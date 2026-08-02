//! Per-session control queue used by the daemon control connection.

use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::Mutex;

use nix::libc;

pub type SessionId = [u8; 16];

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Command {
    Resize {
        serial: u64,
        cols: u16,
        rows: u16,
        xpixel: u16,
        ypixel: u16,
    },
    Signal {
        signum: i32,
    },
}

struct QueueState {
    commands: VecDeque<Command>,
    last_resize_serial: u64,
}

/// A bounded command queue with a pollable wake descriptor.
pub struct SessionControl {
    state: Mutex<QueueState>,
    wake_read: OwnedFd,
    wake_write: OwnedFd,
}

impl SessionControl {
    pub fn new() -> io::Result<Self> {
        let mut fds = [-1; 2];
        let result = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(Self {
            state: Mutex::new(QueueState {
                commands: VecDeque::new(),
                last_resize_serial: 0,
            }),
            wake_read: unsafe { OwnedFd::from_raw_fd(fds[0]) },
            wake_write: unsafe { OwnedFd::from_raw_fd(fds[1]) },
        })
    }

    pub fn wake_fd(&self) -> RawFd {
        self.wake_read.as_raw_fd()
    }

    /// Queue the latest resize, replacing an older pending resize in place.
    pub fn enqueue_resize(&self, serial: u64, cols: u16, rows: u16, xpixel: u16, ypixel: u16) {
        let command = Command::Resize {
            serial,
            cols,
            rows,
            xpixel,
            ypixel,
        };

        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if serial <= state.last_resize_serial {
            return;
        }
        state.last_resize_serial = serial;

        if let Some(existing) = state
            .commands
            .iter_mut()
            .find(|command| matches!(command, Command::Resize { .. }))
        {
            *existing = command;
        } else {
            state.commands.push_back(command);
        }
        drop(state);
        self.wake();
    }

    /// Signals are events and are therefore bounded rather than coalesced.
    pub fn enqueue_signal(&self, signum: i32) {
        const MAX_PENDING_SIGNALS: usize = 64;

        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pending_signals = state
            .commands
            .iter()
            .filter(|command| matches!(command, Command::Signal { .. }))
            .count();
        if pending_signals >= MAX_PENDING_SIGNALS {
            log::warn!("dropping signal {}: session control queue is full", signum);
            return;
        }
        state.commands.push_back(Command::Signal { signum });
        drop(state);
        self.wake();
    }

    pub fn take_commands(&self) -> VecDeque<Command> {
        self.drain_wake_pipe();
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        std::mem::take(&mut state.commands)
    }

    fn wake(&self) {
        let byte = [1u8];
        unsafe {
            // EAGAIN means a wake is already pending, which is sufficient.
            libc::write(
                self.wake_write.as_raw_fd(),
                byte.as_ptr().cast(),
                byte.len(),
            );
        }
    }

    fn drain_wake_pipe(&self) {
        let mut buf = [0u8; 64];
        loop {
            let read = unsafe {
                libc::read(
                    self.wake_read.as_raw_fd(),
                    buf.as_mut_ptr().cast(),
                    buf.len(),
                )
            };
            if read <= 0 {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resize_is_coalesced_and_stale_serials_are_ignored() {
        let control = SessionControl::new().unwrap();
        control.enqueue_resize(2, 100, 40, 1000, 800);
        control.enqueue_resize(1, 80, 24, 800, 600);
        control.enqueue_resize(3, 120, 50, 1200, 1000);

        let commands = control.take_commands();
        assert_eq!(commands.len(), 1);
        assert_eq!(
            commands[0],
            Command::Resize {
                serial: 3,
                cols: 120,
                rows: 50,
                xpixel: 1200,
                ypixel: 1000,
            }
        );
    }

    #[test]
    fn signals_are_not_coalesced() {
        let control = SessionControl::new().unwrap();
        control.enqueue_signal(libc::SIGINT);
        control.enqueue_signal(libc::SIGTERM);

        let commands = control.take_commands();
        assert_eq!(commands.len(), 2);
        assert_eq!(
            commands[0],
            Command::Signal {
                signum: libc::SIGINT
            }
        );
        assert_eq!(
            commands[1],
            Command::Signal {
                signum: libc::SIGTERM
            }
        );
    }
}
