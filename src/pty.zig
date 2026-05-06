const std = @import("std");
const builtin = @import("builtin");
const windows = @import("os/main.zig").windows;
const posix = std.posix;
const assert = @import("quirks.zig").inlineAssert;

const log = std.log.scoped(.pty);

/// Redeclare this winsize struct so we can just use a Zig struct. This
/// layout should be correct on all tested platforms. The defaults on this
/// are some reasonable screen size but you should probably not use them.
pub const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

pub const Pty = switch (builtin.os.tag) {
    .windows => WindowsPty,
    .ios => NullPty,
    else => PosixPty,
};

/// The modes of a pty. Not all of these modes are supported on
/// all platforms but all platforms share the same mode struct.
///
/// The default values of fields in this struct are set to the
/// most typical values for a pty. This makes it easier for cross-platform
/// code which doesn't support all of the modes to work correctly.
pub const Mode = packed struct {
    /// ICANON on POSIX
    canonical: bool = true,

    /// ECHO on POSIX
    echo: bool = true,
};

pub const ProcessInfo = enum {
    /// The PID of the process that controls the PTY.
    foreground_pid,
    /// Gets the name of the slave PTY. Returned name points to an internal buffer
    /// so it should not be modified or freed.
    tty_name,

    pub fn Type(comptime info: ProcessInfo) type {
        return switch (info) {
            .foreground_pid => u64,
            .tty_name => [:0]const u8,
        };
    }
};

// A pty implementation that does nothing.
//
// TODO: This should be removed. This is only temporary until we have
// a termio that doesn't use a pty. This isn't used in any user-facing
// artifacts, this is just a stopgap to get compilation to work on iOS.
const NullPty = struct {
    pub const Error = OpenError || GetModeError || SetSizeError || ChildPreExecError;

    pub const Fd = posix.fd_t;

    master: Fd,
    slave: Fd,

    pub const OpenError = error{};

    pub fn open(size: winsize) OpenError!Pty {
        _ = size;
        return .{ .master = 0, .slave = 0 };
    }

    pub fn deinit(self: *Pty) void {
        _ = self;
    }

    pub const GetModeError = error{GetModeFailed};

    pub fn getMode(self: Pty) GetModeError!Mode {
        _ = self;
        return .{};
    }

    pub const SetSizeError = error{};

    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        _ = self;
        _ = size;
    }

    pub const ChildPreExecError = error{};

    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        _ = self;
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(_: *Pty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

/// Posix PTY creation and management. This is just a thin layer on top
/// of Posix syscalls. The caller is responsible for detail-oriented handling
/// of the returned file handles.
const PosixPty = struct {
    pub const Error = OpenError || GetModeError || GetSizeError || SetSizeError || ChildPreExecError;

    pub const Fd = posix.fd_t;

    const c = @import("pty-c");

    /// The file descriptors for the master and slave side of the pty.
    /// The slave side is never closed automatically by this struct
    /// so the caller is responsible for closing it if things
    /// go wrong.
    master: Fd,
    slave: Fd,

    /// Buffer for storage of slave tty name so that we don't have to recompute
    /// it every time we need it.
    tty_name_buf: [std.fs.max_path_bytes:0]u8 = undefined,
    /// The name of slave tty. If `null` it has not yet been computed or
    /// may not be available. Should not be accessed directly, but through
    /// `self.getProcessInfo(.tty_name)`
    tty_name: ?[:0]const u8 = null,

    pub const OpenError = error{OpenptyFailed};

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) OpenError!Pty {
        // Need to copy so that it becomes non-const.
        var sizeCopy = size;

        var master_fd: Fd = undefined;
        var slave_fd: Fd = undefined;
        if (c.openpty(
            &master_fd,
            &slave_fd,
            null,
            null,
            @ptrCast(&sizeCopy),
        ) < 0)
            return error.OpenptyFailed;
        errdefer {
            _ = posix.system.close(master_fd);
            _ = posix.system.close(slave_fd);
        }

        // Set CLOEXEC on the master fd, only the slave fd should be inherited
        // by the child process (shell/command).
        cloexec: {
            const flags = posix.fcntl(master_fd, posix.F.GETFD, 0) catch |err| {
                log.warn("error getting flags for master fd err={}", .{err});
                break :cloexec;
            };

            _ = posix.fcntl(
                master_fd,
                posix.F.SETFD,
                flags | posix.FD_CLOEXEC,
            ) catch |err| {
                log.warn("error setting CLOEXEC on master fd err={}", .{err});
                break :cloexec;
            };
        }

        // Enable UTF-8 mode. I think this is on by default on Linux but it
        // is NOT on by default on macOS so we ensure that it is always set.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0)
            return error.OpenptyFailed;
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0)
            return error.OpenptyFailed;

        return .{
            .master = master_fd,
            .slave = slave_fd,
            .tty_name_buf = undefined,
            .tty_name = null,
        };
    }

    pub fn deinit(self: *Pty) void {
        _ = posix.system.close(self.master);
        self.* = undefined;
    }

    pub const GetModeError = error{GetModeFailed};

    pub fn getMode(self: Pty) GetModeError!Mode {
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.master, &attrs) != 0)
            return error.GetModeFailed;

        return .{
            .canonical = (attrs.c_lflag & c.ICANON) != 0,
            .echo = (attrs.c_lflag & c.ECHO) != 0,
        };
    }

    pub const GetSizeError = error{IoctlFailed};

    /// Return the size of the pty.
    pub fn getSize(self: Pty) GetSizeError!winsize {
        var ws: winsize = undefined;
        if (c.ioctl(self.master, c.TIOCGWINSZ, @intFromPtr(&ws)) < 0)
            return error.IoctlFailed;

        return ws;
    }

    pub const SetSizeError = error{IoctlFailed};

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        if (c.ioctl(self.master, c.TIOCSWINSZ, @intFromPtr(&size)) < 0)
            return error.IoctlFailed;
    }

    pub const ChildPreExecError = error{ OperationNotSupported, ProcessGroupFailed, SetControllingTerminalFailed };

    /// This should be called prior to exec in the forked child process
    /// in order to setup the tty properly.
    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        // Reset our signals
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.ABRT, &sa, null);
        posix.sigaction(posix.SIG.ALRM, &sa, null);
        posix.sigaction(posix.SIG.BUS, &sa, null);
        posix.sigaction(posix.SIG.CHLD, &sa, null);
        posix.sigaction(posix.SIG.FPE, &sa, null);
        posix.sigaction(posix.SIG.HUP, &sa, null);
        posix.sigaction(posix.SIG.ILL, &sa, null);
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.PIPE, &sa, null);
        posix.sigaction(posix.SIG.SEGV, &sa, null);
        posix.sigaction(posix.SIG.TRAP, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        posix.sigaction(posix.SIG.QUIT, &sa, null);

        // Create a new process group
        if (c.setsid() < 0) return error.ProcessGroupFailed;

        // Set controlling terminal
        switch (posix.errno(c.ioctl(self.slave, c.TIOCSCTTY, @as(c_ulong, 0)))) {
            .SUCCESS => {},
            else => |err| {
                log.err("error setting controlling terminal errno={}", .{err});
                return error.SetControllingTerminalFailed;
            },
        }

        // Can close master/slave pair now
        posix.close(self.slave);
        posix.close(self.master);
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *PosixPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (info) {
            .foreground_pid => {
                switch (builtin.os.tag) {
                    .linux => {
                        const linux = std.os.linux;
                        var pgrp: i32 = undefined;
                        const rc = linux.tcgetpgrp(self.master, &pgrp);
                        switch (linux.E.init(rc)) {
                            .SUCCESS => return @intCast(pgrp),
                            else => return null,
                        }
                    },
                    else => {
                        const rc = c.tcgetpgrp(self.master);
                        if (rc < 0) return null;
                        return @intCast(rc);
                    },
                }
            },
            .tty_name => {
                if (self.tty_name) |tty_name| return tty_name;

                switch (builtin.os.tag) {
                    .macos => {
                        // The macOS TIOCPTYGNAME ioctl does not allow us to
                        // specify the length of the buffer passed to it, but
                        // expects it to be at least 128 bytes long.
                        assert(self.tty_name_buf.len >= 128);
                        switch (posix.errno(c.ioctl(self.master, c.TIOCPTYGNAME, @intFromPtr(&self.tty_name_buf)))) {
                            .SUCCESS => {
                                const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                                self.tty_name = tty_name;
                                return tty_name;
                            },
                            else => |err| {
                                log.err("error getting name of slave PTY errno={t}", .{err});
                                return null;
                            },
                        }
                    },
                    .linux => {
                        if (c.ptsname_r(self.master, &self.tty_name_buf, self.tty_name_buf.len) != 0) return null;
                        const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                        self.tty_name = tty_name;
                        return tty_name;
                    },
                    else => return null,
                }
            },
        };
    }
};

/// Windows PTY creation and management.
const WindowsPty = struct {
    pub const Error = OpenError || GetSizeError || SetSizeError;

    pub const Fd = windows.HANDLE;
    const HMODULE = ?*anyopaque;

    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

    // Process-wide counter for pipe names
    var pipe_name_counter = std.atomic.Value(u32).init(1);
    var api_cache: ?PseudoConsoleApi = null;
    var api_cache_attempted: bool = false;

    out_pipe: windows.HANDLE,
    in_pipe: windows.HANDLE,
    out_pipe_pty: windows.HANDLE,
    in_pipe_pty: windows.HANDLE,
    pseudo_console: windows.exp.HPCON,
    size: winsize,

    const PseudoConsoleApi = struct {
        create: *const @TypeOf(windows.exp.kernel32.CreatePseudoConsole),
        resize: *const @TypeOf(windows.exp.kernel32.ResizePseudoConsole),
        close: *const @TypeOf(windows.exp.kernel32.ClosePseudoConsole),
    };

    /// Embedded ConPTY binaries from dist/windows/conpty/ (Windows Terminal, MIT licensed).
    /// These are extracted to %LOCALAPPDATA%\ghostinthewsl\conpty\ on first use.
    const embedded_conpty_dll = @embedFile("conpty/conpty.dll");
    const embedded_openconsole_exe = @embedFile("conpty/OpenConsole.exe");

    fn loadAdjacentConptyDll() ?HMODULE {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_buf) catch |err| {
            log.warn("failed to determine executable path for adjacent conpty.dll lookup err={}", .{err});
            return null;
        };
        const exe_dir = std.fs.path.dirname(exe_path) orelse return null;

        var dll_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dll_path = std.fmt.bufPrint(
            &dll_path_buf,
            "{s}\\conpty.dll",
            .{exe_dir},
        ) catch |err| {
            log.warn("failed to build adjacent conpty.dll path err={}", .{err});
            return null;
        };

        var dll_path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
        const dll_path_w_len = std.unicode.utf8ToUtf16Le(
            &dll_path_w_buf,
            dll_path,
        ) catch |err| {
            log.warn("failed to encode adjacent conpty.dll path err={}", .{err});
            return null;
        };
        dll_path_w_buf[dll_path_w_len] = 0;

        return LoadLibraryW(dll_path_w_buf[0..dll_path_w_len :0].ptr);
    }

    /// Extract embedded conpty.dll and OpenConsole.exe to
    /// %LOCALAPPDATA%\ghostinthewsl\conpty\ and LoadLibrary the DLL.
    /// Uses file size as a cache key — re-extracts only when the embedded
    /// binary changes (i.e. on version update).
    fn loadEmbeddedConptyDll() ?HMODULE {
        const GetEnvironmentVariableW = struct {
            extern "kernel32" fn GetEnvironmentVariableW(
                lpName: [*:0]const u16,
                lpBuffer: ?[*]u16,
                nSize: u32,
            ) callconv(.winapi) u32;
        }.GetEnvironmentVariableW;

        // Get %LOCALAPPDATA%
        const localappdata_key = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
        var appdata_buf: [std.fs.max_path_bytes / 2]u16 = undefined;
        const appdata_len = GetEnvironmentVariableW(localappdata_key, &appdata_buf, appdata_buf.len);
        if (appdata_len == 0) {
            log.warn("failed to get LOCALAPPDATA for embedded conpty extraction", .{});
            return null;
        }

        // Create directory (CreateDirectoryW, ignore ERROR_ALREADY_EXISTS)
        const CreateDirectoryW = struct {
            extern "kernel32" fn CreateDirectoryW(
                lpPathName: [*:0]const u16,
                lpSecurityAttributes: ?*anyopaque,
            ) callconv(.winapi) i32;
        }.CreateDirectoryW;

        // Use separate buffers for directory path and DLL path to avoid aliasing.
        var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dll_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dir_w_buf: [512]u16 = undefined;

        // Create parent: %LOCALAPPDATA%\ghostinthewsl
        var parent_w_buf: [512]u16 = undefined;
        const parent_path = std.fmt.bufPrint(&dir_path_buf, "{f}\\ghostinthewsl", .{
            std.unicode.fmtUtf16Le(appdata_buf[0..appdata_len]),
        }) catch return null;
        const parent_w_len = std.unicode.utf8ToUtf16Le(&parent_w_buf, parent_path) catch return null;
        parent_w_buf[parent_w_len] = 0;
        _ = CreateDirectoryW(parent_w_buf[0..parent_w_len :0].ptr, null);

        // Create child: %LOCALAPPDATA%\ghostinthewsl\conpty
        const dir_full_path = std.fmt.bufPrint(&dir_path_buf, "{f}\\ghostinthewsl\\conpty", .{
            std.unicode.fmtUtf16Le(appdata_buf[0..appdata_len]),
        }) catch return null;
        const dir_w_len = std.unicode.utf8ToUtf16Le(&dir_w_buf, dir_full_path) catch return null;
        dir_w_buf[dir_w_len] = 0;
        _ = CreateDirectoryW(dir_w_buf[0..dir_w_len :0].ptr, null);

        // Build DLL path in a SEPARATE buffer (dir_full_path is a slice of dir_path_buf)
        const dll_path = std.fmt.bufPrint(&dll_path_buf, "{s}\\conpty.dll", .{dir_full_path}) catch return null;

        // Check if conpty.dll exists with expected size (cache key)
        const needs_extract = needs_extraction: {
            var dll_w_buf2: [512]u16 = undefined;
            const dll_w_len2 = std.unicode.utf8ToUtf16Le(&dll_w_buf2, dll_path) catch break :needs_extraction true;
            dll_w_buf2[dll_w_len2] = 0;

            const GetFileAttributesExW = struct {
                extern "kernel32" fn GetFileAttributesExW(
                    lpFileName: [*:0]const u16,
                    fInfoLevelId: u32,
                    lpFileInformation: *anyopaque,
                ) callconv(.winapi) i32;
            }.GetFileAttributesExW;

            const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
                dwFileAttributes: u32,
                ftCreationTime: u64,
                ftLastAccessTime: u64,
                ftLastWriteTime: u64,
                nFileSizeHigh: u32,
                nFileSizeLow: u32,
            };

            var file_info: WIN32_FILE_ATTRIBUTE_DATA = undefined;
            if (GetFileAttributesExW(dll_w_buf2[0..dll_w_len2 :0].ptr, 0, @ptrCast(&file_info)) == 0) {
                break :needs_extraction true;
            }

            const file_size: u64 = (@as(u64, file_info.nFileSizeHigh) << 32) | file_info.nFileSizeLow;
            break :needs_extraction file_size != embedded_conpty_dll.len;
        };

        if (needs_extract) {
            log.info("extracting embedded conpty.dll ({d} bytes) and OpenConsole.exe ({d} bytes)", .{
                embedded_conpty_dll.len, embedded_openconsole_exe.len,
            });
            // Write conpty.dll atomically
            if (!writeFileAtomic(dir_full_path, "conpty.dll", embedded_conpty_dll)) return null;
            // Write OpenConsole.exe atomically
            if (!writeFileAtomic(dir_full_path, "OpenConsole.exe", embedded_openconsole_exe)) return null;
        }

        // Load the extracted DLL
        var load_path_buf: [512]u16 = undefined;
        const load_path_len = std.unicode.utf8ToUtf16Le(&load_path_buf, dll_path) catch return null;
        load_path_buf[load_path_len] = 0;
        return LoadLibraryW(load_path_buf[0..load_path_len :0].ptr);
    }

    /// Write data to dir\filename via a .tmp file + MoveFileExW for atomicity.
    fn writeFileAtomic(dir: []const u8, filename: []const u8, data: []const u8) bool {
        const CreateFileW = windows.kernel32.CreateFileW;
        const WriteFile = windows.kernel32.WriteFile;
        const MoveFileExW = struct {
            extern "kernel32" fn MoveFileExW(
                lpExistingFileName: [*:0]const u16,
                lpNewFileName: [*:0]const u16,
                dwFlags: u32,
            ) callconv(.winapi) i32;
        }.MoveFileExW;

        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}\\{s}.tmp", .{ dir, filename }) catch return false;
        var final_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const final_path = std.fmt.bufPrint(&final_path_buf, "{s}\\{s}", .{ dir, filename }) catch return false;

        var tmp_w_buf: [512]u16 = undefined;
        const tmp_w_len = std.unicode.utf8ToUtf16Le(&tmp_w_buf, tmp_path) catch return false;
        tmp_w_buf[tmp_w_len] = 0;

        var final_w_buf: [512]u16 = undefined;
        const final_w_len = std.unicode.utf8ToUtf16Le(&final_w_buf, final_path) catch return false;
        final_w_buf[final_w_len] = 0;

        // Create temp file
        const handle = CreateFileW(
            tmp_w_buf[0..tmp_w_len :0].ptr,
            windows.GENERIC_WRITE,
            0,
            null,
            windows.CREATE_ALWAYS,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) {
            log.warn("failed to create temp file for {s}", .{filename});
            return false;
        }

        // Write all data
        var written: u32 = 0;
        var remaining = data;
        while (remaining.len > 0) {
            const chunk_len: u32 = @intCast(@min(remaining.len, 0x7FFF_FFFF));
            if (WriteFile(handle, remaining.ptr, chunk_len, &written, null) == 0) {
                _ = windows.CloseHandle(handle);
                log.warn("failed to write {s}", .{filename});
                return false;
            }
            remaining = remaining[@intCast(written)..];
        }
        _ = windows.CloseHandle(handle);

        // Atomic rename (MOVEFILE_REPLACE_EXISTING = 1)
        if (MoveFileExW(tmp_w_buf[0..tmp_w_len :0].ptr, final_w_buf[0..final_w_len :0].ptr, 1) == 0) {
            log.warn("failed to rename temp file to {s}", .{filename});
            return false;
        }

        return true;
    }

    /// Resolve ConPTY API functions from a loaded DLL module.
    /// Tries Conpty-prefixed names first (NuGet/Windows Terminal convention),
    /// then falls back to unprefixed names (system conpty.dll).
    fn resolveConptyExports(module: HMODULE) ?PseudoConsoleApi {
        // Try Conpty-prefixed first (NuGet Windows Terminal builds)
        var create_ptr = GetProcAddress(module, "ConptyCreatePseudoConsole");
        var resize_ptr = GetProcAddress(module, "ConptyResizePseudoConsole");
        var close_ptr = GetProcAddress(module, "ConptyClosePseudoConsole");

        // Fallback to unprefixed (older builds, system conpty.dll)
        if (create_ptr == null) create_ptr = GetProcAddress(module, "CreatePseudoConsole");
        if (resize_ptr == null) resize_ptr = GetProcAddress(module, "ResizePseudoConsole");
        if (close_ptr == null) close_ptr = GetProcAddress(module, "ClosePseudoConsole");

        if (create_ptr != null and resize_ptr != null and close_ptr != null) {
            return .{
                .create = @ptrCast(@alignCast(create_ptr.?)),
                .resize = @ptrCast(@alignCast(resize_ptr.?)),
                .close = @ptrCast(@alignCast(close_ptr.?)),
            };
        }
        return null;
    }

    fn pseudoConsoleApi() PseudoConsoleApi {
        if (!api_cache_attempted) {
            api_cache_attempted = true;

            wsl_log.print("pseudoConsoleApi: first call, loading ConPTY", .{});

            // 1. Try adjacent conpty.dll (user-provided, highest priority)
            if (loadAdjacentConptyDll()) |module| {
                wsl_log.print("pseudoConsoleApi: adjacent conpty.dll loaded", .{});
                if (resolveConptyExports(module)) |api| {
                    api_cache = api;
                    log.info("using ConPTY APIs from adjacent conpty.dll", .{});
                    wsl_log.print("pseudoConsoleApi: using adjacent conpty.dll", .{});
                } else {
                    log.warn("loaded adjacent conpty.dll but required exports missing", .{});
                    wsl_log.print("pseudoConsoleApi: adjacent exports missing", .{});
                }
            }

            // 2. Try embedded extraction (built-in Windows Terminal ConPTY)
            if (api_cache == null) {
                wsl_log.print("pseudoConsoleApi: trying embedded extraction", .{});
                if (loadEmbeddedConptyDll()) |module| {
                    wsl_log.print("pseudoConsoleApi: embedded DLL loaded", .{});
                    if (resolveConptyExports(module)) |api| {
                        api_cache = api;
                        log.info("using ConPTY APIs from embedded/extracted conpty.dll", .{});
                        wsl_log.print("pseudoConsoleApi: using embedded conpty.dll", .{});
                    } else {
                        log.warn("loaded extracted conpty.dll but required exports missing", .{});
                        wsl_log.print("pseudoConsoleApi: embedded exports missing", .{});
                    }
                } else {
                    log.info("embedded conpty.dll extraction failed; using kernel32 fallback", .{});
                    wsl_log.print("pseudoConsoleApi: embedded extraction failed", .{});
                }
            }

            if (api_cache == null) {
                wsl_log.print("pseudoConsoleApi: using kernel32 fallback", .{});
            }
        }

        // 3. Kernel32 fallback (system ConPTY, always available on Win10+)
        return api_cache orelse .{
            .create = windows.exp.kernel32.CreatePseudoConsole,
            .resize = windows.exp.kernel32.ResizePseudoConsole,
            .close = windows.exp.kernel32.ClosePseudoConsole,
        };
    }

    pub const OpenError = error{Unexpected};

    /// Open a new PTY with the given initial size.
    const wsl_log = @import("apprt/win32/wsl_log.zig");

    pub fn open(size: winsize) OpenError!Pty {
        var pty: Pty = undefined;

        wsl_log.print("Pty.open: start col={d} row={d}", .{ size.ws_col, size.ws_row });

        var pipe_path_buf: [128]u8 = undefined;
        var pipe_path_buf_w: [128]u16 = undefined;
        const pipe_path = std.fmt.bufPrintZ(
            &pipe_path_buf,
            "\\\\.\\pipe\\LOCAL\\ghostty-pty-{d}-{d}",
            .{
                windows.GetCurrentProcessId(),
                pipe_name_counter.fetchAdd(1, .monotonic),
            },
        ) catch unreachable;

        const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
            &pipe_path_buf_w,
            pipe_path,
        ) catch unreachable;
        pipe_path_buf_w[pipe_path_w_len] = 0;
        const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];

        const security_attributes = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = windows.FALSE,
            .lpSecurityDescriptor = null,
        };

        pty.in_pipe = windows.kernel32.CreateNamedPipeW(
            pipe_path_w.ptr,
            windows.PIPE_ACCESS_OUTBOUND |
                windows.exp.FILE_FLAG_FIRST_PIPE_INSTANCE |
                windows.FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_BYTE,
            1,
            4096,
            4096,
            0,
            &security_attributes,
        );
        if (pty.in_pipe == windows.INVALID_HANDLE_VALUE) {
            wsl_log.print("Pty.open: CreateNamedPipeW FAILED", .{});
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.CloseHandle(pty.in_pipe);

        wsl_log.print("Pty.open: named pipe created", .{});

        var security_attributes_read = security_attributes;
        pty.in_pipe_pty = windows.kernel32.CreateFileW(
            pipe_path_w.ptr,
            windows.GENERIC_READ,
            0,
            &security_attributes_read,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (pty.in_pipe_pty == windows.INVALID_HANDLE_VALUE) {
            wsl_log.print("Pty.open: CreateFileW for in_pipe_pty FAILED", .{});
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.CloseHandle(pty.in_pipe_pty);

        wsl_log.print("Pty.open: in_pipe_pty opened", .{});

        // The in_pipe needs to be created as a named pipe, since anonymous
        // pipes created with CreatePipe do not support overlapped operations,
        // and the IOCP backend of libxev only uses overlapped operations on files.
        //
        // It would be ideal to use CreatePipe here, so that our pipe isn't
        // visible to any other processes.

        // if (windows.exp.kernel32.CreatePipe(&pty.in_pipe_pty, &pty.in_pipe, null, 0) == 0) {
        //     return windows.unexpectedError(windows.kernel32.GetLastError());
        // }
        // errdefer {
        //     _ = windows.CloseHandle(pty.in_pipe_pty);
        //     _ = windows.CloseHandle(pty.in_pipe);
        // }

        if (windows.exp.kernel32.CreatePipe(&pty.out_pipe, &pty.out_pipe_pty, null, 0) == 0) {
            wsl_log.print("Pty.open: CreatePipe for out_pipe FAILED", .{});
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.CloseHandle(pty.out_pipe);
            _ = windows.CloseHandle(pty.out_pipe_pty);
        }

        wsl_log.print("Pty.open: out_pipe created", .{});

        try windows.SetHandleInformation(pty.in_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.in_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.out_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.out_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);

        wsl_log.print("Pty.open: handle inheritance cleared, loading ConPTY API", .{});

        const api = pseudoConsoleApi();

        wsl_log.print("Pty.open: calling CreatePseudoConsole", .{});

        const result = api.create(
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
            pty.in_pipe_pty,
            pty.out_pipe_pty,
            0,
            &pty.pseudo_console,
        );
        if (result != windows.S_OK) {
            wsl_log.print("Pty.open: CreatePseudoConsole FAILED (HRESULT not S_OK)", .{});
            return error.Unexpected;
        }

        wsl_log.print("Pty.open: pseudo console created OK", .{});

        pty.size = size;
        return pty;
    }

    pub fn deinit(self: *Pty) void {
        _ = windows.CloseHandle(self.in_pipe_pty);
        _ = windows.CloseHandle(self.in_pipe);
        _ = windows.CloseHandle(self.out_pipe_pty);
        _ = windows.CloseHandle(self.out_pipe);
        pseudoConsoleApi().close(self.pseudo_console);
        self.* = undefined;
    }

    pub const GetSizeError = error{};

    /// Return the size of the pty.
    pub fn getSize(self: Pty) GetSizeError!winsize {
        return self.size;
    }

    pub const SetSizeError = error{ResizeFailed};

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        const result = pseudoConsoleApi().resize(
            self.pseudo_console,
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
        );

        if (result != windows.S_OK) return error.ResizeFailed;
        self.size = size;
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(_: *WindowsPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

test {
    const testing = std.testing;
    var ws: winsize = .{
        .ws_row = 50,
        .ws_col = 80,
        .ws_xpixel = 1,
        .ws_ypixel = 1,
    };

    var pty = try Pty.open(ws);
    defer pty.deinit();

    // Initialize size should match what we gave it
    try testing.expectEqual(ws, try pty.getSize());

    // Can set and read new sizes
    ws.ws_row *= 2;
    try pty.setSize(ws);
    try testing.expectEqual(ws, try pty.getSize());

    switch (builtin.os.tag) {
        .freebsd => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        .linux => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/pts/")),
        .macos => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        else => try testing.expect(pty.getProcessInfo(.tty_name) == null),
    }
}
