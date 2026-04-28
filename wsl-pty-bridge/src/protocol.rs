//! APC-based control protocol for out-of-band commands from the host.
//!
//! Protocol format uses APC (Application Program Command) escape sequences:
//!   `\x1b_Gwsl;COMMAND;ARGS...\x1b\\`
//!
//! This prefix (`\x1b_Gwsl;`) is safe on the stdin path (host → bridge) because
//! the bridge parses it before the PTY child sees it. On the stdout path
//! (bridge → host), we must NOT use `\x1b_G` because Ghostty's terminal
//! parser dispatches it to the kitty graphics handler — use OSC instead.
//!
//! Commands (stdin direction only):
//!   - `resize;COLS;ROWS;XPIXEL;YPIXEL` → ioctl(TIOCSWINSZ) on the PTY master
//!   - `signal;SIGNUM`                    → kill(child_pgid, sig)
//!
//! Non-Gwsl APC sequences on stdin (e.g. kitty graphics responses from the
//! terminal to the application) are passed through to the PTY master unchanged.

/// Parsed control command from the host.
#[derive(Debug, PartialEq)]
pub enum Command {
    Resize { cols: u16, rows: u16, xpixel: u16, ypixel: u16 },
    Signal { signum: i32 },
}

/// State machine for parsing APC sequences out of a byte stream.
///
/// Bytes that are NOT part of an APC sequence are collected in `passthrough`
/// for forwarding to the PTY master.
pub struct ApcParser {
    state: State,
    /// Accumulated APC payload bytes.
    buf: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum State {
    /// Normal pass-through state.
    Ground,
    /// Saw ESC (0x1b), waiting for '_' (APC start) or anything else.
    Escape,
    /// Inside APC payload, accumulating bytes until ST (ESC + '\\').
    ApcBody,
    /// Inside APC body, saw ESC — waiting for '\\' to complete ST.
    ApcEscape,
}

/// Result of feeding bytes through the parser.
pub struct ParseResult {
    /// Bytes to forward to the PTY (everything not part of Gwsl APC sequences).
    pub passthrough: Vec<u8>,
    /// Parsed commands extracted from complete APC sequences.
    pub commands: Vec<Command>,
}

impl ApcParser {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            buf: Vec::with_capacity(64),
        }
    }

    /// Feed a chunk of bytes from stdin through the parser.
    ///
    /// Returns passthrough bytes (for the PTY) and any parsed commands.
    pub fn feed(&mut self, data: &[u8]) -> ParseResult {
        let mut passthrough = Vec::with_capacity(data.len());
        let mut commands = Vec::new();

        for &byte in data {
            match self.state {
                State::Ground => {
                    if byte == 0x1b {
                        self.state = State::Escape;
                    } else {
                        passthrough.push(byte);
                    }
                }
                State::Escape => {
                    if byte == b'_' {
                        // APC start — begin accumulating payload.
                        self.state = State::ApcBody;
                        self.buf.clear();
                    } else {
                        // Not an APC — pass the ESC and this byte through.
                        passthrough.push(0x1b);
                        passthrough.push(byte);
                        self.state = State::Ground;
                    }
                }
                State::ApcBody => {
                    if byte == 0x1b {
                        self.state = State::ApcEscape;
                    } else if self.buf.len() < 1024 * 1024 {
                        self.buf.push(byte);
                    } else {
                        // APC body exceeds 1MB — malformed sequence (missing ST).
                        // Abandon the parse and return to Ground state to prevent
                        // eating all subsequent input (including Ctrl-C). Pass the
                        // accumulated data through to the PTY as-is.
                        passthrough.push(0x1b);
                        passthrough.push(b'_');
                        passthrough.extend_from_slice(&self.buf);
                        passthrough.push(byte);
                        self.buf.clear();
                        self.state = State::Ground;
                    }
                }
                State::ApcEscape => {
                    if byte == b'\\' {
                        // ST received — parse the APC payload.
                        if let Some(cmd) = Self::parse_payload(&self.buf) {
                            commands.push(cmd);
                        } else {
                            // Not a Gwsl command — pass the full APC sequence
                            // through to the PTY. This is critical for kitty
                            // graphics responses (e.g. \x1b_Gi=31;OK\x1b\\)
                            // which flow from the terminal back to the app.
                            passthrough.push(0x1b);
                            passthrough.push(b'_');
                            passthrough.extend_from_slice(&self.buf);
                            passthrough.push(0x1b);
                            passthrough.push(b'\\');
                        }
                        self.buf.clear();
                        self.state = State::Ground;
                    } else {
                        // False alarm — the ESC wasn't followed by '\'.
                        self.buf.push(0x1b);
                        self.buf.push(byte);
                        self.state = State::ApcBody;
                    }
                }
            }
        }

        ParseResult {
            passthrough,
            commands,
        }
    }

    /// Parse the payload of a complete APC sequence.
    ///
    /// Expected format: "Gwsl;command;arg1;arg2..."
    fn parse_payload(payload: &[u8]) -> Option<Command> {
        let s = std::str::from_utf8(payload).ok()?;

        // Must start with "Gwsl;"
        let rest = s.strip_prefix("Gwsl;")?;

        let mut parts = rest.splitn(2, ';');
        let command = parts.next()?;
        let args = parts.next().unwrap_or("");

        match command {
            "resize" => {
                let mut dims = args.splitn(4, ';');
                let cols: u16 = dims.next()?.parse().ok()?;
                let rows: u16 = dims.next()?.parse().ok()?;
                // Pixel dimensions are optional for backward compatibility.
                let xpixel: u16 = dims.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                let ypixel: u16 = dims.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                Some(Command::Resize { cols, rows, xpixel, ypixel })
            }
            "signal" => {
                let signum: i32 = args.parse().ok()?;
                Some(Command::Signal { signum })
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_passthrough_no_apc() {
        let mut parser = ApcParser::new();
        let result = parser.feed(b"hello world");
        assert_eq!(result.passthrough, b"hello world");
        assert!(result.commands.is_empty());
    }

    #[test]
    fn test_resize_command_with_pixels() {
        let mut parser = ApcParser::new();
        let input = b"\x1b_Gwsl;resize;120;40;1920;1080\x1b\\";
        let result = parser.feed(input);
        assert!(result.passthrough.is_empty());
        assert_eq!(result.commands.len(), 1);
        assert_eq!(
            result.commands[0],
            Command::Resize {
                cols: 120,
                rows: 40,
                xpixel: 1920,
                ypixel: 1080,
            }
        );
    }

    #[test]
    fn test_resize_command_without_pixels() {
        // Backward compatibility: pixel dimensions are optional.
        let mut parser = ApcParser::new();
        let input = b"\x1b_Gwsl;resize;80;24\x1b\\";
        let result = parser.feed(input);
        assert!(result.passthrough.is_empty());
        assert_eq!(result.commands.len(), 1);
        assert_eq!(
            result.commands[0],
            Command::Resize {
                cols: 80,
                rows: 24,
                xpixel: 0,
                ypixel: 0,
            }
        );
    }

    #[test]
    fn test_signal_command() {
        let mut parser = ApcParser::new();
        let input = b"\x1b_Gwsl;signal;15\x1b\\";
        let result = parser.feed(input);
        assert!(result.passthrough.is_empty());
        assert_eq!(result.commands.len(), 1);
        assert_eq!(result.commands[0], Command::Signal { signum: 15 });
    }

    #[test]
    fn test_mixed_data_and_commands() {
        let mut parser = ApcParser::new();
        let input = b"before\x1b_Gwsl;resize;80;24;640;480\x1b\\after";
        let result = parser.feed(input);
        assert_eq!(result.passthrough, b"beforeafter");
        assert_eq!(result.commands.len(), 1);
        assert_eq!(
            result.commands[0],
            Command::Resize {
                cols: 80,
                rows: 24,
                xpixel: 640,
                ypixel: 480,
            }
        );
    }

    #[test]
    fn test_non_apc_escape_sequence_passed_through() {
        let mut parser = ApcParser::new();
        // ESC [ 1 m is a normal SGR sequence — should pass through.
        let input = b"\x1b[1m";
        let result = parser.feed(input);
        assert_eq!(result.passthrough, b"\x1b[1m");
        assert!(result.commands.is_empty());
    }

    #[test]
    fn test_split_across_feeds() {
        let mut parser = ApcParser::new();

        // Feed the APC in two halves.
        let r1 = parser.feed(b"\x1b_Gwsl;resi");
        assert!(r1.passthrough.is_empty());
        assert!(r1.commands.is_empty());

        let r2 = parser.feed(b"ze;100;50;800;600\x1b\\");
        assert!(r2.passthrough.is_empty());
        assert_eq!(r2.commands.len(), 1);
        assert_eq!(
            r2.commands[0],
            Command::Resize {
                cols: 100,
                rows: 50,
                xpixel: 800,
                ypixel: 600,
            }
        );
    }

    #[test]
    fn test_non_gwsl_apc_passed_through() {
        let mut parser = ApcParser::new();
        // APC that doesn't start with "Gwsl;" — should be passed through
        // intact so terminal responses (kitty graphics, etc.) reach the app.
        let input = b"\x1b_something_else\x1b\\";
        let result = parser.feed(input);
        assert_eq!(result.passthrough, b"\x1b_something_else\x1b\\");
        assert!(result.commands.is_empty());
    }

    #[test]
    fn test_kitty_graphics_response_passed_through() {
        // Kitty graphics responses from the terminal back to the app
        // must pass through the APC parser unchanged.
        let mut parser = ApcParser::new();
        let input = b"\x1b_Gi=31;OK\x1b\\";
        let result = parser.feed(input);
        assert_eq!(result.passthrough, b"\x1b_Gi=31;OK\x1b\\");
        assert!(result.commands.is_empty());
    }

    #[test]
    fn test_kitty_graphics_query_passed_through() {
        let mut parser = ApcParser::new();
        let input = b"\x1b_Gf=100,a=q,i=1;AAAA\x1b\\";
        let result = parser.feed(input);
        assert_eq!(result.passthrough, b"\x1b_Gf=100,a=q,i=1;AAAA\x1b\\");
        assert!(result.commands.is_empty());
    }

    #[test]
    fn test_unrecognized_gwsl_command_passed_through() {
        let mut parser = ApcParser::new();
        // Unknown Gwsl command — passed through (not silently dropped).
        let input = b"\x1b_Gwsl;unknown;foo\x1b\\";
        let result = parser.feed(input);
        assert_eq!(result.passthrough, b"\x1b_Gwsl;unknown;foo\x1b\\");
        assert!(result.commands.is_empty());
    }

    #[test]
    fn test_regular_escape_sequences_passthrough() {
        let mut parser = ApcParser::new();
        // Verify various terminal escape sequences pass through on stdin.
        let sequences: &[&[u8]] = &[
            b"\x1b[38;2;255;0;0m",          // 24-bit color SGR
            b"\x1b[?25l",                     // hide cursor
            b"\x1b[6n",                        // cursor position report request
            b"\x1b[?1049h",                    // alternate screen buffer
            b"\x1b(0",                         // DEC special character set
        ];

        for seq in sequences {
            let result = parser.feed(seq);
            assert_eq!(
                &result.passthrough, seq,
                "Sequence {:?} should pass through unchanged",
                String::from_utf8_lossy(seq)
            );
            assert!(result.commands.is_empty());
        }
    }
}
