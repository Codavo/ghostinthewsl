/// PTY allocation, fork+exec, and resize support.
use std::ffi::CString;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};

use nix::errno::Errno;
use nix::libc;
use nix::pty::openpty;
use nix::sys::signal::{self, Signal};
use nix::sys::wait::{WaitPidFlag, WaitStatus};
use nix::unistd::{self, ForkResult, Pid};

/// Wraps an allocated PTY pair and the child process.
pub struct PtyChild {
    /// PTY master fd — read child output, write child input.
    pub master: OwnedFd,
    /// Child process PID.
    pub child_pid: Pid,
}

impl PtyChild {
    /// Allocate a PTY, fork, and exec the given shell.
    ///
    /// The child process becomes a session leader with the slave as its
    /// controlling terminal, then execs `shell` with a login shell invocation.
    ///
    /// # Safety
    /// This calls `fork()` which is inherently unsafe in multithreaded programs.
    /// All strings and environment values are pre-computed before fork, and only
    /// async-signal-safe functions are called in the child between fork and exec.
    pub fn spawn(
        shell: &str,
        cols: u16,
        rows: u16,
        cwd: Option<&str>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        // Allocate PTY pair.
        let pty = openpty(None, None)?;
        let master_fd = pty.master;
        let slave_fd = pty.slave;

        // Set initial window size (pixel dimensions arrive with the first resize).
        set_winsize(master_fd.as_raw_fd(), cols, rows, 0, 0)?;

        // Pre-compute all strings BEFORE fork. After fork() in a
        // multithreaded process, only async-signal-safe functions may
        // be called. This means no std::env::set_var (holds Rust env
        // lock), no format! (allocates), and no std::env::var (holds
        // Rust env lock).
        let shell_name = std::path::Path::new(shell)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(shell);
        let login_name = format!("-{}", shell_name);

        let c_shell = CString::new(shell)?;
        let c_argv0 = CString::new(login_name)?;
        let c_fallback_shell = CString::new("/bin/sh").unwrap();
        let c_fallback_argv0 = CString::new("-sh").unwrap();

        // Pre-compute cwd (may need HOME expansion which reads env).
        let c_cwd = cwd.and_then(|dir| {
            let expanded = if dir.starts_with('~') {
                if let Ok(home) = std::env::var("HOME") {
                    dir.replacen('~', &home, 1)
                } else {
                    dir.to_string()
                }
            } else {
                dir.to_string()
            };
            CString::new(expanded).ok()
        });

        // Pre-compute env var C strings.
        let c_term_key = CString::new("TERM").unwrap();
        let c_term_val = CString::new("xterm-ghostty").unwrap();
        let c_ghostwsl_key = CString::new("GHOSTWSL").unwrap();
        let c_ghostwsl_val = CString::new("1").unwrap();
        let c_colorterm_key = CString::new("COLORTERM").unwrap();
        let c_colorterm_val = CString::new("truecolor").unwrap();

        // Fork.
        match unsafe { unistd::fork() }? {
            ForkResult::Child => {
                // === ASYNC-SIGNAL-SAFE ONLY BELOW THIS POINT ===
                // No Rust allocations, no std::env, no format!, no println!.

                // Drop master fd in child — we only use the slave side.
                drop(master_fd);

                // Create a new session (detach from parent's controlling terminal).
                unistd::setsid().ok();

                // Set the slave as the controlling terminal.
                unsafe {
                    libc::ioctl(slave_fd.as_raw_fd(), libc::TIOCSCTTY, 0);
                }

                // Dup slave fd onto stdin/stdout/stderr.
                unistd::dup2(slave_fd.as_raw_fd(), libc::STDIN_FILENO).ok();
                unistd::dup2(slave_fd.as_raw_fd(), libc::STDOUT_FILENO).ok();
                unistd::dup2(slave_fd.as_raw_fd(), libc::STDERR_FILENO).ok();

                // Close the original slave fd if it's not one of 0/1/2.
                if slave_fd.as_raw_fd() > 2 {
                    drop(slave_fd);
                }

                // Change working directory using libc::chdir (async-signal-safe).
                if let Some(ref dir) = c_cwd {
                    unsafe { libc::chdir(dir.as_ptr()); }
                }

                // Set environment using libc::setenv (avoids Rust's internal
                // env lock which could deadlock if held at fork time).
                unsafe {
                    libc::setenv(c_term_key.as_ptr(), c_term_val.as_ptr(), 1);
                    libc::setenv(c_ghostwsl_key.as_ptr(), c_ghostwsl_val.as_ptr(), 1);
                    libc::setenv(c_colorterm_key.as_ptr(), c_colorterm_val.as_ptr(), 1);
                }

                // Exec the shell as a login shell.
                // Login shells conventionally have "-" prepended to argv[0].
                unistd::execvp(&c_shell, &[c_argv0]).ok();

                // If execvp fails, try /bin/sh as fallback.
                unistd::execvp(&c_fallback_shell, &[c_fallback_argv0]).ok();

                // If even /bin/sh fails, use _exit (not process::exit which
                // runs atexit handlers — not async-signal-safe).
                unsafe { libc::_exit(127); }
            }
            ForkResult::Parent { child } => {
                // Drop slave fd in parent — we only use the master side.
                drop(slave_fd);

                Ok(PtyChild {
                    master: master_fd,
                    child_pid: child,
                })
            }
        }
    }

    /// Resize the PTY.
    pub fn resize(&self, cols: u16, rows: u16, xpixel: u16, ypixel: u16) -> Result<(), Box<dyn std::error::Error>> {
        set_winsize(self.master.as_raw_fd(), cols, rows, xpixel, ypixel)
    }

    /// Send a signal to the child process group.
    pub fn send_signal(&self, sig: i32) -> Result<(), Box<dyn std::error::Error>> {
        let signal = Signal::try_from(sig)?;
        // Send to the process group (negative PID).
        signal::kill(Pid::from_raw(-self.child_pid.as_raw()), signal)?;
        Ok(())
    }

    /// Kill the child process and wait for it to exit.
    ///
    /// Sends SIGHUP, waits up to 2 seconds, then escalates to SIGKILL.
    /// Prevents zombie processes when the bridge loop exits with an error.
    pub fn wait_or_kill(&self) {
        let _ = self.send_signal(libc::SIGHUP);
        for _ in 0..200 {
            if self.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ = self.send_signal(libc::SIGKILL);
        for _ in 0..100 {
            if self.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    /// Non-blocking check if child has exited. Returns exit code if so.
    pub fn try_wait(&self) -> Result<Option<i32>, Box<dyn std::error::Error>> {
        match nix::sys::wait::waitpid(self.child_pid, Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::Exited(_, code)) => Ok(Some(code)),
            Ok(WaitStatus::Signaled(_, sig, _)) => Ok(Some(128 + sig as i32)),
            Ok(WaitStatus::StillAlive) => Ok(None),
            Ok(_) => Ok(None),
            Err(Errno::ECHILD) => Ok(Some(0)), // Already reaped.
            Err(e) => Err(e.into()),
        }
    }
}

/// Set the window size on a PTY fd.
fn set_winsize(fd: RawFd, cols: u16, rows: u16, xpixel: u16, ypixel: u16) -> Result<(), Box<dyn std::error::Error>> {
    let ws = libc::winsize {
        ws_col: cols,
        ws_row: rows,
        ws_xpixel: xpixel,
        ws_ypixel: ypixel,
    };
    let ret = unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) };
    if ret < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}
