const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Search for "cmd" in the PATH and return the absolute path. This will
/// always allocate if there is a non-null result. The caller must free the
/// resulting value.
pub fn expand(alloc: Allocator, cmd: []const u8) !?[]u8 {
    // If the command already contains a slash, then we return it as-is
    // because it is assumed to be absolute or relative.
    if (std.mem.indexOfScalar(u8, cmd, '/') != null or
        std.mem.indexOfScalar(u8, cmd, '\\') != null)
    {
        return try alloc.dupe(u8, cmd);
    }

    const PATH = switch (builtin.os.tag) {
        .windows => blk: {
            const win_path = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("PATH")) orelse return null;
            const path = try std.unicode.utf16LeToUtf8Alloc(alloc, win_path);
            break :blk path;
        },
        else => std.posix.getenvZ("PATH") orelse return null,
    };
    defer if (builtin.os.tag == .windows) alloc.free(PATH);

    const path_ext: []const u8 = if (builtin.os.tag == .windows)
        (std.process.getEnvVarOwned(alloc, "PATHEXT") catch ".COM;.EXE;.BAT;.CMD")
    else
        "";
    defer if (builtin.os.tag == .windows and path_ext.ptr != ".COM;.EXE;.BAT;.CMD".ptr) alloc.free(path_ext);

    var it = std.mem.tokenizeScalar(u8, PATH, std.fs.path.delimiter);
    var seen_eacces = false;
    while (it.next()) |search_path| {
        if (try expandSearchPath(alloc, search_path, cmd, null, &seen_eacces)) |result| {
            return result;
        }

        if (builtin.os.tag == .windows and std.fs.path.extension(cmd).len == 0) {
            var ext_it = std.mem.tokenizeScalar(u8, path_ext, ';');
            while (ext_it.next()) |ext| {
                if (try expandSearchPath(alloc, search_path, cmd, ext, &seen_eacces)) |result| {
                    return result;
                }
            }
        }
    }

    if (seen_eacces) return error.AccessDenied;

    return null;
}

fn isExecutable(mode: std.fs.File.Mode) bool {
    if (builtin.os.tag == .windows) return true;
    return mode & 0o0111 != 0;
}

fn expandSearchPath(
    alloc: Allocator,
    search_path: []const u8,
    cmd: []const u8,
    ext: ?[]const u8,
    seen_eacces: *bool,
) !?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ext_ = ext orelse "";
    const path_len = search_path.len + 1 + cmd.len + ext_.len;
    if (path_buf.len <= path_len) return error.PathTooLong;

    @memcpy(path_buf[0..search_path.len], search_path);
    path_buf[search_path.len] = std.fs.path.sep;
    @memcpy(path_buf[search_path.len + 1 ..][0..cmd.len], cmd);
    if (ext_.len > 0) {
        @memcpy(path_buf[search_path.len + 1 + cmd.len ..][0..ext_.len], ext_);
    }
    path_buf[path_len] = 0;
    const full_path = path_buf[0..path_len :0];

    const f = std.fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.AccessDenied => {
            seen_eacces.* = true;
            return null;
        },
        else => return err,
    };
    defer f.close();
    const stat = try f.stat();
    if (stat.kind != .directory and isExecutable(stat.mode)) {
        return try alloc.dupe(u8, full_path);
    }

    return null;
}

// `uname -n` is the *nix equivalent of `hostname.exe` on Windows
test "expand: hostname" {
    const executable = if (builtin.os.tag == .windows) "hostname.exe" else "uname";
    const path = (try expand(testing.allocator, executable)).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len > executable.len);
}

test "expand: does not exist" {
    const path = try expand(testing.allocator, "thisreallyprobablydoesntexist123");
    try testing.expect(path == null);
}

test "expand: slash" {
    const path = (try expand(testing.allocator, "foo/env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len == 7);
}
