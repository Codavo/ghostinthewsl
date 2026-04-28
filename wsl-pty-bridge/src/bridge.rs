/// Main bridge event loop: poll-based bidirectional I/O proxy between
/// stdin/stdout and the PTY master, with APC command parsing on stdin.
///
/// Architecture:
///   stdin  → (APC parser) → PTY master  (keyboard input + control commands)
///   PTY master → stdout                  (terminal output, zero filtering)
///
/// The APC parser intercepts `\x1b_Gwsl;...\x1b\\` sequences for control
/// commands (resize, signal) and passes everything else through to the PTY
/// unchanged — including non-Gwsl APC sequences like kitty graphics responses.
use std::io::{self, Write};
use std::os::fd::{AsRawFd, BorrowedFd};

use nix::libc;
use nix::poll::{PollFd, PollFlags};

use crate::protocol::{ApcParser, Command};
use crate::pty::PtyChild;

const BUF_SIZE: usize = 64 * 1024; // 64KB read buffer

/// Exit status report sent to the host when the child process exits.
/// Uses OSC (Operating System Command) format: \x1b]9999;exit;CODE\x07
///
/// We use OSC instead of APC because Ghostty's APC handler dispatches
/// \x1b_G to the kitty graphics parser, which would swallow our message.
/// OSC 9999 is a private-use code that Ghostty ignores but we can detect
/// on the Zig side if needed.
fn write_exit_status(code: i32) {
    let msg = format!("\x1b]9999;exit;{}\x07", code);
    let _ = io::stdout().write_all(msg.as_bytes());
    let _ = io::stdout().flush();
}

/// Run the bridge event loop.
///
/// Proxies data bidirectionally:
///   stdin  → (APC parser) → PTY master  (keyboard input + control commands)
///   PTY master → stdout                  (terminal output)
///
/// Returns the child process exit code.
pub fn run(child: &PtyChild) -> Result<i32, Box<dyn std::error::Error>> {
    let stdin_fd = io::stdin().as_raw_fd();
    let master_fd = child.master.as_raw_fd();

    // Set both fds to non-blocking mode.
    set_nonblocking(stdin_fd)?;
    set_nonblocking(master_fd)?;

    let mut parser = ApcParser::new();
    let mut buf = vec![0u8; BUF_SIZE];
    let mut last_resize: (u16, u16, u16, u16) = (0, 0, 0, 0);

    loop {
        // Poll on stdin and PTY master.
        // SAFETY: These fds are valid for the duration of the poll call.
        let mut fds = unsafe {
            [
                PollFd::new(BorrowedFd::borrow_raw(stdin_fd), PollFlags::POLLIN),
                PollFd::new(BorrowedFd::borrow_raw(master_fd), PollFlags::POLLIN),
            ]
        };

        // Use a 100ms timeout so we can periodically check if the child exited.
        match nix::poll::poll(&mut fds, nix::poll::PollTimeout::from(100u16)) {
            Ok(0) => {
                // Timeout — check if child exited.
                if let Some(code) = child.try_wait()? {
                    // Drain any remaining PTY output.
                    drain_pty_to_stdout(master_fd, &mut buf);
                    write_exit_status(code);
                    return Ok(code);
                }
                continue;
            }
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => return Err(e.into()),
        }

        // Check for stdin data (host → PTY).
        if let Some(revents) = fds[0].revents() {
            if revents.contains(PollFlags::POLLIN) {
                match read_nonblocking(stdin_fd, &mut buf) {
                    Ok(0) => {
                        // stdin EOF — host closed the pipe. Wait for child to exit.
                        log::info!("stdin EOF, waiting for child to exit");
                        return wait_for_child(child, master_fd, &mut buf);
                    }
                    Ok(n) => {
                        let result = parser.feed(&buf[..n]);

                        // Forward passthrough data to PTY master.
                        if !result.passthrough.is_empty() {
                            write_all_fd(master_fd, &result.passthrough)?;
                        }

                        // Handle commands.
                        for cmd in result.commands {
                            handle_command(child, cmd, &mut last_resize);
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                    Err(e) => return Err(e.into()),
                }
            }
            if revents.intersects(PollFlags::POLLERR | PollFlags::POLLHUP) {
                log::info!("stdin HUP/ERR, waiting for child to exit");
                return wait_for_child(child, master_fd, &mut buf);
            }
        }

        // Check for PTY master data (child → host) — pure passthrough.
        if let Some(revents) = fds[1].revents() {
            if revents.contains(PollFlags::POLLIN) {
                match read_nonblocking(master_fd, &mut buf) {
                    Ok(0) => {
                        // PTY master EOF — child exited.
                        if let Some(code) = child.try_wait()? {
                            write_exit_status(code);
                            return Ok(code);
                        }
                        write_exit_status(0);
                        return Ok(0);
                    }
                    Ok(n) => {
                        // Write directly to stdout — zero filtering.
                        if let Err(e) = io::stdout().write_all(&buf[..n]) {
                            log::info!("stdout write error: {}, exiting", e);
                            return wait_for_child(child, master_fd, &mut buf);
                        }
                        if let Err(e) = io::stdout().flush() {
                            log::info!("stdout flush error: {}, exiting", e);
                            return wait_for_child(child, master_fd, &mut buf);
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                    Err(e) => {
                        // EIO on PTY master means the slave side closed.
                        if e.raw_os_error() == Some(libc::EIO) {
                            if let Some(code) = child.try_wait()? {
                                write_exit_status(code);
                                return Ok(code);
                            }
                            write_exit_status(0);
                            return Ok(0);
                        }
                        return Err(e.into());
                    }
                }
            }
            if revents.intersects(PollFlags::POLLERR | PollFlags::POLLHUP) {
                // PTY closed — drain any remaining buffered data first,
                // then report exit. The kernel can set POLLHUP while data
                // is still readable in the buffer.
                drain_pty_to_stdout(master_fd, &mut buf);
                if let Some(code) = child.try_wait()? {
                    write_exit_status(code);
                    return Ok(code);
                }
                write_exit_status(0);
                return Ok(0);
            }
        }
    }
}

/// Handle a parsed APC command.
///
/// `last_resize` tracks the last resize dimensions to skip duplicate
/// ioctl(TIOCSWINSZ) calls. Without this, rapid resize drags flood the
/// child with SIGWINCHs, triggering re-render storms that cause
/// backpressure on the socket and multi-second stalls.
fn handle_command(child: &PtyChild, cmd: Command, last_resize: &mut (u16, u16, u16, u16)) {
    match cmd {
        Command::Resize { cols, rows, xpixel, ypixel } => {
            let new = (cols, rows, xpixel, ypixel);
            if new == *last_resize {
                return; // Skip duplicate — no SIGWINCH generated
            }
            *last_resize = new;
            log::debug!("Resize to {}x{} ({}x{}px)", cols, rows, xpixel, ypixel);
            if let Err(e) = child.resize(cols, rows, xpixel, ypixel) {
                log::error!("Failed to resize PTY: {}", e);
            }
        }
        Command::Signal { signum } => {
            log::debug!("Forwarding signal {}", signum);
            if let Err(e) = child.send_signal(signum) {
                log::error!("Failed to send signal {}: {}", signum, e);
            }
        }
    }
}

/// Shut down the child process and return its exit code.
///
/// Sends SIGHUP to the child process group (like a real terminal closing),
/// waits briefly while draining PTY output, then escalates to SIGKILL if needed.
/// Draining during the wait ensures the child's final output is delivered and
/// prevents the child from blocking on a full PTY buffer (which would prevent
/// it from processing SIGHUP).
fn wait_for_child(child: &PtyChild, master_fd: i32, buf: &mut [u8]) -> Result<i32, Box<dyn std::error::Error>> {
    // Send SIGHUP — this is what a real terminal does when it closes.
    let _ = child.send_signal(libc::SIGHUP);

    // Wait up to 2 seconds for graceful exit, draining PTY output along the way.
    for _ in 0..200 {
        // Drain available output — prevents the child from blocking on write
        // and also delivers any remaining data to stdout.
        drain_pty_to_stdout(master_fd, buf);

        if let Some(code) = child.try_wait()? {
            drain_pty_to_stdout(master_fd, buf);
            write_exit_status(code);
            return Ok(code);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    // Still alive — force kill.
    log::warn!("Child did not exit after SIGHUP, sending SIGKILL");
    let _ = child.send_signal(libc::SIGKILL);

    // Wait up to 1 more second.
    for _ in 0..100 {
        drain_pty_to_stdout(master_fd, buf);

        if let Some(code) = child.try_wait()? {
            drain_pty_to_stdout(master_fd, buf);
            write_exit_status(code);
            return Ok(code);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    // Give up — report as killed.
    write_exit_status(128 + libc::SIGKILL);
    Ok(128 + libc::SIGKILL)
}

/// Drain any remaining output from the PTY master to stdout.
///
/// Reads all available data from the PTY and writes it to stdout.
/// Stops on write error (stdout broken) or read EOF/error (no more data).
fn drain_pty_to_stdout(master_fd: i32, buf: &mut [u8]) {
    let mut had_data = false;
    loop {
        match read_nonblocking(master_fd, buf) {
            Ok(0) => break,
            Ok(n) => {
                if io::stdout().write_all(&buf[..n]).is_err() {
                    break; // Output broken, can't deliver remaining data
                }
                had_data = true;
            }
            // EAGAIN = no more data available, EIO = slave closed, other = done
            Err(_) => break,
        }
    }
    if had_data {
        let _ = io::stdout().flush();
    }
}

/// Maximum size of the socket write buffer before we consider the
/// connection dead. 4MB is generous — typical resize re-render bursts
/// are a few hundred KB at most.
const MAX_WRITE_BUF: usize = 4 * 1024 * 1024;

/// Run the bridge event loop using a single bidirectional fd (e.g. a socket).
///
/// Same logic as `run()` but reads input from `fd` instead of stdin and
/// writes PTY output to `fd` instead of stdout.
///
/// Uses non-blocking writes with a buffer for socket output. This prevents
/// the daemon from stalling on a full socket send buffer (backpressure from
/// a slow consumer on the host side) while incoming resize APCs accumulate
/// unread — the root cause of multi-second stalls during window drag.
pub fn run_with_fd(child: &PtyChild, fd: i32) -> Result<i32, Box<dyn std::error::Error>> {
    let master_fd = child.master.as_raw_fd();

    set_nonblocking(fd)?;
    set_nonblocking(master_fd)?;

    let mut parser = ApcParser::new();
    let mut buf = vec![0u8; BUF_SIZE];
    let mut write_buf: Vec<u8> = Vec::new();
    let mut last_resize: (u16, u16, u16, u16) = (0, 0, 0, 0);

    loop {
        // Poll socket for POLLIN always; add POLLOUT when we have buffered data.
        let socket_events = if write_buf.is_empty() {
            PollFlags::POLLIN
        } else {
            PollFlags::POLLIN | PollFlags::POLLOUT
        };

        let mut fds = unsafe {
            [
                PollFd::new(BorrowedFd::borrow_raw(fd), socket_events),
                PollFd::new(BorrowedFd::borrow_raw(master_fd), PollFlags::POLLIN),
            ]
        };

        match nix::poll::poll(&mut fds, nix::poll::PollTimeout::from(100u16)) {
            Ok(0) => {
                if let Some(code) = child.try_wait()? {
                    flush_write_buf(fd, &mut write_buf)?;
                    drain_fd(master_fd, fd, &mut buf);
                    write_exit_status_fd(fd, code);
                    return Ok(code);
                }
                continue;
            }
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => return Err(e.into()),
        }

        // Check for socket events.
        if let Some(revents) = fds[0].revents() {
            // Flush buffered writes when socket is writable.
            if revents.contains(PollFlags::POLLOUT) && !write_buf.is_empty() {
                flush_write_buf(fd, &mut write_buf)?;
            }

            // Read host → PTY data.
            if revents.contains(PollFlags::POLLIN) {
                match read_nonblocking(fd, &mut buf) {
                    Ok(0) => {
                        log::info!("socket EOF, waiting for child to exit");
                        return wait_for_child_fd(child, fd, master_fd, &mut buf);
                    }
                    Ok(n) => {
                        let result = parser.feed(&buf[..n]);
                        if !result.passthrough.is_empty() {
                            write_all_fd(master_fd, &result.passthrough)?;
                        }
                        for cmd in result.commands {
                            handle_command(child, cmd, &mut last_resize);
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                    Err(e) => return Err(e.into()),
                }
            }
            if revents.intersects(PollFlags::POLLERR | PollFlags::POLLHUP) {
                log::info!("socket HUP/ERR, waiting for child to exit");
                return wait_for_child_fd(child, fd, master_fd, &mut buf);
            }
        }

        // Check for PTY master data (child → host).
        if let Some(revents) = fds[1].revents() {
            if revents.contains(PollFlags::POLLIN) {
                match read_nonblocking(master_fd, &mut buf) {
                    Ok(0) => {
                        flush_write_buf(fd, &mut write_buf)?;
                        if let Some(code) = child.try_wait()? {
                            write_exit_status_fd(fd, code);
                            return Ok(code);
                        }
                        write_exit_status_fd(fd, 0);
                        return Ok(0);
                    }
                    Ok(n) => {
                        // Non-blocking write to socket. Buffer any data
                        // that can't be sent immediately.
                        if write_buf.is_empty() {
                            // Fast path: try direct write.
                            let written = try_write_nonblocking(fd, &buf[..n]);
                            if written < n {
                                write_buf.extend_from_slice(&buf[written..n]);
                            }
                        } else {
                            // Already have buffered data, append.
                            write_buf.extend_from_slice(&buf[..n]);
                        }

                        // Check for buffer overflow.
                        if write_buf.len() > MAX_WRITE_BUF {
                            log::warn!(
                                "write buffer overflow ({} bytes), host not consuming data",
                                write_buf.len()
                            );
                            return Err(io::Error::new(
                                io::ErrorKind::Other,
                                "socket write buffer overflow",
                            )
                            .into());
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                    Err(e) => {
                        if e.raw_os_error() == Some(libc::EIO) {
                            flush_write_buf(fd, &mut write_buf)?;
                            if let Some(code) = child.try_wait()? {
                                write_exit_status_fd(fd, code);
                                return Ok(code);
                            }
                            write_exit_status_fd(fd, 0);
                            return Ok(0);
                        }
                        return Err(e.into());
                    }
                }
            }
            if revents.intersects(PollFlags::POLLERR | PollFlags::POLLHUP) {
                // PTY closed — drain any remaining buffered data first.
                flush_write_buf(fd, &mut write_buf)?;
                drain_fd(master_fd, fd, &mut buf);
                if let Some(code) = child.try_wait()? {
                    write_exit_status_fd(fd, code);
                    return Ok(code);
                }
                write_exit_status_fd(fd, 0);
                return Ok(0);
            }
        }
    }
}

/// Write exit status report to an arbitrary fd.
fn write_exit_status_fd(fd: i32, code: i32) {
    let msg = format!("\x1b]9999;exit;{}\x07", code);
    let _ = write_all_fd(fd, msg.as_bytes());
}

/// Drain remaining PTY output to a socket fd.
///
/// Reads all available data from the PTY and writes it to the socket.
/// Stops on write error (socket broken) or read EOF/error (no more data).
fn drain_fd(master_fd: i32, out_fd: i32, buf: &mut [u8]) {
    loop {
        match read_nonblocking(master_fd, buf) {
            Ok(0) => break,
            Ok(n) => {
                if write_all_fd(out_fd, &buf[..n]).is_err() {
                    break; // Output broken, can't deliver remaining data
                }
            }
            // EAGAIN = no more data available, EIO = slave closed, other = done
            Err(_) => break,
        }
    }
}

/// Shut down the child and report exit status to a socket fd.
/// Drains PTY output during the wait to prevent the child from blocking
/// on a full PTY buffer and to deliver final output to the host.
fn wait_for_child_fd(child: &PtyChild, fd: i32, master_fd: i32, buf: &mut [u8]) -> Result<i32, Box<dyn std::error::Error>> {
    let _ = child.send_signal(libc::SIGHUP);

    for _ in 0..200 {
        drain_fd(master_fd, fd, buf);

        if let Some(code) = child.try_wait()? {
            drain_fd(master_fd, fd, buf);
            write_exit_status_fd(fd, code);
            return Ok(code);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    log::warn!("Child did not exit after SIGHUP, sending SIGKILL");
    let _ = child.send_signal(libc::SIGKILL);

    for _ in 0..100 {
        drain_fd(master_fd, fd, buf);

        if let Some(code) = child.try_wait()? {
            drain_fd(master_fd, fd, buf);
            write_exit_status_fd(fd, code);
            return Ok(code);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    write_exit_status_fd(fd, 128 + libc::SIGKILL);
    Ok(128 + libc::SIGKILL)
}

/// Set a file descriptor to non-blocking mode.
fn set_nonblocking(fd: i32) -> Result<(), io::Error> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let ret = unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) };
    if ret < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Read from a file descriptor (non-blocking).
fn read_nonblocking(fd: i32, buf: &mut [u8]) -> Result<usize, io::Error> {
    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

/// Try to write data to a fd without blocking. Returns the number of
/// bytes actually written (may be 0 if the fd isn't writable).
fn try_write_nonblocking(fd: i32, data: &[u8]) -> usize {
    if data.is_empty() {
        return 0;
    }
    let n = unsafe { libc::write(fd, data.as_ptr() as *const libc::c_void, data.len()) };
    if n <= 0 {
        0 // EAGAIN, EINTR, or error — caller should buffer
    } else {
        n as usize
    }
}

/// Flush as much of the write buffer as possible without blocking.
///
/// Writes bytes from the front of the buffer and removes them. Returns
/// when the buffer is empty or the fd would block.
fn flush_write_buf(fd: i32, write_buf: &mut Vec<u8>) -> Result<(), io::Error> {
    while !write_buf.is_empty() {
        let n = unsafe {
            libc::write(
                fd,
                write_buf.as_ptr() as *const libc::c_void,
                write_buf.len(),
            )
        };
        if n < 0 {
            let err = io::Error::last_os_error();
            match err.kind() {
                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted => return Ok(()),
                _ => return Err(err),
            }
        }
        if n == 0 {
            return Ok(());
        }
        let written = n as usize;
        write_buf.drain(..written);
    }
    Ok(())
}

/// Write all bytes to a file descriptor.
///
/// Handles both EINTR (signal interruption) and EAGAIN/WouldBlock (non-blocking
/// fd with full buffer) by polling for write readiness before retrying.
fn write_all_fd(fd: i32, mut data: &[u8]) -> Result<(), io::Error> {
    while !data.is_empty() {
        let n = unsafe { libc::write(fd, data.as_ptr() as *const libc::c_void, data.len()) };
        if n < 0 {
            let err = io::Error::last_os_error();
            match err.kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::WouldBlock => {
                    // Buffer is full — wait for the fd to become writable.
                    let mut pfd = [nix::poll::PollFd::new(
                        unsafe { BorrowedFd::borrow_raw(fd) },
                        PollFlags::POLLOUT,
                    )];
                    match nix::poll::poll(&mut pfd, nix::poll::PollTimeout::from(30_000u16)) {
                        Ok(0) => {
                            // Timeout — fd still not writable after 30s. The Zig
                            // read thread may be blocked on the renderer mutex
                            // (processOutput holds it while parsing VT data),
                            // causing the socket buffer to fill. 30s accommodates
                            // even extreme renderer stalls during resize.
                            return Err(io::Error::new(
                                io::ErrorKind::TimedOut,
                                "write_all_fd: fd not writable after 30s",
                            ));
                        }
                        Ok(_) => {
                            // Check for POLLERR/POLLHUP — fd is broken.
                            if let Some(revents) = pfd[0].revents() {
                                if revents.intersects(PollFlags::POLLERR | PollFlags::POLLHUP) {
                                    return Err(io::Error::new(
                                        io::ErrorKind::BrokenPipe,
                                        "write_all_fd: fd has POLLERR/POLLHUP",
                                    ));
                                }
                            }
                            continue; // POLLOUT set — retry write
                        }
                        Err(nix::errno::Errno::EINTR) => continue,
                        Err(e) => return Err(io::Error::from_raw_os_error(e as i32)),
                    }
                }
                _ => return Err(err),
            }
        }
        data = &data[n as usize..];
    }
    Ok(())
}
