//! Daemon mode: listens on a vsock port and spawns a PTY per connection.
//!
//! Data connections carry one raw PTY byte stream. Authenticated control
//! connections multiplex resize and signal commands for all live sessions.
//!
//! Protocol v3 starts with "GWSL\x03" + role:u8 + token:32bytes.
//! Data role (1) continues with terminal geometry, shell, and cwd. Its response
//! is "OK\x02" + pty_id:u32be + session_id:16bytes, followed by raw PTY bytes.
//! Control role (2) receives "OKC\x01", then sends framed commands addressed
//! by session ID: type:u8 + payload_len:u16be + payload.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rand::Rng;
use vsock::VsockListener;

use crate::bridge;
use crate::control::{SessionControl, SessionId};
use crate::pty::PtyChild;

/// Set to true after the first connection is accepted. The idle watcher
/// won't start its countdown until this is set, so the daemon survives
/// the gap between startup and the first tab connecting.
static HAS_HAD_CONNECTION: AtomicBool = AtomicBool::new(false);

/// Versioned connection preamble followed by a one-byte connection role.
const HANDSHAKE_MAGIC: &[u8] = b"GWSL\x03";
const ROLE_DATA: u8 = 1;
const ROLE_CONTROL: u8 = 2;
const CONTROL_RESIZE: u8 = 1;
const CONTROL_SIGNAL: u8 = 2;
const MAX_CONTROL_PAYLOAD: usize = 256;

/// Length of the authentication token in bytes.
const TOKEN_LEN: usize = 32;

/// Token file path template — port is appended for per-daemon isolation.
/// e.g. "/tmp/ghostwsl-48470.token"
fn token_file_path(port: u32) -> String {
    format!("/tmp/ghostwsl-{}.token", port)
}

/// Monotonically increasing PTY ID for each connection.
static NEXT_PTY_ID: AtomicU32 = AtomicU32::new(1);

type SessionRegistry = Arc<Mutex<HashMap<SessionId, Arc<SessionControl>>>>;

/// Parsed handshake from the client.
#[derive(Debug)]
struct Handshake {
    cols: u16,
    rows: u16,
    xpixel: u16,
    ypixel: u16,
    shell: String,
    cwd: Option<String>,
}

/// Run the daemon: listen on vsock and handle connections.
/// `idle_timeout_secs`: seconds of inactivity before shutdown. 0 = run forever.
pub fn run(port: u32, idle_timeout_secs: u64) -> Result<(), Box<dyn std::error::Error>> {
    // Double-fork to fully detach from wsl.exe:
    //   1. First fork: parent exits → wsl.exe sees child die → wsl.exe exits
    //   2. Child calls setsid() to become session leader (no controlling terminal)
    //   3. Second fork: intermediate exits → grandchild can never reacquire a terminal
    //   4. Grandchild redirects stdio to /dev/null and continues as the daemon
    //
    // Without the double-fork, wsl.exe waits for its child (the daemon) to exit,
    // creating a leaked wsl.exe process per startDaemon() call on the Windows side.
    unsafe {
        let pid = libc::fork();
        if pid < 0 {
            return Err("first fork failed".into());
        }
        if pid > 0 {
            // Original process (wsl.exe's child): exit immediately so wsl.exe can exit.
            libc::_exit(0);
        }

        // First child: become session leader.
        libc::setsid();
        libc::signal(libc::SIGHUP, libc::SIG_IGN);

        let pid2 = libc::fork();
        if pid2 < 0 {
            libc::_exit(1);
        }
        if pid2 > 0 {
            // Intermediate process: exit so the grandchild is orphaned (adopted by init).
            libc::_exit(0);
        }

        // Grandchild: redirect stdio to /dev/null. The daemon uses vsock
        // (not stdio) for all communication, and logging goes to a file.
        let devnull = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
        if devnull >= 0 {
            libc::dup2(devnull, 0);
            libc::dup2(devnull, 1);
            libc::dup2(devnull, 2);
            if devnull > 2 {
                libc::close(devnull);
            }
        }
    }

    // Bind first, then write the token file. If bind fails (e.g. EADDRINUSE
    // because another daemon is already running), we must NOT overwrite the
    // existing token file — that would poison it with a token the running
    // daemon doesn't know about.
    let listener = VsockListener::bind_with_cid_port(libc::VMADDR_CID_ANY, port)?;

    let token = generate_token();
    write_token_file(port, &token)?;
    log::info!("Token file written to {}", token_file_path(port));
    log::info!("Daemon listening on vsock port {}", port);

    // Track active connections for idle shutdown.
    let active_count = Arc::new(AtomicU32::new(0));
    let last_activity = Arc::new(std::sync::Mutex::new(Instant::now()));

    // Spawn idle watcher thread (only if timeout is configured).
    if idle_timeout_secs > 0 {
        let idle_count = Arc::clone(&active_count);
        let idle_activity = Arc::clone(&last_activity);
        std::thread::spawn(move || {
            idle_watcher(idle_count, idle_activity, idle_timeout_secs);
        });
    } else {
        log::info!("Idle timeout disabled, daemon will run until killed");
    }

    let token = Arc::new(token);
    let registry: SessionRegistry = Arc::new(Mutex::new(HashMap::new()));

    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                log::error!("Accept error: {}", e);
                continue;
            }
        };

        // Mark that we've had at least one connection (enables idle timeout).
        HAS_HAD_CONNECTION.store(true, Ordering::SeqCst);

        // Update activity timestamp.
        if let Ok(mut ts) = last_activity.lock() {
            *ts = Instant::now();
        }

        let conn_token = Arc::clone(&token);
        let conn_registry = Arc::clone(&registry);
        let count = Arc::clone(&active_count);
        let activity = Arc::clone(&last_activity);
        std::thread::spawn(move || {
            if let Err(e) = handle_connection(stream, &conn_token, conn_registry, count, activity) {
                log::error!("Connection error: {}", e);
            }
        });
    }

    Ok(())
}

/// RAII guard that decrements active count and updates activity on drop.
struct ConnectionGuard {
    count: Arc<AtomicU32>,
    activity: Arc<std::sync::Mutex<Instant>>,
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.count.fetch_sub(1, Ordering::SeqCst);
        if let Ok(mut ts) = self.activity.lock() {
            *ts = Instant::now();
        }
    }
}

/// Watch for idle timeout: exit if no connections for the configured duration.
/// Only starts counting after the first connection has been made and closed,
/// so the daemon survives the initial startup gap.
fn idle_watcher(
    active_count: Arc<AtomicU32>,
    last_activity: Arc<std::sync::Mutex<Instant>>,
    timeout_secs: u64,
) {
    let idle_timeout = Duration::from_secs(timeout_secs);
    loop {
        std::thread::sleep(Duration::from_secs(5));

        // Don't time out before the first connection — the daemon may have
        // just started and the first tab hasn't connected yet.
        if !HAS_HAD_CONNECTION.load(Ordering::SeqCst) {
            continue;
        }

        if active_count.load(Ordering::SeqCst) > 0 {
            continue;
        }

        let elapsed = last_activity
            .lock()
            .map(|ts| ts.elapsed())
            .unwrap_or(Duration::ZERO);

        if elapsed >= idle_timeout {
            // Double-check: a connection might have arrived between our
            // last check and now.
            if active_count.load(Ordering::SeqCst) > 0 {
                continue;
            }
            log::info!(
                "No active connections for {}s, shutting down daemon",
                timeout_secs
            );
            std::process::exit(0);
        }
    }
}

/// Authenticate and dispatch a data or shared control connection.
fn handle_connection(
    mut stream: vsock::VsockStream,
    expected_token: &[u8; TOKEN_LEN],
    registry: SessionRegistry,
    active_count: Arc<AtomicU32>,
    last_activity: Arc<Mutex<Instant>>,
) -> Result<(), Box<dyn std::error::Error>> {
    let (role, token) = read_connection_preamble(&mut stream)?;

    // Authenticate: constant-time comparison to avoid timing side-channels.
    if !constant_time_eq(&token, expected_token) {
        log::warn!("Connection rejected: invalid authentication token");
        let _ = write_handshake_err(&mut stream, b"EAUTH");
        return Err("invalid authentication token".into());
    }

    match role {
        ROLE_DATA => handle_data_connection(stream, registry, active_count, last_activity),
        ROLE_CONTROL => handle_control_connection(stream, registry),
        _ => {
            let _ = write_handshake_err(&mut stream, b"EROLE");
            Err(format!("unsupported connection role: {}", role).into())
        }
    }
}

fn handle_data_connection(
    mut stream: vsock::VsockStream,
    registry: SessionRegistry,
    active_count: Arc<AtomicU32>,
    last_activity: Arc<Mutex<Instant>>,
) -> Result<(), Box<dyn std::error::Error>> {
    let handshake = read_data_handshake(&mut stream)?;

    let pty_id = NEXT_PTY_ID.fetch_add(1, Ordering::SeqCst);

    log::info!(
        "Connection {}: shell={}, size={}x{}, cwd={:?}",
        pty_id,
        handshake.shell,
        handshake.cols,
        handshake.rows,
        handshake.cwd,
    );

    let child = PtyChild::spawn(
        &handshake.shell,
        handshake.cols,
        handshake.rows,
        handshake.cwd.as_deref(),
    )?;
    let _child_cleanup = ChildCleanup(&child);

    // Set initial pixel dimensions (spawn only sets character dimensions).
    if handshake.xpixel > 0 || handshake.ypixel > 0 {
        let _ = child.resize(
            handshake.cols,
            handshake.rows,
            handshake.xpixel,
            handshake.ypixel,
        );
    }

    log::info!("Connection {}: child PID {}", pty_id, child.child_pid);

    let control = Arc::new(SessionControl::new()?);
    let session_id = register_session(&registry, Arc::clone(&control));
    let _session_guard = SessionGuard {
        registry: Arc::clone(&registry),
        session_id,
    };
    active_count.fetch_add(1, Ordering::SeqCst);
    let _connection_guard = ConnectionGuard {
        count: active_count,
        activity: last_activity,
    };

    // Send handshake response.
    write_handshake_ok(&mut stream, pty_id, &session_id)?;

    // Run the bridge loop over the socket fd.
    let fd = stream.as_raw_fd();
    match bridge::run_with_fd(&child, fd, &control) {
        Ok(code) => {
            log::info!("Connection {}: child exited with code {}", pty_id, code);
            Ok(())
        }
        Err(e) => {
            log::error!(
                "Connection {}: bridge error: {}, cleaning up child",
                pty_id,
                e
            );
            // Kill and wait for the child to prevent zombie processes.
            child.wait_or_kill();
            Err(e)
        }
    }
}

/// Ensure handshake and bridge errors cannot leave an unreaped PTY child.
struct ChildCleanup<'a>(&'a PtyChild);

impl Drop for ChildCleanup<'_> {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            self.0.wait_or_kill();
        }
    }
}

fn register_session(registry: &SessionRegistry, control: Arc<SessionControl>) -> SessionId {
    loop {
        let mut session_id = [0u8; 16];
        rand::thread_rng().fill(&mut session_id);

        let mut sessions = registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let std::collections::hash_map::Entry::Vacant(entry) = sessions.entry(session_id) {
            entry.insert(control);
            return session_id;
        }
    }
}

struct SessionGuard {
    registry: SessionRegistry,
    session_id: SessionId,
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        let mut sessions = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        sessions.remove(&self.session_id);
    }
}

// ─── Token Generation ──────────────────────────────────────────────

/// Generate a cryptographically random 32-byte token.
fn generate_token() -> [u8; TOKEN_LEN] {
    let mut token = [0u8; TOKEN_LEN];
    rand::thread_rng().fill(&mut token);
    token
}

/// Write the token file with port and hex-encoded token.
/// File is created with mode 0600 (owner-only read/write).
fn write_token_file(port: u32, token: &[u8; TOKEN_LEN]) -> Result<(), Box<dyn std::error::Error>> {
    let hex: String = token.iter().map(|b| format!("{:02x}", b)).collect();
    let content = format!("PORT {}\nTOKEN {}\n", port, hex);
    let path = token_file_path(port);

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?;
    file.write_all(content.as_bytes())?;
    Ok(())
}

/// Constant-time comparison of two token buffers.
fn constant_time_eq(a: &[u8; TOKEN_LEN], b: &[u8; TOKEN_LEN]) -> bool {
    let mut diff: u8 = 0;
    for i in 0..TOKEN_LEN {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

// ─── Connection Protocol ───────────────────────────────────────────

fn read_connection_preamble(
    stream: &mut impl Read,
) -> Result<(u8, [u8; TOKEN_LEN]), Box<dyn std::error::Error>> {
    let mut magic = [0u8; 5];
    stream.read_exact(&mut magic)?;
    if magic != *HANDSHAKE_MAGIC {
        if &magic[..4] == b"GWSL" {
            return Err(format!("unsupported handshake version: {:#x}", magic[4]).into());
        }
        return Err("invalid handshake magic".into());
    }

    let mut role = [0u8; 1];
    stream.read_exact(&mut role)?;

    let mut token = [0u8; TOKEN_LEN];
    stream.read_exact(&mut token)?;

    Ok((role[0], token))
}

fn read_data_handshake(stream: &mut impl Read) -> Result<Handshake, Box<dyn std::error::Error>> {
    // Read fixed header: cols, rows, xpixel, ypixel (4 x u16be = 8 bytes).
    let mut header = [0u8; 8];
    stream.read_exact(&mut header)?;
    let cols = u16::from_be_bytes([header[0], header[1]]);
    let rows = u16::from_be_bytes([header[2], header[3]]);
    let xpixel = u16::from_be_bytes([header[4], header[5]]);
    let ypixel = u16::from_be_bytes([header[6], header[7]]);

    // Read shell path.
    let shell = read_length_prefixed_string(stream)?;

    // Read cwd (empty string means default).
    let cwd_str = read_length_prefixed_string(stream)?;
    let cwd = if cwd_str.is_empty() {
        None
    } else {
        Some(cwd_str)
    };

    // Use default shell if none specified.
    let shell = if shell.is_empty() {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
    } else {
        shell
    };

    Ok(Handshake {
        cols,
        rows,
        xpixel,
        ypixel,
        shell,
        cwd,
    })
}

/// Read a length-prefixed UTF-8 string (u16be length + bytes).
fn read_length_prefixed_string(
    stream: &mut impl Read,
) -> Result<String, Box<dyn std::error::Error>> {
    let mut len_buf = [0u8; 2];
    stream.read_exact(&mut len_buf)?;
    let len = u16::from_be_bytes(len_buf) as usize;

    if len == 0 {
        return Ok(String::new());
    }

    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf)?;
    Ok(String::from_utf8(buf)?)
}

/// Send the data handshake response with a diagnostic ID and capability.
fn write_handshake_ok(
    stream: &mut impl Write,
    pty_id: u32,
    session_id: &SessionId,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut buf = [0u8; 23]; // "OK\x02" + u32be + session_id
    buf[0] = b'O';
    buf[1] = b'K';
    buf[2] = 0x02;
    buf[3..7].copy_from_slice(&pty_id.to_be_bytes());
    buf[7..23].copy_from_slice(session_id);
    stream.write_all(&buf)?;
    stream.flush()?;
    Ok(())
}

fn handle_control_connection(
    mut stream: vsock::VsockStream,
    registry: SessionRegistry,
) -> Result<(), Box<dyn std::error::Error>> {
    stream.write_all(b"OKC\x01")?;
    stream.flush()?;

    loop {
        let mut header = [0u8; 3];
        match stream.read_exact(&mut header) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error.into()),
        }

        let message_type = header[0];
        let payload_len = u16::from_be_bytes([header[1], header[2]]) as usize;
        if payload_len > MAX_CONTROL_PAYLOAD {
            return Err(format!("control payload too large: {}", payload_len).into());
        }

        let mut payload = vec![0u8; payload_len];
        stream.read_exact(&mut payload)?;
        dispatch_control(message_type, &payload, &registry)?;
    }
}

fn dispatch_control(
    message_type: u8,
    payload: &[u8],
    registry: &SessionRegistry,
) -> Result<(), Box<dyn std::error::Error>> {
    let expected_len = match message_type {
        CONTROL_RESIZE => 32,
        CONTROL_SIGNAL => 20,
        _ => return Err(format!("unknown control message type: {}", message_type).into()),
    };
    if payload.len() != expected_len {
        return Err(format!(
            "invalid control payload length for type {}: {}",
            message_type,
            payload.len()
        )
        .into());
    }

    let mut session_id = [0u8; 16];
    session_id.copy_from_slice(&payload[..16]);
    let control = {
        let sessions = registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        sessions.get(&session_id).cloned()
    };
    let Some(control) = control else {
        log::debug!("control command for expired session");
        return Ok(());
    };

    match message_type {
        CONTROL_RESIZE => {
            let serial = u64::from_be_bytes(payload[16..24].try_into().unwrap());
            let cols = u16::from_be_bytes(payload[24..26].try_into().unwrap());
            let rows = u16::from_be_bytes(payload[26..28].try_into().unwrap());
            let xpixel = u16::from_be_bytes(payload[28..30].try_into().unwrap());
            let ypixel = u16::from_be_bytes(payload[30..32].try_into().unwrap());
            if cols == 0 || rows == 0 {
                log::warn!("dropping resize with zero rows or columns");
                return Ok(());
            }
            control.enqueue_resize(serial, cols, rows, xpixel, ypixel);
        }
        CONTROL_SIGNAL => {
            let signum = i32::from_be_bytes(payload[16..20].try_into().unwrap());
            if nix::sys::signal::Signal::try_from(signum).is_err() {
                return Err(format!("invalid signal: {}", signum).into());
            }
            control.enqueue_signal(signum);
        }
        _ => unreachable!(),
    }

    Ok(())
}

/// Send an error response (e.g., authentication failure).
fn write_handshake_err(
    stream: &mut impl Write,
    code: &[u8],
) -> Result<(), Box<dyn std::error::Error>> {
    let mut buf = [0u8; 8]; // "ERR" + up to 5 bytes of error code
    buf[0] = b'E';
    buf[1] = b'R';
    buf[2] = b'R';
    let len = code.len().min(5);
    buf[3..3 + len].copy_from_slice(&code[..len]);
    stream.write_all(&buf[..3 + len])?;
    stream.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn build_handshake(
        token: &[u8; TOKEN_LEN],
        shell: &str,
        cwd: &str,
        cols: u16,
        rows: u16,
    ) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(HANDSHAKE_MAGIC);
        buf.push(ROLE_DATA);
        buf.extend_from_slice(token);
        buf.extend_from_slice(&cols.to_be_bytes());
        buf.extend_from_slice(&rows.to_be_bytes());
        buf.extend_from_slice(&0u16.to_be_bytes()); // xpixel
        buf.extend_from_slice(&0u16.to_be_bytes()); // ypixel
        buf.extend_from_slice(&(shell.len() as u16).to_be_bytes());
        buf.extend_from_slice(shell.as_bytes());
        buf.extend_from_slice(&(cwd.len() as u16).to_be_bytes());
        buf.extend_from_slice(cwd.as_bytes());
        buf
    }

    #[test]
    fn test_handshake_roundtrip() {
        let token = [0xAB; TOKEN_LEN];
        let data = build_handshake(&token, "/bin/zsh", "/home/user", 120, 40);
        let mut cursor = Cursor::new(data);
        let (role, parsed_token) = read_connection_preamble(&mut cursor).unwrap();
        let hs = read_data_handshake(&mut cursor).unwrap();
        assert_eq!(role, ROLE_DATA);
        assert_eq!(parsed_token, token);
        assert_eq!(hs.shell, "/bin/zsh");
        assert_eq!(hs.cwd, Some("/home/user".to_string()));
        assert_eq!(hs.cols, 120);
        assert_eq!(hs.rows, 40);
        assert_eq!(hs.xpixel, 0);
        assert_eq!(hs.ypixel, 0);
    }

    #[test]
    fn test_handshake_empty_shell_defaults() {
        let token = [0x00; TOKEN_LEN];
        let data = build_handshake(&token, "", "", 80, 24);
        let mut cursor = Cursor::new(data);
        read_connection_preamble(&mut cursor).unwrap();
        let hs = read_data_handshake(&mut cursor).unwrap();
        // Empty shell should default to $SHELL or /bin/sh.
        assert!(!hs.shell.is_empty());
        assert!(hs.cwd.is_none());
    }

    #[test]
    fn test_handshake_bad_magic() {
        let data = b"BADM\x01\x00\x50\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00";
        let mut cursor = Cursor::new(data);
        assert!(read_connection_preamble(&mut cursor).is_err());
    }

    #[test]
    fn test_handshake_v1_rejected() {
        // v1 magic should be rejected by v3 daemon.
        let mut buf = Vec::new();
        buf.extend_from_slice(b"GWSL\x01");
        buf.extend_from_slice(&80u16.to_be_bytes());
        buf.extend_from_slice(&24u16.to_be_bytes());
        buf.extend_from_slice(&0u16.to_be_bytes());
        buf.extend_from_slice(&0u16.to_be_bytes());
        buf.extend_from_slice(&0u16.to_be_bytes()); // shell len
        buf.extend_from_slice(&0u16.to_be_bytes()); // cwd len
        let mut cursor = Cursor::new(buf);
        let err = read_connection_preamble(&mut cursor).unwrap_err();
        assert!(err.to_string().contains("unsupported handshake version"));
    }

    #[test]
    fn test_handshake_ok_response() {
        let mut buf = Vec::new();
        let session_id = [0xAB; 16];
        write_handshake_ok(&mut buf, 42, &session_id).unwrap();
        assert_eq!(&buf[0..3], b"OK\x02");
        let pty_id = u32::from_be_bytes([buf[3], buf[4], buf[5], buf[6]]);
        assert_eq!(pty_id, 42);
        assert_eq!(&buf[7..23], &session_id);
    }

    #[test]
    fn test_resize_control_dispatch() {
        let registry: SessionRegistry = Arc::new(Mutex::new(HashMap::new()));
        let session_id = [0xCD; 16];
        let control = Arc::new(SessionControl::new().unwrap());
        registry
            .lock()
            .unwrap()
            .insert(session_id, Arc::clone(&control));

        let mut payload = Vec::new();
        payload.extend_from_slice(&session_id);
        payload.extend_from_slice(&7u64.to_be_bytes());
        payload.extend_from_slice(&120u16.to_be_bytes());
        payload.extend_from_slice(&40u16.to_be_bytes());
        payload.extend_from_slice(&1920u16.to_be_bytes());
        payload.extend_from_slice(&1080u16.to_be_bytes());
        dispatch_control(CONTROL_RESIZE, &payload, &registry).unwrap();

        assert_eq!(
            control.take_commands()[0],
            crate::control::Command::Resize {
                serial: 7,
                cols: 120,
                rows: 40,
                xpixel: 1920,
                ypixel: 1080,
            }
        );
    }

    #[test]
    fn test_zero_sized_resize_is_dropped_without_closing_control_stream() {
        let registry: SessionRegistry = Arc::new(Mutex::new(HashMap::new()));
        let session_id = [0xEF; 16];
        let control = Arc::new(SessionControl::new().unwrap());
        registry
            .lock()
            .unwrap()
            .insert(session_id, Arc::clone(&control));

        let mut payload = Vec::new();
        payload.extend_from_slice(&session_id);
        payload.extend_from_slice(&1u64.to_be_bytes());
        payload.extend_from_slice(&0u16.to_be_bytes());
        payload.extend_from_slice(&24u16.to_be_bytes());
        payload.extend_from_slice(&0u16.to_be_bytes());
        payload.extend_from_slice(&0u16.to_be_bytes());

        dispatch_control(CONTROL_RESIZE, &payload, &registry).unwrap();
        assert!(control.take_commands().is_empty());
    }

    #[test]
    fn test_handshake_err_response() {
        let mut buf = Vec::new();
        write_handshake_err(&mut buf, b"EAUTH").unwrap();
        assert_eq!(&buf[0..3], b"ERR");
        assert_eq!(&buf[3..8], b"EAUTH");
    }

    #[test]
    fn test_constant_time_eq_equal() {
        let a = [0x42; TOKEN_LEN];
        let b = [0x42; TOKEN_LEN];
        assert!(constant_time_eq(&a, &b));
    }

    #[test]
    fn test_constant_time_eq_different() {
        let a = [0x42; TOKEN_LEN];
        let mut b = [0x42; TOKEN_LEN];
        b[TOKEN_LEN - 1] = 0x43;
        assert!(!constant_time_eq(&a, &b));
    }

    #[test]
    fn test_token_generation() {
        let t1 = generate_token();
        let t2 = generate_token();
        // Two random tokens should (almost certainly) be different.
        assert_ne!(t1, t2);
        // Should not be all zeros.
        assert_ne!(t1, [0u8; TOKEN_LEN]);
    }

    #[test]
    fn test_token_file_roundtrip() {
        let dir = std::env::temp_dir();
        let path = dir.join("ghostwsl_test_token");
        let token = [0xAB; TOKEN_LEN];

        // Write using our format.
        let hex: String = token.iter().map(|b| format!("{:02x}", b)).collect();
        let content = format!("PORT {}\nTOKEN {}\n", 48470, hex);
        std::fs::write(&path, &content).unwrap();

        // Read back and parse.
        let data = std::fs::read_to_string(&path).unwrap();
        let mut found_port = false;
        let mut found_token = false;
        for line in data.lines() {
            if let Some(port_str) = line.strip_prefix("PORT ") {
                assert_eq!(port_str.trim(), "48470");
                found_port = true;
            }
            if let Some(hex_str) = line.strip_prefix("TOKEN ") {
                assert_eq!(hex_str.trim().len(), 64);
                // Decode hex and compare.
                let decoded: Vec<u8> = (0..32)
                    .map(|i| u8::from_str_radix(&hex_str.trim()[i * 2..i * 2 + 2], 16).unwrap())
                    .collect();
                assert_eq!(decoded, token);
                found_token = true;
            }
        }
        assert!(found_port);
        assert!(found_token);

        let _ = std::fs::remove_file(&path);
    }
}
