//! VsockBridge manages vsock (AF_HYPERV) connections to WSL PTY daemons.
//!
//! This is the sole connection method — there is no wsl.exe relay fallback.
//! The open() function is self-bootstrapping: on first connect failure, it
//! deploys the bridge binary, registers the Hyper-V service GUID, starts
//! the daemon, and retries with exponential backoff.
//!
//! Each WSL distro gets its own daemon on a unique vsock port:
//!   Default distro: port 48470
//!   Named distros:  port 48471 + (fnv1a(name) % 1000)
//!
//! Fast path (daemon already running): ~10ms
//! Cold bootstrap (first tab ever):    ~3-5s
const VsockBridge = @This();

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("../../os/main.zig").windows;
const ptypkg = @import("../../pty.zig");

const log = std.log.scoped(.vsock_bridge);
const wsl_log = @import("wsl_log.zig");

// ─── Constants ────────────────────────────────────────────────────────

/// Win32 constant: CREATE_NO_WINDOW (0x08000000).
const CREATE_NO_WINDOW: windows.DWORD = 0x08000000;

/// Base vsock port for the default distro.
const BASE_PORT: u32 = 48470;

/// Path to the bridge binary inside WSL (uses $HOME for sh expansion).
const BRIDGE_SHELL_PATH = "$HOME/.local/bin/wsl-pty-bridge";
/// For display/logging only.
const BRIDGE_DISPLAY_PATH = "~/.local/bin/wsl-pty-bridge";

/// The embedded bridge binary (built from wsl-pty-bridge Rust crate).
/// Must be a static-pie musl binary (~1.4MB). A dynamically linked binary
/// will fail inside WSL if the target distro lacks the required shared libs.
const embedded_bridge = blk: {
    const data = @embedFile("wsl-pty-bridge.bin");
    // Sanity check: static musl binary is >100KB. A dynamically linked
    // build is typically <50KB and won't run reliably across distros.
    if (data.len < 100_000) {
        @compileError("wsl-pty-bridge.bin is too small (" ++
            std.fmt.comptimePrint("{d}", .{data.len}) ++
            " bytes). Did you build with --target x86_64-unknown-linux-musl?");
    }
    break :blk data;
};

/// Cached FNV-1a hash of the embedded bridge binary for version detection.
/// Computed once at runtime (microseconds for ~1.4MB) — comptime would be
/// too slow for the Zig compiler at this data size.
var bridge_hash_cached: u64 = 0;
var bridge_hash_ready = std.atomic.Value(bool).init(false);

fn getEmbeddedBridgeHash() u64 {
    if (bridge_hash_ready.load(.acquire)) return bridge_hash_cached;
    bridge_hash_cached = std.hash.Fnv1a_64.hash(embedded_bridge);
    bridge_hash_ready.store(true, .release);
    return bridge_hash_cached;
}

/// The embedded terminfo source for xterm-ghostty.
const embedded_terminfo = @embedFile("ghostty.terminfo");

// ─── Winsock2 / AF_HYPERV declarations ──────────────────────────────

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
const SOCKET_ERROR: i32 = -1;

const AF_HYPERV: i32 = 34;
const SOCK_STREAM: i32 = 1;
const HV_PROTOCOL_RAW: i32 = 1;

const WSA_FLAG_OVERLAPPED: u32 = 0x01;

const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667e));
const WSAEWOULDBLOCK: i32 = 10035;

/// Connect timeout in milliseconds. 500ms is enough for vsock
/// (kernel-to-kernel) and fast-fails when no daemon is listening.
const CONNECT_TIMEOUT_MS: i32 = 500;

/// Winsock fd_set: count + array of SOCKETs.
const FD_SETSIZE = 64;
const fd_set = extern struct {
    fd_count: u32,
    fd_array: [FD_SETSIZE]SOCKET,
};

/// Winsock timeval for select().
const timeval = extern struct {
    tv_sec: i32,
    tv_usec: i32,
};

const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

/// GUID structure for AF_HYPERV addressing.
const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// SOCKADDR_HV — address structure for AF_HYPERV sockets.
const SOCKADDR_HV = extern struct {
    Family: u16,
    Reserved: u16,
    VmId: GUID,
    ServiceId: GUID,
};

// ─── Win32 function imports ─────────────────────────────────────────

extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.winapi) i32;
extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
extern "ws2_32" fn WSASocketA(af: i32, socket_type: i32, protocol: i32, lpProtocolInfo: ?*anyopaque, g: u32, dwFlags: u32) callconv(.winapi) SOCKET;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, argp: *u32) callconv(.winapi) i32;

const select_fn = struct {
    extern "ws2_32" fn select(nfds: i32, readfds: ?*fd_set, writefds: ?*fd_set, exceptfds: ?*fd_set, timeout: ?*const timeval) callconv(.winapi) i32;
}.select;

// Comptime struct pattern for Winsock functions that clash with Zig keywords/stdlib names
const connect_fn = struct {
    extern "ws2_32" fn connect(s: SOCKET, name: *const SOCKADDR_HV, namelen: i32) callconv(.winapi) i32;
}.connect;
const send_fn = struct {
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
}.send;
const recv_fn = struct {
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
}.recv;

/// Win32 constant: WAIT_TIMEOUT (0x00000102).
const WAIT_TIMEOUT: windows.DWORD = 0x00000102;

// ─── VsockBridge struct ─────────────────────────────────────────────

/// The vsock socket, used as both read and write handle.
socket: SOCKET,

/// Current terminal size.
size: ptypkg.winsize,

/// PTY ID assigned by the daemon.
pty_id: u32,

pub const Error = error{
    WsaStartupFailed,
    SocketCreateFailed,
    ConnectFailed,
    HandshakeFailed,
    DaemonStartFailed,
    DeployFailed,
    Unexpected,
};

pub const Config = struct {
    /// WSL distribution name. null = default distribution.
    distro: ?[:0]const u8 = null,
    /// Shell to launch inside WSL. null = distribution default.
    shell: ?[:0]const u8 = null,
    /// Initial terminal size.
    size: ptypkg.winsize = .{},
    /// Working directory inside WSL.
    cwd: ?[:0]const u8 = null,
};

// ─── Process-wide state ─────────────────────────────────────────────

/// Thread-safe VM ID cache.
var vm_id_ready = std.atomic.Value(bool).init(false);
var vm_id_storage: GUID = undefined;
var wsa_initialized = std.atomic.Value(bool).init(false);

/// Bridge deployment guard (default distro fast path).
var bridge_deployed = std.atomic.Value(bool).init(false);

/// Thread-safe per-port authentication token cache.
/// Each daemon has its own token, so we cache per port.
var token_cache: std.AutoHashMap(u32, [32]u8) = std.AutoHashMap(u32, [32]u8).init(std.heap.page_allocator);
var token_cache_lock: std.Thread.Mutex = .{};

// ─── Public API ─────────────────────────────────────────────────────

/// Ensure WSL is running by executing a trivial command.
/// On cold start this blocks ~10-15s while WSL boots.
/// On warm start this returns in ~100ms.
/// Idempotent and safe to call from multiple threads.
pub fn ensureWslRunning(distro: ?[:0]const u8) void {
    var cmd_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("wsl.exe") catch return;
    if (distro) |d| {
        writer.print(" -d {s}", .{d}) catch return;
    }
    writer.writeAll(" -- true") catch return;

    const cmd_line = fbs.getWritten();

    var cmd_w_buf: [256]u16 = undefined;
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_line) catch return;
    cmd_w_buf[cmd_w_len] = 0;

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);

    var process_info: windows.PROCESS_INFORMATION = undefined;

    wsl_log.print("ensureWslRunning: launching {s}", .{cmd_line});

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.FALSE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        wsl_log.print("ensureWslRunning: CreateProcessW failed", .{});
        return;
    }

    defer _ = windows.CloseHandle(process_info.hProcess);
    defer _ = windows.CloseHandle(process_info.hThread);

    // Wait up to 30s for WSL to boot
    _ = windows.kernel32.WaitForSingleObject(process_info.hProcess, 30000);

    var exit_code: windows.DWORD = 1;
    _ = windows.kernel32.GetExitCodeProcess(process_info.hProcess, &exit_code);

    wsl_log.print("ensureWslRunning: done (exit_code={d})", .{exit_code});
}

/// Open a vsock connection to the WSL PTY daemon.
///
/// Sequential bootstrap: ensures WSL is running, deploys the bridge,
/// discovers VM ID, then connects. All wsl.exe calls are serialized
/// to avoid overwhelming WSL's init process during cold boot.
pub fn open(config: Config) Error!VsockBridge {
    const port = portForDistro(config.distro);
    const service_guid = makeVsockServiceGuid(port);

    wsl_log.print("VsockBridge.open: distro={s} port={d}", .{
        if (config.distro) |d| @as([]const u8, d) else "(default)", port,
    });

    // 1. Initialize Winsock2 (process-wide, idempotent).
    ensureWsa() catch return error.WsaStartupFailed;

    // 2. Ensure WSL is running (idempotent, fast if bg thread already did this).
    ensureWslRunning(config.distro);

    // 3. Deploy bridge binary + install terminfo (idempotent, fast since WSL is up).
    ensureDeployed(config) catch |err| {
        wsl_log.print("VsockBridge.open: deploy failed: {s}", .{@errorName(err)});
    };

    // 4. Discover VM ID (WSL is running, so this should succeed).
    if (!vm_id_ready.load(.acquire)) {
        discoverAndCacheVmId(config.distro);
    }

    // 5. Fast path: try connecting to an existing daemon.
    if (vm_id_ready.load(.acquire)) {
        const vm_id = vm_id_storage;
        if (tryConnect(vm_id, service_guid)) |sock| {
            wsl_log.print("VsockBridge.open: fast path connected", .{});
            if (getTokenForPort(port) == null) {
                readAndCacheToken(config.distro, port);
            }
            if (tryHandshake(sock, config, port, vm_id, service_guid)) |bridge| {
                return bridge;
            } else |_| {
                wsl_log.print("VsockBridge.open: fast path handshake failed", .{});
            }
        }
    }

    // 6. Cold path: start daemon, then retry with short backoffs.
    //    WSL is already booted, so daemon starts in ~1s.
    wsl_log.print("VsockBridge.open: starting daemon...", .{});
    _ = startDaemon(config.distro, port) catch {};

    // New daemon means new token; VM ID might also be stale.
    vm_id_ready.store(false, .release);
    invalidateTokenForPort(port);

    const delays = [_]u64{ 500, 500, 1000, 2000, 3000 };
    for (delays, 0..) |delay_ms, attempt| {
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);

        if (!vm_id_ready.load(.acquire)) {
            discoverAndCacheVmId(config.distro);
        }

        if (vm_id_ready.load(.acquire)) {
            const vm_id = vm_id_storage;
            if (tryConnect(vm_id, service_guid)) |sock| {
                wsl_log.print("VsockBridge.open: connected on attempt {d}", .{attempt});
                if (getTokenForPort(port) == null) {
                    readAndCacheToken(config.distro, port);
                }
                if (tryHandshake(sock, config, port, vm_id, service_guid)) |bridge| {
                    return bridge;
                } else |_| {
                    wsl_log.print("VsockBridge.open: cold path handshake failed on attempt {d}", .{attempt});
                }
            }
        }
    }

    wsl_log.print("VsockBridge.open: all retries exhausted", .{});
    return error.ConnectFailed;
}

/// Close the vsock connection.
pub fn deinit(self: *VsockBridge) void {
    _ = closesocket(self.socket);
    self.* = undefined;
}

/// Get the socket as a Windows HANDLE for ReadFile/WriteFile.
pub fn socketAsHandle(self: VsockBridge) windows.HANDLE {
    return @ptrFromInt(self.socket);
}

/// Get the current size.
pub fn getSize(self: VsockBridge) ptypkg.winsize {
    return self.size;
}

/// Discover the VM ID and cache it for future vsock attempts.
pub fn discoverAndCacheVmId(distro: ?[:0]const u8) void {
    if (vm_id_ready.load(.acquire)) {
        wsl_log.print("discoverAndCacheVmId: already cached, skipping", .{});
        return;
    }
    wsl_log.print("discoverAndCacheVmId: running wslinfo --vm-id", .{});
    if (discoverVmId(distro)) |id| {
        vm_id_storage = id;
        vm_id_ready.store(true, .release);
        log.info("vsock: VM ID cached for future tabs", .{});
        wsl_log.print("discoverAndCacheVmId: success (Data1=0x{x:0>8})", .{id.Data1});
    } else {
        wsl_log.print("discoverAndCacheVmId: wslinfo returned null (not available?)", .{});
    }
}

/// Read and cache the authentication token for future vsock handshakes.
/// Tokens are cached per-port since each daemon has its own token.
pub fn readAndCacheToken(distro: ?[:0]const u8, port: u32) void {
    token_cache_lock.lock();
    if (token_cache.contains(port)) {
        token_cache_lock.unlock();
        wsl_log.print("readAndCacheToken: already cached for port {d}", .{port});
        return;
    }
    token_cache_lock.unlock();

    wsl_log.print("readAndCacheToken: reading token file for port {d}", .{port});
    if (readToken(distro, port)) |tok| {
        token_cache_lock.lock();
        token_cache.put(port, tok) catch {};
        token_cache_lock.unlock();
        wsl_log.print("readAndCacheToken: success (port {d})", .{port});
    } else {
        wsl_log.print("readAndCacheToken: failed to read token file", .{});
    }
}

/// Try handshake with cached token. On HandshakeFailed, invalidate
/// the cached token, re-read from file, reconnect, and retry once.
/// This handles daemon restarts where the token file is new but our
/// cache is stale.
fn tryHandshake(
    sock: SOCKET,
    config: Config,
    port: u32,
    vm_id: GUID,
    service_guid: GUID,
) Error!VsockBridge {
    const token = getTokenForPort(port) orelse return error.HandshakeFailed;
    return doHandshake(sock, config, token) catch |err| {
        if (err != error.HandshakeFailed) return err;
        // Stale token — invalidate, re-read, reconnect, retry once.
        wsl_log.print("tryHandshake: stale token for port {d}, retrying", .{port});
        invalidateTokenForPort(port);
        readAndCacheToken(config.distro, port);
        const new_token = getTokenForPort(port) orelse return error.HandshakeFailed;
        const new_sock = tryConnect(vm_id, service_guid) orelse return error.ConnectFailed;
        return doHandshake(new_sock, config, new_token);
    };
}

/// Look up a cached token for the given port. Returns null if not cached.
fn getTokenForPort(port: u32) ?[32]u8 {
    token_cache_lock.lock();
    defer token_cache_lock.unlock();
    return token_cache.get(port);
}

/// Invalidate the cached token for a given port (e.g. after restarting a daemon).
fn invalidateTokenForPort(port: u32) void {
    token_cache_lock.lock();
    defer token_cache_lock.unlock();
    _ = token_cache.remove(port);
}

/// Start the daemon in the background without blocking the caller.
pub fn startDaemonBackground(distro: ?[:0]const u8) void {
    const port = portForDistro(distro);
    wsl_log.print("startDaemonBackground: starting daemon on port {d}", .{port});
    startDaemon(distro, port) catch |err| {
        log.warn("failed to start daemon in background: {}", .{err});
        wsl_log.print("startDaemonBackground: failed ({s})", .{@errorName(err)});
    };
}

/// Start a lightweight WSL keepalive process.
/// Returns the process handle (caller owns it) or null on failure.
/// Runs `wsl.exe [-d distro] -- sleep infinity` which keeps the WSL VM
/// alive as long as the process is running. Caller should TerminateProcess
/// and CloseHandle when the app exits.
pub fn startKeepalive(distro: ?[:0]const u8) ?windows.HANDLE {
    var cmd_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("wsl.exe") catch return null;
    if (distro) |d| {
        writer.print(" -d {s}", .{d}) catch return null;
    }
    writer.writeAll(" -- sleep infinity") catch return null;

    const cmd_line = fbs.getWritten();

    var cmd_w_buf: [256]u16 = undefined;
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_line) catch return null;
    cmd_w_buf[cmd_w_len] = 0;

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);

    var process_info: windows.PROCESS_INFORMATION = undefined;

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.FALSE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        log.warn("failed to start WSL keepalive: {}", .{windows.kernel32.GetLastError()});
        return null;
    }

    _ = windows.CloseHandle(process_info.hThread);
    log.info("WSL keepalive started (pid=wsl.exe)", .{});
    wsl_log.print("startKeepalive: wsl.exe -- sleep infinity launched", .{});
    return process_info.hProcess;
}

/// Compute a deterministic vsock port for a WSL distro.
pub fn portForDistro(distro: ?[:0]const u8) u32 {
    const name = distro orelse return BASE_PORT;
    // FNV-1a hash
    var hash: u32 = 2166136261;
    for (name) |c| {
        hash ^= c;
        hash *%= 16777619;
    }
    return BASE_PORT + 1 + (hash % 1000);
}

// ─── Bridge Deployment ──────────────────────────────────────────────

/// Hash sidecar path inside WSL (alongside the bridge binary).
const BRIDGE_HASH_SHELL_PATH = "$HOME/.local/bin/wsl-pty-bridge.hash";

/// Ensure the embedded bridge binary and terminfo are deployed inside WSL.
///
/// Consolidated into a SINGLE wsl.exe invocation to minimize interop load.
/// The shell script checks the hash sidecar first; if it matches, only
/// terminfo is verified. If it differs (or is missing), the bridge binary
/// is read from stdin, deployed via atomic rename, the hash is written,
/// the old daemon is killed, and terminfo is installed.
///
/// Stdin protocol: bridge binary bytes (exactly embedded_bridge.len),
/// followed by terminfo source bytes (rest of stream until EOF).
/// The shell script uses `head -c N` to split the two.
pub fn ensureDeployed(config: Config) Error!void {
    // Fast-path for default distro: skip if already deployed this session.
    if (config.distro == null and bridge_deployed.load(.acquire)) return;

    log.info("ensureDeployed: checking bridge + terminfo (single wsl.exe call)", .{});
    wsl_log.print("ensureDeployed: starting consolidated deploy check", .{});

    var hash_str_buf: [18]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_str_buf, "{x}", .{getEmbeddedBridgeHash()}) catch
        return error.Unexpected;

    // Build the consolidated shell command.
    // The script:
    //   1. Checks hash sidecar — if match, drains stdin, checks terminfo, exits
    //   2. On mismatch: reads binary from stdin (head -c N), deploys atomically,
    //      writes hash, kills old daemon, then reads+installs terminfo from stdin
    var cmd_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("wsl.exe") catch return error.Unexpected;
    if (config.distro) |distro| {
        writer.print(" -d {s}", .{distro}) catch return error.Unexpected;
    }
    writer.print(
        " -- sh -c '" ++
            "HASH_FILE={s}; " ++
            "EXPECTED={s}; " ++
            "BIN_PATH={s}; " ++
            "BIN_LEN={d}; " ++
            "CURRENT=$(cat \"$HASH_FILE\" 2>/dev/null); " ++
            "if [ \"$CURRENT\" = \"$EXPECTED\" ]; then " ++
            "  cat >/dev/null; " ++ // drain stdin (binary + terminfo)
            "  infocmp xterm-ghostty >/dev/null 2>&1 || {{ " ++
            "    command -v tic >/dev/null 2>&1 && exit 2; " ++ // exit 2 = needs terminfo with tic
            "  }}; " ++
            "  exit 0; " ++ // hash match, terminfo OK
            "fi; " ++
            // Hash mismatch: deploy new binary
            "mkdir -p \"$(dirname \"$BIN_PATH\")\" && " ++
            "head -c \"$BIN_LEN\" > \"$BIN_PATH.tmp\" && " ++
            "chmod +x \"$BIN_PATH.tmp\" && " ++
            "mv -f \"$BIN_PATH.tmp\" \"$BIN_PATH\" && " ++
            "echo \"$EXPECTED\" > \"$HASH_FILE\" && " ++
            "pkill -f \"[w]sl-pty-bridge --daemon\" 2>/dev/null || true; " ++ // [w] trick avoids self-match
            // Install terminfo from remaining stdin
            "infocmp xterm-ghostty >/dev/null 2>&1 && {{ cat >/dev/null; exit 0; }}; " ++
            "if command -v tic >/dev/null 2>&1; then " ++
            "  mkdir -p ~/.terminfo 2>/dev/null; tic -x - 2>/dev/null; " ++
            "else " ++
            "  cat >/dev/null; " ++ // drain remaining stdin
            "fi; " ++
            "exit 0" ++ // always succeed after binary deployed
            "'",
        .{
            BRIDGE_HASH_SHELL_PATH,
            hash_str,
            BRIDGE_SHELL_PATH,
            embedded_bridge.len,
        },
    ) catch return error.Unexpected;

    const cmd_line = fbs.getWritten();

    var cmd_w_buf: [2048]u16 = undefined;
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_line) catch
        return error.Unexpected;
    cmd_w_buf[cmd_w_len] = 0;

    // Create pipe to feed binary + terminfo through stdin
    var in_read: windows.HANDLE = undefined;
    var in_write: windows.HANDLE = undefined;
    if (windows.exp.kernel32.CreatePipe(&in_read, &in_write, null, 0) == 0) {
        return error.DeployFailed;
    }
    errdefer {
        _ = windows.CloseHandle(in_read);
        _ = windows.CloseHandle(in_write);
    }

    windows.SetHandleInformation(in_read, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT) catch
        return error.Unexpected;
    windows.SetHandleInformation(in_write, windows.HANDLE_FLAG_INHERIT, 0) catch
        return error.Unexpected;

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    startup_info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.hStdInput = in_read;

    var process_info: windows.PROCESS_INFORMATION = undefined;

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.TRUE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        _ = windows.CloseHandle(in_read);
        _ = windows.CloseHandle(in_write);
        return error.DeployFailed;
    }

    _ = windows.CloseHandle(in_read);
    defer _ = windows.CloseHandle(process_info.hProcess);
    defer _ = windows.CloseHandle(process_info.hThread);

    // Write bridge binary followed by terminfo source through the pipe.
    // The shell script uses `head -c BIN_LEN` to split the two.
    const payloads = [_][]const u8{ embedded_bridge, embedded_terminfo };
    for (payloads) |payload| {
        var total_written: usize = 0;
        while (total_written < payload.len) {
            var written: windows.DWORD = 0;
            if (windows.kernel32.WriteFile(
                in_write,
                payload[total_written..].ptr,
                @intCast(payload.len - total_written),
                &written,
                null,
            ) == 0) {
                _ = windows.CloseHandle(in_write);
                // Don't fail hard — the hash-match path drains stdin and
                // may close the pipe early. Check exit code below.
                break;
            }
            total_written += written;
        }
    }

    // Close write end to signal EOF
    _ = windows.CloseHandle(in_write);

    // Wait for completion (30 second timeout)
    _ = windows.kernel32.WaitForSingleObject(process_info.hProcess, 30000);

    var exit_code: windows.DWORD = 1;
    _ = windows.kernel32.GetExitCodeProcess(process_info.hProcess, &exit_code);

    if (exit_code == 0) {
        log.info("ensureDeployed: success (hash match or deploy+terminfo OK)", .{});
        wsl_log.print("ensureDeployed: exit_code=0 (up to date or deployed)", .{});
    } else if (exit_code == 2) {
        // Exit code 2 = hash matched but terminfo missing and tic is available.
        // Need a separate tic call with terminfo on stdin. This is rare (only
        // on first run after terminfo gets deleted).
        log.info("ensureDeployed: hash matched, installing terminfo separately", .{});
        wsl_log.print("ensureDeployed: exit_code=2, running tic for terminfo", .{});
        installTerminfoOnly(config);
    } else {
        log.err("ensureDeployed: failed with exit code {}", .{exit_code});
        wsl_log.print("ensureDeployed: exit_code={d}", .{exit_code});
        return error.DeployFailed;
    }

    // If we deployed a new binary, the daemon was killed by the script.
    // Invalidate cached token since the old daemon had a different one.
    // We detect this by checking if the hash was already cached — if it
    // was, we didn't deploy (just verified), so no token invalidation needed.
    if (!bridge_deployed.load(.acquire)) {
        // Deploy killed all daemons — invalidate all cached tokens.
        token_cache_lock.lock();
        token_cache.clearRetainingCapacity();
        token_cache_lock.unlock();
    }

    if (config.distro == null) {
        bridge_deployed.store(true, .release);
    }
}

/// Install terminfo only (used when hash matched but terminfo was missing).
/// This is the only case that needs a second wsl.exe call, and it's rare —
/// only on first run or if someone deletes their ~/.terminfo.
fn installTerminfoOnly(config: Config) void {
    var cmd_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("wsl.exe") catch return;
    if (config.distro) |distro| {
        writer.print(" -d {s}", .{distro}) catch return;
    }
    writer.writeAll(" -- sh -c \"mkdir -p ~/.terminfo 2>/dev/null; tic -x - 2>/dev/null\"") catch return;

    const cmd_line = fbs.getWritten();

    var cmd_w_buf: [512]u16 = undefined;
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_line) catch return;
    cmd_w_buf[cmd_w_len] = 0;

    var in_read: windows.HANDLE = undefined;
    var in_write: windows.HANDLE = undefined;
    if (windows.exp.kernel32.CreatePipe(&in_read, &in_write, null, 0) == 0) return;

    windows.SetHandleInformation(in_read, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT) catch {
        _ = windows.CloseHandle(in_read);
        _ = windows.CloseHandle(in_write);
        return;
    };
    windows.SetHandleInformation(in_write, windows.HANDLE_FLAG_INHERIT, 0) catch {
        _ = windows.CloseHandle(in_read);
        _ = windows.CloseHandle(in_write);
        return;
    };

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    startup_info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.hStdInput = in_read;

    var process_info: windows.PROCESS_INFORMATION = undefined;

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.TRUE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        _ = windows.CloseHandle(in_read);
        _ = windows.CloseHandle(in_write);
        return;
    }

    _ = windows.CloseHandle(in_read);
    defer _ = windows.CloseHandle(process_info.hProcess);
    defer _ = windows.CloseHandle(process_info.hThread);

    var total_written: usize = 0;
    while (total_written < embedded_terminfo.len) {
        var written: windows.DWORD = 0;
        if (windows.kernel32.WriteFile(
            in_write,
            embedded_terminfo[total_written..].ptr,
            @intCast(embedded_terminfo.len - total_written),
            &written,
            null,
        ) == 0) break;
        total_written += written;
    }

    _ = windows.CloseHandle(in_write);
    _ = windows.kernel32.WaitForSingleObject(process_info.hProcess, 10000);

    var exit_code: windows.DWORD = 1;
    _ = windows.kernel32.GetExitCodeProcess(process_info.hProcess, &exit_code);
    if (exit_code == 0) {
        log.info("xterm-ghostty terminfo installed successfully", .{});
    } else {
        log.warn("terminfo installation exited with code {}", .{exit_code});
    }
}

// ─── Distro Enumeration ─────────────────────────────────────────────

/// Enumerate installed WSL distributions.
///
/// Runs `wsl.exe -l -q` and parses the output (UTF-16LE).
pub fn listDistros(alloc: std.mem.Allocator) ![][]const u8 {
    var cmd_w_buf: [256]u16 = undefined;
    const cmd_str = "wsl.exe -l -q";
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_str) catch
        return error.Unexpected;
    cmd_w_buf[cmd_w_len] = 0;

    var out_read: windows.HANDLE = undefined;
    var out_write: windows.HANDLE = undefined;
    if (windows.exp.kernel32.CreatePipe(&out_read, &out_write, null, 0) == 0) {
        return error.Unexpected;
    }
    defer _ = windows.CloseHandle(out_read);

    windows.SetHandleInformation(out_write, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT) catch
        return error.Unexpected;
    windows.SetHandleInformation(out_read, windows.HANDLE_FLAG_INHERIT, 0) catch
        return error.Unexpected;

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    startup_info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.hStdOutput = out_write;
    startup_info.hStdError = out_write;

    var process_info: windows.PROCESS_INFORMATION = undefined;

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.TRUE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        _ = windows.CloseHandle(out_write);
        return error.Unexpected;
    }

    _ = windows.CloseHandle(out_write);
    defer _ = windows.CloseHandle(process_info.hProcess);
    defer _ = windows.CloseHandle(process_info.hThread);

    _ = windows.kernel32.WaitForSingleObject(process_info.hProcess, 5000);

    var output_buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < output_buf.len) {
        var bytes_read: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            out_read,
            output_buf[total_read..].ptr,
            @intCast(output_buf.len - total_read),
            &bytes_read,
            null,
        ) == 0) break;
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }

    const raw = output_buf[0..total_read];
    var distros: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (distros.items) |d| alloc.free(d);
        distros.deinit(alloc);
    }

    // Detect UTF-16LE encoding
    var utf16_start: usize = 0;
    const is_utf16 = blk: {
        if (raw.len >= 2 and raw[0] == 0xFF and raw[1] == 0xFE) {
            utf16_start = 2;
            break :blk true;
        }
        if (raw.len >= 4 and raw.len % 2 == 0) {
            var zeros: usize = 0;
            var checked: usize = 0;
            var i: usize = 1;
            while (i < raw.len and checked < 8) : (i += 2) {
                checked += 1;
                if (raw[i] == 0) zeros += 1;
            }
            break :blk checked > 0 and zeros == checked;
        }
        break :blk false;
    };

    if (is_utf16) {
        const utf16_bytes = raw[utf16_start..];
        const utf16_slice = std.mem.bytesAsSlice(u16, utf16_bytes[0 .. utf16_bytes.len - (utf16_bytes.len % 2)]);

        var utf8_buf: [4096]u8 = undefined;
        var utf8_len: usize = 0;
        for (utf16_slice) |code_unit| {
            if (code_unit == 0) continue;
            if (code_unit < 0x80) {
                if (utf8_len < utf8_buf.len) {
                    utf8_buf[utf8_len] = @intCast(code_unit);
                    utf8_len += 1;
                }
            } else {
                var encode_buf: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(@intCast(code_unit), &encode_buf) catch continue;
                if (utf8_len + encoded_len <= utf8_buf.len) {
                    @memcpy(utf8_buf[utf8_len..][0..encoded_len], encode_buf[0..encoded_len]);
                    utf8_len += encoded_len;
                }
            }
        }

        var lines = std.mem.splitSequence(u8, utf8_buf[0..utf8_len], "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) {
                const owned = try alloc.dupe(u8, trimmed);
                try distros.append(alloc, owned);
            }
        }
    } else {
        var lines = std.mem.splitSequence(u8, raw, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) {
                const owned = try alloc.dupe(u8, trimmed);
                try distros.append(alloc, owned);
            }
        }
    }

    return try distros.toOwnedSlice(alloc);
}

/// Free a distro list returned by listDistros.
pub fn freeDistroList(alloc: std.mem.Allocator, distros: [][]const u8) void {
    for (distros) |d| alloc.free(d);
    alloc.free(distros);
}

// ─── Path Translation ───────────────────────────────────────────────

/// Translate a Windows path to its WSL equivalent.
pub fn windowsToWslPath(buf: []u8, win_path: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    if (win_path.len > 0 and win_path[0] == '/') {
        try writer.writeAll(win_path);
        return fbs.getWritten();
    }

    if (win_path.len >= 6 and std.mem.startsWith(u8, win_path, "\\\\wsl")) {
        var rest = win_path[2..];
        if (std.mem.indexOfScalar(u8, rest, '\\')) |sep| {
            rest = rest[sep + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '\\')) |dsep| {
                rest = rest[dsep..];
                for (rest) |c| {
                    try writer.writeByte(if (c == '\\') '/' else c);
                }
                return fbs.getWritten();
            }
        }
        try writer.writeByte('/');
        return fbs.getWritten();
    }

    if (win_path.len >= 2 and win_path[1] == ':') {
        const drive_letter = std.ascii.toLower(win_path[0]);
        try writer.print("/mnt/{c}", .{drive_letter});
        if (win_path.len > 2) {
            const rest = win_path[2..];
            for (rest) |c| {
                try writer.writeByte(if (c == '\\') '/' else c);
            }
        }
        return fbs.getWritten();
    }

    for (win_path) |c| {
        try writer.writeByte(if (c == '\\') '/' else c);
    }
    return fbs.getWritten();
}

/// Translate a WSL path to its Windows equivalent.
pub fn wslToWindowsPath(buf: []u8, wsl_path: []const u8, distro: ?[]const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    if (wsl_path.len >= 6 and std.mem.startsWith(u8, wsl_path, "/mnt/") and
        wsl_path.len > 5 and (wsl_path.len == 6 or wsl_path[6] == '/'))
    {
        const drive_letter = std.ascii.toUpper(wsl_path[5]);
        try writer.print("{c}:", .{drive_letter});
        if (wsl_path.len > 6) {
            const rest = wsl_path[6..];
            for (rest) |c| {
                try writer.writeByte(if (c == '/') '\\' else c);
            }
        } else {
            try writer.writeByte('\\');
        }
        return fbs.getWritten();
    }

    const distro_name = distro orelse "default";
    try writer.print("\\\\wsl$\\{s}", .{distro_name});
    for (wsl_path) |c| {
        try writer.writeByte(if (c == '/') '\\' else c);
    }
    return fbs.getWritten();
}

// ─── Internal Helpers ───────────────────────────────────────────────

/// Initialize Winsock2 (process-wide, idempotent).
fn ensureWsa() Error!void {
    if (wsa_initialized.load(.acquire)) return;
    var wsa_data: WSADATA = undefined;
    if (WSAStartup(0x0202, &wsa_data) != 0) {
        wsl_log.print("ensureWsa: WSAStartup failed", .{});
        return error.WsaStartupFailed;
    }
    wsa_initialized.store(true, .release);
    wsl_log.print("ensureWsa: WSAStartup OK", .{});
}

/// Convert a vsock port to a Hyper-V service GUID.
/// WSL2 template: {PORT as u32}-FACB-11E6-BD58-64006A7986D3
fn makeVsockServiceGuid(port: u32) GUID {
    return .{
        .Data1 = port,
        .Data2 = 0xFACB,
        .Data3 = 0x11E6,
        .Data4 = .{ 0xBD, 0x58, 0x64, 0x00, 0x6A, 0x79, 0x86, 0xD3 },
    };
}

/// Try to connect to the daemon with a 500ms timeout.
///
/// Uses non-blocking connect + select() because SO_SNDTIMEO does NOT
/// affect connect() on Windows (only send calls). Without this, AF_HYPERV
/// connect() blocks for ~30 seconds when no daemon is listening.
fn tryConnect(vm_id: GUID, service_guid: GUID) ?SOCKET {
    const sock = WSASocketA(AF_HYPERV, SOCK_STREAM, HV_PROTOCOL_RAW, null, 0, WSA_FLAG_OVERLAPPED);
    if (sock == INVALID_SOCKET) {
        wsl_log.print("tryConnect: WSASocket failed, err={d}", .{WSAGetLastError()});
        return null;
    }

    // Set non-blocking mode for the connect.
    var nonblocking: u32 = 1;
    _ = ioctlsocket(sock, FIONBIO, &nonblocking);

    const addr = SOCKADDR_HV{
        .Family = @intCast(AF_HYPERV),
        .Reserved = 0,
        .VmId = vm_id,
        .ServiceId = service_guid,
    };

    const result = connect_fn(sock, &addr, @sizeOf(SOCKADDR_HV));
    if (result == SOCKET_ERROR) {
        const err = WSAGetLastError();
        if (err != WSAEWOULDBLOCK) {
            wsl_log.print("tryConnect: connect failed immediately, WSA err={d}", .{err});
            _ = closesocket(sock);
            return null;
        }

        // Connection in progress — wait with select().
        var write_fds = std.mem.zeroes(fd_set);
        write_fds.fd_count = 1;
        write_fds.fd_array[0] = sock;

        var except_fds = std.mem.zeroes(fd_set);
        except_fds.fd_count = 1;
        except_fds.fd_array[0] = sock;

        const timeout = timeval{
            .tv_sec = 0,
            .tv_usec = CONNECT_TIMEOUT_MS * 1000, // 500ms
        };

        const sel = select_fn(0, null, &write_fds, &except_fds, &timeout);
        if (sel <= 0) {
            // Timeout or error.
            wsl_log.print("tryConnect: select timeout/error (sel={d})", .{sel});
            _ = closesocket(sock);
            return null;
        }

        // Check if connect failed (socket in except set).
        if (except_fds.fd_count > 0) {
            wsl_log.print("tryConnect: connect failed (in except set)", .{});
            _ = closesocket(sock);
            return null;
        }
    }

    // Restore blocking mode for normal I/O.
    var blocking: u32 = 0;
    _ = ioctlsocket(sock, FIONBIO, &blocking);

    return sock;
}

/// Send handshake and read response.
fn doHandshake(sock: SOCKET, config: Config, token: [32]u8) Error!VsockBridge {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Magic (v2)
    const magic = "GWSL\x02";
    @memcpy(buf[pos..][0..magic.len], magic);
    pos += magic.len;

    // Authentication token (32 bytes)
    @memcpy(buf[pos..][0..32], &token);
    pos += 32;

    // Terminal size (big-endian u16)
    inline for (.{ config.size.ws_col, config.size.ws_row, config.size.ws_xpixel, config.size.ws_ypixel }) |val| {
        buf[pos] = @intCast((val >> 8) & 0xFF);
        buf[pos + 1] = @intCast(val & 0xFF);
        pos += 2;
    }

    // Shell path
    const shell = config.shell orelse "";
    const shell_len: u16 = @intCast(shell.len);
    buf[pos] = @intCast((shell_len >> 8) & 0xFF);
    buf[pos + 1] = @intCast(shell_len & 0xFF);
    pos += 2;
    if (shell.len > 0) {
        @memcpy(buf[pos..][0..shell.len], shell);
        pos += shell.len;
    }

    // CWD
    const cwd = config.cwd orelse "";
    const cwd_len: u16 = @intCast(cwd.len);
    buf[pos] = @intCast((cwd_len >> 8) & 0xFF);
    buf[pos + 1] = @intCast(cwd_len & 0xFF);
    pos += 2;
    if (cwd.len > 0) {
        @memcpy(buf[pos..][0..cwd.len], cwd);
        pos += cwd.len;
    }

    if (sendAll(sock, buf[0..pos]) != pos) {
        _ = closesocket(sock);
        return error.HandshakeFailed;
    }

    // Read response: "OK\x01" + pty_id:u32be = 7 bytes
    var resp: [7]u8 = undefined;
    if (recvExact(sock, &resp) == null) {
        _ = closesocket(sock);
        return error.HandshakeFailed;
    }

    if (resp[0] != 'O' or resp[1] != 'K' or resp[2] != 0x01) {
        log.err("invalid handshake response", .{});
        _ = closesocket(sock);
        return error.HandshakeFailed;
    }

    const pty_id = @as(u32, resp[3]) << 24 |
        @as(u32, resp[4]) << 16 |
        @as(u32, resp[5]) << 8 |
        @as(u32, resp[6]);

    log.info("vsock connected, pty_id={}", .{pty_id});

    return VsockBridge{
        .socket = sock,
        .size = config.size,
        .pty_id = pty_id,
    };
}

fn sendAll(sock: SOCKET, data: []const u8) usize {
    var sent: usize = 0;
    while (sent < data.len) {
        const remaining = @as(i32, @intCast(data.len - sent));
        const n = send_fn(sock, data[sent..].ptr, remaining, 0);
        if (n <= 0) return sent;
        sent += @intCast(n);
    }
    return sent;
}

fn recvExact(sock: SOCKET, buf_out: []u8) ?[]u8 {
    var received: usize = 0;
    while (received < buf_out.len) {
        const remaining = @as(i32, @intCast(buf_out.len - received));
        const n = recv_fn(sock, buf_out[received..].ptr, remaining, 0);
        if (n <= 0) return null;
        received += @intCast(n);
    }
    return buf_out;
}

/// Discover the WSL2 VM ID by running `wslinfo --vm-id` inside WSL.
fn discoverVmId(distro: ?[:0]const u8) ?GUID {
    var cmd_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("wsl.exe") catch return null;
    if (distro) |d| {
        writer.print(" -d {s}", .{d}) catch return null;
    }
    writer.writeAll(" -- wslinfo --vm-id") catch return null;

    const cmd_line = fbs.getWritten();

    var cmd_w_buf: [512]u16 = undefined;
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_line) catch return null;
    cmd_w_buf[cmd_w_len] = 0;

    var out_read: windows.HANDLE = undefined;
    var out_write: windows.HANDLE = undefined;
    if (windows.exp.kernel32.CreatePipe(&out_read, &out_write, null, 0) == 0) {
        return null;
    }
    defer _ = windows.CloseHandle(out_read);

    windows.SetHandleInformation(out_write, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT) catch return null;
    windows.SetHandleInformation(out_read, windows.HANDLE_FLAG_INHERIT, 0) catch return null;

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    startup_info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.hStdOutput = out_write;
    startup_info.hStdError = out_write;

    var process_info: windows.PROCESS_INFORMATION = undefined;

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.TRUE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        _ = windows.CloseHandle(out_write);
        return null;
    }

    _ = windows.CloseHandle(out_write);
    defer _ = windows.CloseHandle(process_info.hProcess);
    defer _ = windows.CloseHandle(process_info.hThread);

    const wait_result = windows.kernel32.WaitForSingleObject(process_info.hProcess, 5000);
    if (wait_result == WAIT_TIMEOUT) {
        _ = windows.kernel32.TerminateProcess(process_info.hProcess, 1);
        _ = windows.kernel32.WaitForSingleObject(process_info.hProcess, 1000);
        return null;
    }

    var output_buf: [256]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < output_buf.len) {
        var bytes_read: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            out_read,
            output_buf[total_read..].ptr,
            @intCast(output_buf.len - total_read),
            &bytes_read,
            null,
        ) == 0) break;
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }

    if (total_read == 0) {
        wsl_log.print("discoverVmId: wslinfo returned no output", .{});
        return null;
    }

    const output = std.mem.trim(u8, output_buf[0..total_read], " \t\r\n");
    wsl_log.print("discoverVmId: wslinfo output ({d} bytes): {s}", .{ output.len, output });
    return parseGuid(output);
}

/// Read the authentication token from the daemon's token file inside WSL.
/// Runs: wsl.exe [-d distro] -- cat /tmp/ghostwsl-PORT.token
/// Parses the "TOKEN <hex>" line and decodes the 64 hex chars into 32 bytes.
fn readToken(distro: ?[:0]const u8, port: u32) ?[32]u8 {
    var cmd_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("wsl.exe") catch return null;
    if (distro) |d| {
        writer.print(" -d {s}", .{d}) catch return null;
    }
    writer.print(" -- cat /tmp/ghostwsl-{d}.token", .{port}) catch return null;

    const cmd_line = fbs.getWritten();

    var cmd_w_buf: [512]u16 = undefined;
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_line) catch return null;
    cmd_w_buf[cmd_w_len] = 0;

    var out_read: windows.HANDLE = undefined;
    var out_write: windows.HANDLE = undefined;
    if (windows.exp.kernel32.CreatePipe(&out_read, &out_write, null, 0) == 0) {
        return null;
    }
    defer _ = windows.CloseHandle(out_read);

    windows.SetHandleInformation(out_write, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT) catch return null;
    windows.SetHandleInformation(out_read, windows.HANDLE_FLAG_INHERIT, 0) catch return null;

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    startup_info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.hStdOutput = out_write;
    startup_info.hStdError = out_write;

    var process_info: windows.PROCESS_INFORMATION = undefined;

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.TRUE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        _ = windows.CloseHandle(out_write);
        return null;
    }

    _ = windows.CloseHandle(out_write);
    defer _ = windows.CloseHandle(process_info.hProcess);
    defer _ = windows.CloseHandle(process_info.hThread);

    const wait_result = windows.kernel32.WaitForSingleObject(process_info.hProcess, 5000);
    if (wait_result == WAIT_TIMEOUT) {
        _ = windows.kernel32.TerminateProcess(process_info.hProcess, 1);
        _ = windows.kernel32.WaitForSingleObject(process_info.hProcess, 1000);
        return null;
    }

    var output_buf: [256]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < output_buf.len) {
        var bytes_read: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            out_read,
            output_buf[total_read..].ptr,
            @intCast(output_buf.len - total_read),
            &bytes_read,
            null,
        ) == 0) break;
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }

    if (total_read == 0) {
        wsl_log.print("readToken: no output from cat", .{});
        return null;
    }

    // Parse "TOKEN <64 hex chars>" line.
    const output = output_buf[0..total_read];
    var line_start: usize = 0;
    while (line_start < output.len) {
        var line_end = line_start;
        while (line_end < output.len and output[line_end] != '\n' and output[line_end] != '\r') : (line_end += 1) {}
        const line = output[line_start..line_end];

        if (line.len >= 70 and std.mem.eql(u8, line[0..6], "TOKEN ")) {
            const hex = line[6..70]; // 64 hex chars
            var token: [32]u8 = undefined;
            for (0..32) |i| {
                token[i] = parseHex(u8, hex[i * 2 ..][0..2]) orelse return null;
            }
            wsl_log.print("readToken: parsed token successfully", .{});
            return token;
        }

        // Skip past line ending.
        while (line_end < output.len and (output[line_end] == '\n' or output[line_end] == '\r')) : (line_end += 1) {}
        line_start = line_end;
    }

    wsl_log.print("readToken: TOKEN line not found in output", .{});
    return null;
}

/// Start the PTY daemon inside WSL via wsl.exe.
fn startDaemon(distro: ?[:0]const u8, port: u32) Error!void {
    // Idempotent: if a daemon is already listening on this port, the new
    // instance will fail to bind (EADDRINUSE) and exit harmlessly.
    // The daemon double-forks, so wsl.exe exits quickly (~100ms).
    // We wait for it to avoid leaked wsl.exe processes.

    var cmd_buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("wsl.exe") catch return error.Unexpected;
    if (distro) |d| {
        writer.print(" -d {s}", .{d}) catch return error.Unexpected;
    }
    writer.print(
        " -- sh -c \"exec {s} --daemon --port {d} --idle-timeout 0\"",
        .{ BRIDGE_SHELL_PATH, port },
    ) catch return error.Unexpected;

    const cmd_line = fbs.getWritten();

    var cmd_w_buf: [1024]u16 = undefined;
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w_buf, cmd_line) catch
        return error.Unexpected;
    cmd_w_buf[cmd_w_len] = 0;

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);

    var process_info: windows.PROCESS_INFORMATION = undefined;

    if (windows.exp.kernel32.CreateProcessW(
        null,
        @ptrCast(&cmd_w_buf),
        null,
        null,
        windows.FALSE,
        CREATE_NO_WINDOW,
        null,
        null,
        @ptrCast(&startup_info),
        &process_info,
    ) == 0) {
        log.err("CreateProcessW failed for daemon: {}", .{windows.kernel32.GetLastError()});
        return error.DaemonStartFailed;
    }

    defer _ = windows.CloseHandle(process_info.hThread);
    defer _ = windows.CloseHandle(process_info.hProcess);

    // Wait for wsl.exe to exit. The daemon double-forks so its direct child
    // exits immediately, allowing wsl.exe to terminate quickly.
    _ = windows.kernel32.WaitForSingleObject(process_info.hProcess, 5000);

    log.info("daemon start requested on port {d}", .{port});
    wsl_log.print("startDaemon: wsl.exe launched for port {d}", .{port});
}

/// Parse a GUID string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
fn parseGuid(s: []const u8) ?GUID {
    if (s.len < 36) return null;

    var start: usize = 0;
    while (start < s.len and !isHexDigit(s[start])) : (start += 1) {}
    if (start + 36 > s.len) return null;

    const g = s[start..][0..36];

    if (g[8] != '-' or g[13] != '-' or g[18] != '-' or g[23] != '-') return null;

    const data1 = parseHex(u32, g[0..8]) orelse return null;
    const data2 = parseHex(u16, g[9..13]) orelse return null;
    const data3 = parseHex(u16, g[14..18]) orelse return null;

    var data4: [8]u8 = undefined;
    data4[0] = parseHex(u8, g[19..21]) orelse return null;
    data4[1] = parseHex(u8, g[21..23]) orelse return null;
    data4[2] = parseHex(u8, g[24..26]) orelse return null;
    data4[3] = parseHex(u8, g[26..28]) orelse return null;
    data4[4] = parseHex(u8, g[28..30]) orelse return null;
    data4[5] = parseHex(u8, g[30..32]) orelse return null;
    data4[6] = parseHex(u8, g[32..34]) orelse return null;
    data4[7] = parseHex(u8, g[34..36]) orelse return null;

    return .{ .Data1 = data1, .Data2 = data2, .Data3 = data3, .Data4 = data4 };
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn parseHex(comptime T: type, s: []const u8) ?T {
    var result: T = 0;
    for (s) |c| {
        const digit: T = if (c >= '0' and c <= '9')
            @intCast(c - '0')
        else if (c >= 'a' and c <= 'f')
            @intCast(c - 'a' + 10)
        else if (c >= 'A' and c <= 'F')
            @intCast(c - 'A' + 10)
        else
            return null;
        result = result *% 16 +% digit;
    }
    return result;
}

// ─── Tests ──────────────────────────────────────────────────────────

test "parseGuid: valid GUID" {
    const g = parseGuid("12345678-abcd-ef01-2345-678901abcdef").?;
    try std.testing.expectEqual(@as(u32, 0x12345678), g.Data1);
    try std.testing.expectEqual(@as(u16, 0xabcd), g.Data2);
    try std.testing.expectEqual(@as(u16, 0xef01), g.Data3);
    try std.testing.expectEqual([8]u8{ 0x23, 0x45, 0x67, 0x89, 0x01, 0xab, 0xcd, 0xef }, g.Data4);
}

test "parseGuid: uppercase" {
    const g = parseGuid("AABBCCDD-1122-3344-5566-778899AABBCC").?;
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), g.Data1);
    try std.testing.expectEqual(@as(u16, 0x1122), g.Data2);
}

test "parseGuid: invalid format" {
    try std.testing.expect(parseGuid("not-a-guid") == null);
    try std.testing.expect(parseGuid("12345678abcdef012345678901abcdef") == null);
    try std.testing.expect(parseGuid("") == null);
}

test "parseGuid: with surrounding whitespace" {
    const g = parseGuid("12345678-abcd-ef01-2345-678901abcdef");
    try std.testing.expect(g != null);
}

test "makeVsockServiceGuid: port 48470" {
    const g = makeVsockServiceGuid(48470);
    try std.testing.expectEqual(@as(u32, 48470), g.Data1);
    try std.testing.expectEqual(@as(u16, 0xFACB), g.Data2);
    try std.testing.expectEqual(@as(u16, 0x11E6), g.Data3);
}

test "portForDistro: default" {
    try std.testing.expectEqual(@as(u32, 48470), portForDistro(null));
}

test "portForDistro: named distro" {
    const port = portForDistro("Ubuntu");
    try std.testing.expect(port >= 48471 and port <= 49470);
}

test "portForDistro: different names give different ports" {
    const p1 = portForDistro("Ubuntu");
    const p2 = portForDistro("Fedora");
    // Very unlikely to collide, but not impossible
    try std.testing.expect(p1 != p2);
}

test "portForDistro: deterministic" {
    const p1 = portForDistro("Ubuntu");
    const p2 = portForDistro("Ubuntu");
    try std.testing.expectEqual(p1, p2);
}

test "handshake encoding" {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    const magic_str = "GWSL\x01";
    @memcpy(buf[pos..][0..magic_str.len], magic_str);
    pos += magic_str.len;

    buf[pos] = 0;
    buf[pos + 1] = 80;
    pos += 2;
    buf[pos] = 0;
    buf[pos + 1] = 24;
    pos += 2;
    buf[pos] = 0;
    buf[pos + 1] = 0;
    pos += 2;
    buf[pos] = 0;
    buf[pos + 1] = 0;
    pos += 2;

    buf[pos] = 0;
    buf[pos + 1] = 8;
    pos += 2;
    @memcpy(buf[pos..][0..8], "/bin/zsh");
    pos += 8;

    buf[pos] = 0;
    buf[pos + 1] = 0;
    pos += 2;

    try std.testing.expectEqualSlices(u8, "GWSL\x01", buf[0..5]);
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
    try std.testing.expectEqual(@as(u8, 80), buf[6]);
    try std.testing.expectEqual(@as(u8, 0), buf[7]);
    try std.testing.expectEqual(@as(u8, 24), buf[8]);
    try std.testing.expectEqual(@as(usize, 25), pos);
}

test "windowsToWslPath: drive letter" {
    var buf: [256]u8 = undefined;
    const result = try windowsToWslPath(&buf, "C:\\Users\\foo\\Documents");
    try std.testing.expectEqualStrings("/mnt/c/Users/foo/Documents", result);
}

test "windowsToWslPath: drive root" {
    var buf: [256]u8 = undefined;
    const result = try windowsToWslPath(&buf, "C:\\");
    try std.testing.expectEqualStrings("/mnt/c/", result);
}

test "windowsToWslPath: UNC wsl$" {
    var buf: [256]u8 = undefined;
    const result = try windowsToWslPath(&buf, "\\\\wsl$\\Ubuntu\\home\\user");
    try std.testing.expectEqualStrings("/home/user", result);
}

test "windowsToWslPath: already linux path" {
    var buf: [256]u8 = undefined;
    const result = try windowsToWslPath(&buf, "/home/user/project");
    try std.testing.expectEqualStrings("/home/user/project", result);
}

test "wslToWindowsPath: /mnt drive path" {
    var buf: [256]u8 = undefined;
    const result = try wslToWindowsPath(&buf, "/mnt/c/Users/foo", null);
    try std.testing.expectEqualStrings("C:\\Users\\foo", result);
}

test "wslToWindowsPath: WSL internal path" {
    var buf: [256]u8 = undefined;
    const result = try wslToWindowsPath(&buf, "/home/user", "Ubuntu");
    try std.testing.expectEqualStrings("\\\\wsl$\\Ubuntu\\home\\user", result);
}
