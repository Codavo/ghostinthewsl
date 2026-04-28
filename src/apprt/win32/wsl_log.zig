//! File-based debug logger for WSL code paths.
//!
//! Standard log output (GHOSTTY_LOG=stderr) is hard to capture on Windows
//! because PowerShell hangs GUI processes when using 2> redirect. This
//! module writes directly to a known file using Win32 CreateFileW/WriteFile,
//! bypassing all redirection issues.
//!
//! Output goes to %TEMP%\ghostty-wsl.log. Enable by setting the environment
//! variable GHOSTWSL_DEBUG=1 before launching Ghostty.
//!
//! Usage:
//!   const wsl_log = @import("wsl_log.zig");
//!   wsl_log.print("vsock connected, pty_id={d}", .{pty_id});

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("../../os/main.zig").windows;

/// Whether debug logging is enabled. Checked once at first use.
var enabled: enum { unknown, yes, no } = .unknown;

/// The open file handle, or null if not yet opened / disabled.
var log_handle: ?windows.HANDLE = null;

const FILE_APPEND_DATA: windows.DWORD = 0x0004;
const OPEN_ALWAYS: windows.DWORD = 4;

extern "kernel32" fn GetTempPathW(nBufferLength: windows.DWORD, lpBuffer: [*]u16) callconv(.winapi) windows.DWORD;

/// Write a formatted message to the debug log file.
/// No-op if GHOSTWSL_DEBUG is not set to "1".
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.os.tag != .windows) return;

    const handle = getHandle() orelse return;

    var buf: [2048]u8 = undefined;
    var pos: usize = 0;

    // Timestamp prefix: [HH:MM:SS.mmm]
    const ts = std.time.milliTimestamp();
    // Convert to time-of-day (UTC). milliTimestamp is ms since epoch.
    const ms_in_day = @mod(ts, 86400_000);
    const hours = @divTrunc(ms_in_day, 3600_000);
    const mins = @divTrunc(@mod(ms_in_day, 3600_000), 60_000);
    const secs = @divTrunc(@mod(ms_in_day, 60_000), 1000);
    const millis = @mod(ms_in_day, 1000);

    const prefix = std.fmt.bufPrint(buf[0..], "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{
        hours, mins, secs, millis,
    }) catch return;
    pos = prefix.len;

    // Format the user message
    const msg = std.fmt.bufPrint(buf[pos..], fmt, args) catch blk: {
        // If message is too long, truncate
        @memcpy(buf[pos..][0..3], "...");
        break :blk buf[pos..][0..3];
    };
    pos += msg.len;

    // Add newline
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    // Write to file
    var written: windows.DWORD = 0;
    _ = windows.kernel32.WriteFile(
        handle,
        buf[0..pos].ptr,
        @intCast(pos),
        &written,
        null,
    );
}

/// Write raw bytes to %TEMP%\ghostty-vt-dump.bin (append mode).
/// Used to capture VT data that triggers slow parsing for offline replay.
/// Each record: [u32le: chunk_len] [u32le: vt_ms] [u8[chunk_len]: data]
pub fn dumpVtChunk(data: []const u8, vt_ms: u32) void {
    if (comptime builtin.os.tag != .windows) return;

    const handle = getDumpHandle() orelse return;

    // Write header: chunk_len (u32le) + vt_ms (u32le) = 8 bytes
    var header: [8]u8 = undefined;
    const len: u32 = @intCast(@min(data.len, std.math.maxInt(u32)));
    @memcpy(header[0..4], &std.mem.toBytes(len));
    @memcpy(header[4..8], &std.mem.toBytes(vt_ms));

    var written: windows.DWORD = 0;
    _ = windows.kernel32.WriteFile(handle, &header, 8, &written, null);

    // Write chunk data (may need multiple calls for large chunks)
    var remaining = data[0..len];
    while (remaining.len > 0) {
        var n: windows.DWORD = 0;
        _ = windows.kernel32.WriteFile(
            handle,
            remaining.ptr,
            @intCast(remaining.len),
            &n,
            null,
        );
        if (n == 0) break;
        remaining = remaining[n..];
    }
}

/// Lazily open the VT dump file.
var dump_handle: ?windows.HANDLE = null;

fn getDumpHandle() ?windows.HANDLE {
    // Only dump if debug logging is enabled
    if (getHandle() == null) return null;
    if (dump_handle) |h| return h;

    var path_buf: [512]u16 = undefined;
    const temp_len = GetTempPathW(path_buf.len, &path_buf);
    if (temp_len == 0 or temp_len >= path_buf.len - 30) return null;

    const filename = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-vt-dump.bin");
    var pos: usize = temp_len;
    for (filename, 0..) |ch, i| {
        if (pos + i >= path_buf.len) return null;
        path_buf[pos + i] = ch;
    }
    pos += filename.len;
    path_buf[pos] = 0;

    const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
    const handle = windows.kernel32.CreateFileW(
        @ptrCast(&path_buf),
        FILE_APPEND_DATA,
        windows.FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_ALWAYS,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return null;

    dump_handle = handle;
    return handle;
}

/// Get (or lazily open) the log file handle.
fn getHandle() ?windows.HANDLE {
    if (enabled == .no) return null;
    if (log_handle) |h| return h;

    // First call: check environment variable
    if (enabled == .unknown) {
        const val = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOSTWSL_DEBUG") catch {
            enabled = .no;
            return null;
        };
        defer std.heap.page_allocator.free(val);
        if (!std.mem.eql(u8, val, "1")) {
            enabled = .no;
            return null;
        }
        enabled = .yes;
    }

    // Build path: %TEMP%\ghostty-wsl.log
    var path_buf: [512]u16 = undefined;
    const temp_len = GetTempPathW(path_buf.len, &path_buf);
    if (temp_len == 0 or temp_len >= path_buf.len - 20) {
        enabled = .no;
        return null;
    }

    const filename = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-wsl.log");
    // Ensure trailing backslash from GetTempPathW, then append filename
    var pos: usize = temp_len;
    for (filename, 0..) |ch, i| {
        if (pos + i >= path_buf.len) {
            enabled = .no;
            return null;
        }
        path_buf[pos + i] = ch;
    }
    pos += filename.len;
    path_buf[pos] = 0; // null terminate

    // Open the file for appending (create if not exists)
    const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
    const handle = windows.kernel32.CreateFileW(
        @ptrCast(&path_buf),
        FILE_APPEND_DATA,
        windows.FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_ALWAYS,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        enabled = .no;
        return null;
    }

    log_handle = handle;
    return handle;
}
