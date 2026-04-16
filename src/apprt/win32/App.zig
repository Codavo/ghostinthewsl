/// Win32 application runtime for Ghostty. This is a minimal native Windows
/// application using the Win32 API with OpenGL rendering.
///
/// An App owns a list of Windows, each with its own HWND and split tree.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const SplitTree = @import("SplitTree.zig");
const CommandPalette = @import("CommandPalette.zig");
const PromptDialog = @import("PromptDialog.zig");
const SearchPanel = @import("SearchPanel.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.win32);

// Re-exported types for convenience
const HWND = sys.HWND;
const HINSTANCE = sys.HINSTANCE;
const BOOL = sys.BOOL;
const UINT = sys.UINT;
const DWORD = sys.DWORD;
const WPARAM = sys.WPARAM;
const LPARAM = sys.LPARAM;
const LRESULT = sys.LRESULT;
const RECT = sys.RECT;
const MSG = sys.MSG;
const PAINTSTRUCT = sys.PAINTSTRUCT;
const WM_CLOSE = sys.WM_CLOSE;
const WM_SIZE = sys.WM_SIZE;
const WM_PAINT = sys.WM_PAINT;
const WM_KEYDOWN = sys.WM_KEYDOWN;
const WM_CHAR = sys.WM_CHAR;
const WM_COPYDATA = sys.WM_COPYDATA;
const WM_WAKEUP = sys.WM_WAKEUP;
const COPYDATASTRUCT = sys.COPYDATASTRUCT;

// Additional externs not in sys.zig
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: u32) callconv(.winapi) c_int;
extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) BOOL;
extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetLayeredWindowAttributes(hWnd: HWND, crKey: u32, bAlpha: u8, dwFlags: u32) callconv(.winapi) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn FlashWindowEx(pfwi: *FLASHWINFO) callconv(.winapi) BOOL;
const WS_EX_LAYERED: u32 = 0x00080000;

const FLASHWINFO = extern struct {
    cbSize: UINT,
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};
const FLASHW_CAPTION: DWORD = 0x00000001;
const FLASHW_TRAY: DWORD = 0x00000002;
const FLASHW_ALL: DWORD = FLASHW_CAPTION | FLASHW_TRAY;
const FLASHW_TIMERNOFG: DWORD = 0x0000000C;
extern "advapi32" fn RegOpenKeyExW(hKey: ?*anyopaque, lpSubKey: [*:0]const u16, ulOptions: DWORD, samDesired: DWORD, phkResult: *?*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(hKey: ?*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn RegQueryValueExW(hKey: ?*anyopaque, lpValueName: [*:0]const u16, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?[*]u8, lpcbData: ?*DWORD) callconv(.winapi) i32;
extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(.winapi) ?*anyopaque;
extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: ?*anyopaque) callconv(.winapi) BOOL;
extern "imm32" fn ImmSetCompositionWindow(hIMC: ?*anyopaque, lpCompForm: *COMPOSITIONFORM) callconv(.winapi) BOOL;
extern "imm32" fn ImmSetCompositionFontW(hIMC: ?*anyopaque, lplf: *LOGFONTW) callconv(.winapi) BOOL;
extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
const HKEY_CURRENT_USER: ?*anyopaque = @ptrFromInt(0x80000001);
const KEY_READ: DWORD = 0x20019;

const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: sys.POINT,
    rcArea: RECT,
};

const LOGFONTW = extern struct {
    lfHeight: i32,
    lfWidth: i32,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 0,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = [_]u16{0} ** 32,
};

const NIM_ADD: DWORD = 0x00000000;
const NIM_MODIFY: DWORD = 0x00000001;
const NIM_DELETE: DWORD = 0x00000002;
const NIF_ICON: DWORD = 0x00000002;
const NIF_TIP: DWORD = 0x00000004;
const NIF_INFO: DWORD = 0x00000010;
const NIIF_INFO: DWORD = 0x00000001;
const IPC_COPYDATA_NEW_WINDOW_ARGS: usize = 1;

const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT = 0,
    hIcon: sys.HICON,
    szTip: [128]u16 = [_]u16{0} ** 128,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]u16 = [_]u16{0} ** 256,
    uTimeoutOrVersion: UINT = 0,
    szInfoTitle: [64]u16 = [_]u16{0} ** 64,
    dwInfoFlags: DWORD = 0,
    guidItem: extern struct { a: u32 = 0, b: u16 = 0, c: u16 = 0, d: [8]u8 = [_]u8{0} ** 8 } = .{},
    hBalloonIcon: ?*anyopaque = null,
};

// ============================================================================
// App state
// ============================================================================

/// The core app instance.
core_app: *CoreApp,

/// The configuration.
config: *Config,

/// The allocator.
alloc: Allocator,

/// Whether the app is running.
running: bool = true,

/// All top-level windows owned by this app.
windows: std.ArrayListUnmanaged(*Window) = .{},

/// The window that currently has focus.
focused_window: ?*Window = null,

/// Whether the tray icon is registered (for notifications).
tray_registered: bool = false,

/// Dedicated quick terminal window, if one has been created.
quick_terminal_window: ?*Window = null,

/// The command palette (created lazily).
command_palette: CommandPalette = undefined,
command_palette_initialized: bool = false,

/// Prompt dialog for title editing.
prompt_dialog: PromptDialog = undefined,
prompt_dialog_initialized: bool = false,

/// Search panel for incremental search.
search_panel: SearchPanel = undefined,
search_panel_initialized: bool = false,

/// Single-instance mutex handle.
instance_mutex: ?*anyopaque = null,

const NewWindowOptions = Window.CreateOptions;

fn parseNewWindowArguments(alloc: Allocator, arguments: []const []const u8) !NewWindowOptions {
    var opts: NewWindowOptions = .{};
    errdefer opts.deinit(alloc);

    var direct_args: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (direct_args.items) |arg| alloc.free(arg);
        direct_args.deinit(alloc);
    }

    var e_seen = false;
    for (arguments) |arg| {
        if (e_seen) {
            try direct_args.append(alloc, try alloc.dupeZ(u8, arg));
            continue;
        }

        if (std.mem.eql(u8, arg, "-e")) {
            e_seen = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--command=")) {
            if (opts.command) |cmd| cmd.deinit(alloc);
            var cmd: configpkg.Command = undefined;
            try cmd.parseCLI(alloc, arg["--command=".len..]);
            opts.command = cmd;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--working-directory=")) {
            if (opts.working_directory) |wd| switch (wd) {
                .path => |path| alloc.free(path),
                else => {},
            };
            var wd: configpkg.WorkingDirectory = undefined;
            try wd.parseCLI(alloc, arg["--working-directory=".len..]);
            opts.working_directory = wd;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--title=")) {
            if (opts.title) |title| alloc.free(title);
            opts.title = try alloc.dupeZ(u8, std.mem.trim(u8, arg["--title=".len..], &std.ascii.whitespace));
            continue;
        }
    }

    if (direct_args.items.len > 0) {
        if (opts.command) |cmd| cmd.deinit(alloc);
        opts.command = .{ .direct = try direct_args.toOwnedSlice(alloc) };
    } else {
        direct_args.deinit(alloc);
    }

    return opts;
}

fn deserializeNewWindowArguments(alloc: Allocator, payload: []const u8) ![][:0]const u8 {
    var args: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (args.items) |arg| alloc.free(arg);
        args.deinit(alloc);
    }

    var i: usize = 0;
    while (i < payload.len) {
        const end = std.mem.indexOfScalarPos(u8, payload, i, 0) orelse break;
        if (end == i) break;
        try args.append(alloc, try alloc.dupeZ(u8, payload[i..end]));
        i = end + 1;
    }

    return try args.toOwnedSlice(alloc);
}

fn serializeNewWindowArguments(alloc: Allocator, arguments: []const [:0]const u8) ![]u8 {
    var len: usize = 1;
    for (arguments) |arg| len += arg.len + 1;

    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);

    var i: usize = 0;
    for (arguments) |arg| {
        @memcpy(buf[i .. i + arg.len], arg);
        i += arg.len;
        buf[i] = 0;
        i += 1;
    }
    buf[i] = 0;
    return buf;
}

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;

    var config = try Config.load(alloc);
    errdefer config.deinit();

    const config_ptr = try alloc.create(Config);
    config_ptr.* = config;

    self.* = .{
        .core_app = core_app,
        .config = config_ptr,
        .alloc = alloc,
    };

    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Single-instance check: if another Ghostty is already running,
    // signal it to open a new window and exit this process.
    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\GhosttyWin32Mutex");
    self.instance_mutex = sys.CreateMutexW(null, 0, mutex_name);
    if (sys.GetLastError() == sys.ERROR_ALREADY_EXISTS) {
        // Another instance owns the mutex. Find its window and request a new one.
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
        if (sys.FindWindowW(class_name, null)) |other| {
            _ = sys.PostMessageW(other, sys.WM_APP_NEW_WINDOW, 0, 0);
        }
        // Clean up this mutex handle (doesn't release ownership since we don't own it)
        if (self.instance_mutex) |h| _ = sys.CloseHandle(h);
        self.instance_mutex = null;
        return error.AlreadyRunning;
    }

    // Create the first window
    const window = try Window.create(alloc, self, .none);
    try self.windows.append(alloc, window);
    self.focused_window = window;
}

pub fn run(self: *App) !void {
    log.info("starting Win32 event loop", .{});

    while (self.running) {
        var msg: MSG = std.mem.zeroes(MSG);
        const ret = sys.GetMessageW(&msg, null, 0, 0);
        if (ret == 0) {
            self.running = false;
            break;
        }
        if (ret == -1) {
            log.err("GetMessage failed", .{});
            return error.Win32Error;
        }

        // Let the command palette intercept keys if it's open
        if (self.command_palette_initialized and self.command_palette.hwnd != null) {
            if (msg.hwnd) |mh| {
                if (self.command_palette.preTranslateMessage(msg.message, mh, msg.wParam)) {
                    continue;
                }
            }
        }
        if (self.prompt_dialog_initialized and self.prompt_dialog.hwnd != null) {
            if (msg.hwnd) |mh| {
                if (self.prompt_dialog.preTranslateMessage(msg.message, mh, msg.wParam)) {
                    continue;
                }
            }
        }
        if (self.search_panel_initialized and self.search_panel.hwnd != null) {
            if (msg.hwnd) |mh| {
                if (self.search_panel.preTranslateMessage(msg.message, mh, msg.wParam)) {
                    continue;
                }
            }
        }

        _ = sys.TranslateMessage(&msg);
        _ = sys.DispatchMessageW(&msg);

        // After WM_CHAR processing, if palette is open, re-filter
        if (self.command_palette_initialized and self.command_palette.hwnd != null) {
            if (msg.message == WM_CHAR) {
                if (msg.hwnd) |mh| {
                    if (mh == self.command_palette.edit_hwnd) {
                        self.command_palette.refilter();
                    }
                }
            }
        }
    }
}

pub fn terminate(self: *App) void {
    if (self.command_palette_initialized) {
        self.command_palette.deinit();
    }
    if (self.prompt_dialog_initialized) self.prompt_dialog.deinit();
    if (self.search_panel_initialized) self.search_panel.deinit();
    if (self.tray_registered) {
        if (self.windows.items.len > 0) {
            if (self.windows.items[0].hwnd) |hwnd| {
                var nid: NOTIFYICONDATAW = std.mem.zeroes(NOTIFYICONDATAW);
                nid.cbSize = @sizeOf(NOTIFYICONDATAW);
                nid.hWnd = hwnd;
                nid.uID = 1;
                _ = Shell_NotifyIconW(NIM_DELETE, &nid);
            }
        }
    }
    for (self.windows.items) |w| {
        w.deinit();
        self.alloc.destroy(w);
    }
    self.windows.deinit(self.alloc);
    self.config.deinit();
    self.alloc.destroy(self.config);
    if (self.instance_mutex) |h| {
        _ = sys.ReleaseMutex(h);
        _ = sys.CloseHandle(h);
        self.instance_mutex = null;
    }
}

pub fn wakeup(self: *App) void {
    // Wake up all windows
    for (self.windows.items) |w| {
        if (w.hwnd) |hwnd| {
            _ = sys.PostMessageW(hwnd, WM_WAKEUP, 0, 0);
        }
    }
}

/// Create a new top-level window.
pub fn newWindow(self: *App, opts: NewWindowOptions) !void {
    const window = try Window.create(self.alloc, self, opts);
    try self.windows.append(self.alloc, window);
    if (opts.quick_terminal) self.quick_terminal_window = window;
    self.focused_window = window;
}

/// Close a window. If it's the last window, quit the app.
pub fn closeWindow(self: *App, window: *Window) void {
    // Find and remove from list
    for (self.windows.items, 0..) |w, i| {
        if (w == window) {
            _ = self.windows.orderedRemove(i);
            break;
        }
    }

    // Destroy the Window's HWND if still alive (normally done already)
    if (self.quick_terminal_window == window) {
        self.quick_terminal_window = null;
    }
    window.deinit();
    self.alloc.destroy(window);

    // Update focused_window
    if (self.focused_window == window) {
        self.focused_window = if (self.windows.items.len > 0)
            self.windows.items[self.windows.items.len - 1]
        else
            null;
    }

    // If no more windows, quit the app
    if (self.windows.items.len == 0) {
        sys.PostQuitMessage(0);
    }
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            sys.PostQuitMessage(0);
            return true;
        },
        .new_window => {
            self.newWindow(.none) catch |err| {
                log.err("new_window failed: {}", .{err});
                return false;
            };
            return true;
        },
        .toggle_command_palette => {
            const window = self.focused_window orelse return false;
            if (!self.command_palette_initialized) {
                self.command_palette = CommandPalette.init(self.alloc, self);
                self.command_palette_initialized = true;
            }
            self.command_palette.toggle(window);
            return true;
        },
        .set_title => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                const utf16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, value.title) catch return false;
                defer self.alloc.free(utf16);
                _ = sys.SetWindowTextW(hwnd, utf16.ptr);
            }
            return true;
        },
        .toggle_maximize => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                const maximized = sys.IsZoomed(hwnd) != 0;
                _ = sys.ShowWindow(hwnd, if (maximized) sys.SW_RESTORE else sys.SW_MAXIMIZE);
            }
            return true;
        },
        .toggle_fullscreen => {
            const window = self.focused_window orelse return false;
            window.toggleFullscreen();
            return true;
        },
        .new_split => {
            const window = self.focused_window orelse return false;
            const existing = window.getFocusedSurface() orelse return false;
            window.newSplit(existing, value) catch |err| {
                log.err("new_split failed: {}", .{err});
                return false;
            };
            return true;
        },
        .goto_split => {
            const window = self.focused_window orelse return false;
            window.gotoSplit(value);
            return true;
        },
        .equalize_splits => {
            const window = self.focused_window orelse return false;
            window.equalizeSplits();
            return true;
        },
        .resize_split => {
            const window = self.focused_window orelse return false;
            window.resizeSplit(value);
            return true;
        },
        .mouse_shape => {
            const window = self.focused_window orelse return false;
            if (window.getFocusedSurface()) |s| s.setMouseShape(value);
            return true;
        },
        .mouse_visibility => {
            const window = self.focused_window orelse return false;
            if (window.getFocusedSurface()) |s| s.setMouseVisibility(value == .visible);
            return true;
        },
        .open_url => {
            const url_utf16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, value.url) catch return false;
            defer self.alloc.free(url_utf16);
            const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
            _ = sys.ShellExecuteW(null, verb, url_utf16.ptr, null, null, sys.SW_SHOWNORMAL);
            return true;
        },
        .ring_bell => {
            _ = MessageBeep(0xFFFFFFFF);
            return true;
        },
        .progress_report => {
            const surface = switch (target) {
                .app => return false,
                .surface => |core| core.rt_surface,
            };
            surface.setProgressReport(value);
            return true;
        },
        .desktop_notification => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| self.showNotification(hwnd, value.title, value.body);
            return true;
        },
        .quit_timer => return true,
        .mouse_over_link => return true,
        .inspector => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            switch (value) {
                .show => core.activateInspector() catch return false,
                .hide => core.deactivateInspector(),
                .toggle => if (core.inspector != null) core.deactivateInspector() else core.activateInspector() catch return false,
            }
            return true;
        },
        .reload_config => {
            if (!value.soft) {
                var new_config = Config.load(self.alloc) catch |err| {
                    log.err("failed to reload config: {}", .{err});
                    return false;
                };
                self.config.deinit();
                self.config.* = new_config;
                _ = &new_config;
            }
            self.core_app.updateConfig(self, self.config) catch |err| {
                log.err("failed to update config: {}", .{err});
                return false;
            };
            return true;
        },
        .config_change => return true,
        .show_child_exited => {
            if (value.exit_code == 0) return true;
            const surface = switch (target) {
                .app => return false,
                .surface => |core| core.rt_surface,
            };
            const window = surface.window orelse return false;
            const hwnd = window.hwnd orelse return false;

            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &msg_buf,
                "Process exited with code {} after {} ms.",
                .{ value.exit_code, value.runtime_ms },
            ) catch return false;
            const msg_w = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, msg) catch return false;
            defer self.alloc.free(msg_w);

            const caption = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
            _ = MessageBoxW(hwnd, msg_w.ptr, caption, 0x00000040);
            return true;
        },
        .open_config => {
            const path = configpkg.edit.openPath(self.alloc) catch return false;
            defer self.alloc.free(path);
            const path_w = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, path) catch return false;
            defer self.alloc.free(path_w);
            _ = sys.ShellExecuteW(null, null, path_w.ptr, null, null, sys.SW_SHOWNORMAL);
            return true;
        },
        .close_window => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| _ = sys.PostMessageW(hwnd, WM_CLOSE, 0, 0);
            return true;
        },
        .reset_window_size => {
            const window = self.focused_window orelse return false;
            window.applyConfiguredWindowSize();
            return true;
        },
        .copy_title_to_clipboard => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                var title_buf: [512]u16 = undefined;
                const len = GetWindowTextW(hwnd, &title_buf, title_buf.len);
                if (len > 0) {
                    if (window.focused_surface) |s| {
                        s.setClipboard(.standard, &.{.{
                            .mime = "text/plain",
                            .data = std.unicode.utf16LeToUtf8AllocZ(
                                self.alloc,
                                title_buf[0..@intCast(len)],
                            ) catch return false,
                        }}, false) catch return false;
                    }
                }
            }
            return true;
        },
        .toggle_split_zoom => {
            const window = self.focused_window orelse return false;
            window.relayout();
            return true;
        },
        .render => {
            const window = self.focused_window orelse return false;
            if (window.focused_surface) |s| _ = sys.InvalidateRect(s.hwnd, null, 0);
            return true;
        },
        .present_terminal => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                _ = SetForegroundWindow(hwnd);
                _ = sys.ShowWindow(hwnd, sys.SW_SHOWNORMAL);
            }
            return true;
        },
        .renderer_health => return true,
        .color_change => return true,
        .pwd => return true,
        .secure_input => return true,
        .initial_size, .cell_size, .size_limit => return true,
        .scrollbar => return true,
        .close_all_windows => {
            // Close all windows
            var i = self.windows.items.len;
            while (i > 0) {
                i -= 1;
                const w = self.windows.items[i];
                if (w.hwnd) |hwnd| _ = sys.PostMessageW(hwnd, WM_CLOSE, 0, 0);
            }
            return true;
        },
        .toggle_window_decorations => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                const style = sys.GetWindowLongW(hwnd, sys.GWL_STYLE);
                const has_caption = (style & sys.WS_CAPTION_BIT) != 0;
                const new_style = if (has_caption)
                    style & ~@as(i32, @bitCast(sys.WS_CAPTION_BIT))
                else
                    style | @as(i32, @bitCast(sys.WS_CAPTION_BIT));
                _ = sys.SetWindowLongW(hwnd, sys.GWL_STYLE, new_style);
                _ = sys.SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x0020 | 0x0001 | 0x0002 | 0x0004);
            }
            return true;
        },
        .toggle_visibility => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                const visible = IsWindowVisible(hwnd) != 0;
                _ = sys.ShowWindow(hwnd, if (visible) 0 else sys.SW_SHOWNORMAL);
            }
            return true;
        },
        .float_window => {
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                const topmost: ?HWND = switch (value) {
                    .on => @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))),
                    .off => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))),
                    .toggle => blk: {
                        const ex = sys.GetWindowLongW(hwnd, sys.GWL_EXSTYLE);
                        break :blk if ((ex & sys.WS_EX_TOPMOST) != 0)
                            @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))))
                        else
                            @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
                    },
                };
                _ = sys.SetWindowPos(hwnd, topmost, 0, 0, 0, 0, 0x0001 | 0x0002);
            }
            return true;
        },
        .goto_window => {
            if (self.windows.items.len <= 1) return true;
            const cur = self.focused_window orelse return true;
            var idx: usize = 0;
            for (self.windows.items, 0..) |w, i| {
                if (w == cur) {
                    idx = i;
                    break;
                }
            }
            const next_idx: usize = switch (value) {
                .previous => (idx + self.windows.items.len - 1) % self.windows.items.len,
                .next => (idx + 1) % self.windows.items.len,
            };
            const target_window = self.windows.items[next_idx];
            if (target_window.hwnd) |hwnd| {
                _ = SetForegroundWindow(hwnd);
            }
            self.focused_window = target_window;
            return true;
        },
        .toggle_background_opacity => {
            // Toggle between fully opaque and slightly translucent (0xD0 = ~82%).
            const window = self.focused_window orelse return false;
            if (window.hwnd) |hwnd| {
                const ex = sys.GetWindowLongW(hwnd, sys.GWL_EXSTYLE);
                const is_layered = (ex & WS_EX_LAYERED) != 0;
                if (is_layered) {
                    _ = sys.SetWindowLongW(hwnd, sys.GWL_EXSTYLE, ex & ~@as(i32, @bitCast(@as(u32, WS_EX_LAYERED))));
                } else {
                    _ = sys.SetWindowLongW(hwnd, sys.GWL_EXSTYLE, ex | @as(i32, @bitCast(@as(u32, WS_EX_LAYERED))));
                    _ = SetLayeredWindowAttributes(hwnd, 0, 0xD0, 0x2); // LWA_ALPHA
                }
            }
            return true;
        },
        .check_for_updates => {
            // Open the Ghostty releases page in the default browser
            const url = std.unicode.utf8ToUtf16LeStringLiteral("https://ghostty.org/download");
            const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
            _ = sys.ShellExecuteW(null, verb, url, null, null, sys.SW_SHOWNORMAL);
            return true;
        },
        .show_on_screen_keyboard => {
            // Launch the Windows on-screen keyboard
            const osk = std.unicode.utf8ToUtf16LeStringLiteral("osk.exe");
            const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
            _ = sys.ShellExecuteW(null, verb, osk, null, null, sys.SW_SHOWNORMAL);
            return true;
        },
        .prompt_title => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            const rt_surface = core.rt_surface;
            const window = rt_surface.window orelse return false;
            if (!self.prompt_dialog_initialized) {
                self.prompt_dialog = PromptDialog.init(self.alloc, self);
                self.prompt_dialog_initialized = true;
            }
            const initial = switch (value) {
                .surface => rt_surface.getTitle() orelse "",
                .tab => window.getActiveTabTitle() orelse "",
            };
            self.prompt_dialog.open(
                window,
                core,
                switch (value) {
                    .surface => .surface_title,
                    .tab => .tab_title,
                },
                initial,
            ) catch return false;
            return true;
        },
        .command_finished => {
            // Flash the taskbar button if the window is not focused. This
            // matches the GTK apprt's "attention" behavior for long-running
            // commands that finished in the background.
            const window = self.focused_window orelse return true;
            if (window.hwnd) |hwnd| {
                // Only flash if not currently the foreground window
                if (GetForegroundWindow() != hwnd) {
                    var fw = FLASHWINFO{
                        .cbSize = @sizeOf(FLASHWINFO),
                        .hwnd = hwnd,
                        .dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG,
                        .uCount = 3,
                        .dwTimeout = 0,
                    };
                    _ = FlashWindowEx(&fw);
                }
            }
            return true;
        },
        .readonly => {
            // Update the window title to indicate readonly state.
            const window = self.focused_window orelse return true;
            if (window.hwnd) |hwnd| {
                const title = switch (value) {
                    .on => std.unicode.utf8ToUtf16LeStringLiteral("Ghostty (read-only)"),
                    .off => std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                };
                _ = sys.SetWindowTextW(hwnd, title);
            }
            return true;
        },
        .key_sequence => {
            // Show/hide a hint in the window title when a multi-key binding
            // sequence is in progress.
            const window = self.focused_window orelse return true;
            if (window.hwnd) |hwnd| {
                const title = switch (value) {
                    .trigger => std.unicode.utf8ToUtf16LeStringLiteral("Ghostty (key sequence...)"),
                    .end => std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                };
                _ = sys.SetWindowTextW(hwnd, title);
            }
            return true;
        },
        .key_table => {
            // Show the active key table name (if any) in the window title.
            const window = self.focused_window orelse return true;
            if (window.hwnd) |hwnd| {
                switch (value) {
                    .activate => |name| {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrintZ(&buf, "Ghostty ({s})", .{name}) catch return true;
                        const wtext = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, msg) catch return true;
                        defer self.alloc.free(wtext);
                        _ = sys.SetWindowTextW(hwnd, wtext.ptr);
                    },
                    .deactivate, .deactivate_all => {
                        _ = sys.SetWindowTextW(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"));
                    },
                }
            }
            return true;
        },
        .new_tab => {
            const window = self.focused_window orelse return false;
            window.newTab(.none) catch return false;
            return true;
        },
        .close_tab => {
            const window = self.focused_window orelse return false;
            window.closeTab(value);
            return true;
        },
        .toggle_tab_overview => {
            const window = self.focused_window orelse return false;
            if (window.tab_hwnd) |hwnd| _ = sys.SetFocus(hwnd);
            return true;
        },
        .toggle_quick_terminal => {
            if (self.quick_terminal_window) |window| {
                if (window.hwnd) |hwnd| {
                    if (IsWindowVisible(hwnd) != 0) {
                        _ = sys.ShowWindow(hwnd, 0);
                    } else {
                        window.applyQuickTerminalLayout();
                        _ = sys.ShowWindow(hwnd, sys.SW_SHOWNORMAL);
                        _ = SetForegroundWindow(hwnd);
                        self.focused_window = window;
                    }
                    return true;
                }
            }

            self.newWindow(.{ .quick_terminal = true }) catch return false;
            if (self.quick_terminal_window) |window| {
                if (window.hwnd) |hwnd| _ = SetForegroundWindow(hwnd);
            }
            return true;
        },
        .move_tab => {
            const window = self.focused_window orelse return false;
            _ = window.moveTab(value.amount);
            return true;
        },
        .goto_tab => {
            const window = self.focused_window orelse return false;
            return window.gotoTab(value);
        },
        .show_gtk_inspector => return false,
        .render_inspector => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            redrawInspector(self, core.rt_surface);
            return true;
        },
        .set_tab_title => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            const window = core.rt_surface.window orelse return false;
            window.setActiveTabTitle(value.title) catch return false;
            return true;
        },
        .undo,
        .redo,
        => return true,
        .start_search => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            const rt_surface = core.rt_surface;
            const window = rt_surface.window orelse return false;
            if (!self.search_panel_initialized) {
                self.search_panel = SearchPanel.init(self.alloc, self);
                self.search_panel_initialized = true;
            }
            self.search_panel.open(window, core, value.needle) catch return false;
            return true;
        },
        .end_search => {
            if (self.search_panel_initialized and self.search_panel.hwnd != null) self.search_panel.close(false);
            return true;
        },
        .search_total => {
            if (self.search_panel_initialized) self.search_panel.setSearchTotal(value.total);
            return true;
        },
        .search_selected => {
            if (self.search_panel_initialized) self.search_panel.setSearchSelected(value.selected);
            return true;
        },
    }
}

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);
    const stderr = &stderr_writer.interface;

    switch (action) {
        .new_window => {
            switch (target) {
                .class => |class| {
                    try stderr.print(
                        "Win32 IPC does not yet support targeting a custom Ghostty class: {s}\n",
                        .{class},
                    );
                    try stderr.flush();
                    return error.IPCFailed;
                },
                .detect => {},
            }

            const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
            const hwnd = sys.FindWindowW(class_name, null) orelse {
                try stderr.print("No running Ghostty Win32 instance was found.\n", .{});
                try stderr.flush();
                return error.IPCFailed;
            };

            if (value.arguments) |arguments| {
                const payload = try serializeNewWindowArguments(alloc, arguments);
                defer alloc.free(payload);

                const cds: COPYDATASTRUCT = .{
                    .dwData = IPC_COPYDATA_NEW_WINDOW_ARGS,
                    .cbData = @intCast(payload.len),
                    .lpData = payload.ptr,
                };

                if (sys.SendMessageW(
                    hwnd,
                    WM_COPYDATA,
                    0,
                    @bitCast(@intFromPtr(&cds)),
                ) == 0) {
                    try stderr.print("Failed to send a new-window request with arguments to Ghostty.\n", .{});
                    try stderr.flush();
                    return error.IPCFailed;
                }

                return true;
            }

            if (sys.PostMessageW(hwnd, sys.WM_APP_NEW_WINDOW, 0, 0) == 0) {
                try stderr.print("Failed to send a new-window request to Ghostty.\n", .{});
                try stderr.flush();
                return error.IPCFailed;
            }
            return true;
        },
    }
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}

/// Detect the Windows light/dark theme from the registry.
pub fn detectColorScheme(_: *App) apprt.ColorScheme {
    var hkey: ?*anyopaque = null;
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    if (RegOpenKeyExW(HKEY_CURRENT_USER, subkey, 0, KEY_READ, &hkey) != 0) return .light;
    defer _ = RegCloseKey(hkey);

    var value: u32 = 1;
    var value_size: u32 = @sizeOf(u32);
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    if (RegQueryValueExW(hkey, value_name, null, null, @ptrCast(&value), &value_size) != 0) return .light;
    return if (value == 0) .dark else .light;
}

fn showNotification(self: *App, hwnd: HWND, title: [:0]const u8, body: [:0]const u8) void {
    var nid: NOTIFYICONDATAW = std.mem.zeroes(NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_ICON | NIF_INFO | NIF_TIP;
    nid.dwInfoFlags = NIIF_INFO;
    nid.hIcon = sys.LoadIconW(sys.GetModuleHandleW(null), @ptrFromInt(1));

    const title_utf16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, title) catch return;
    defer self.alloc.free(title_utf16);
    const body_utf16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, body) catch return;
    defer self.alloc.free(body_utf16);

    const title_len = @min(title_utf16.len, nid.szInfoTitle.len - 1);
    @memcpy(nid.szInfoTitle[0..title_len], title_utf16[0..title_len]);
    nid.szInfoTitle[title_len] = 0;

    const body_len = @min(body_utf16.len, nid.szInfo.len - 1);
    @memcpy(nid.szInfo[0..body_len], body_utf16[0..body_len]);
    nid.szInfo[body_len] = 0;

    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(nid.szTip[0..tip.len], tip);

    if (!self.tray_registered) {
        _ = Shell_NotifyIconW(NIM_ADD, &nid);
        self.tray_registered = true;
    } else {
        _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
    }
}

// ============================================================================
// Input helpers
// ============================================================================

extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.winapi) i16;

fn getModifiers() @import("../../input.zig").Mods {
    const input = @import("../../input.zig");
    var mods: input.Mods = .{};
    if (GetKeyState(0x10) < 0) {
        mods.shift = true;
        mods.sides.shift = if (GetKeyState(0xA1) < 0) .right else .left;
    }
    if (GetKeyState(0x11) < 0) {
        mods.ctrl = true;
        mods.sides.ctrl = if (GetKeyState(0xA3) < 0) .right else .left;
    }
    if (GetKeyState(0x12) < 0) {
        mods.alt = true;
        mods.sides.alt = if (GetKeyState(0xA5) < 0) .right else .left;
    }
    if (GetKeyState(0x5B) < 0 or GetKeyState(0x5C) < 0) {
        mods.super = true;
        mods.sides.super = if (GetKeyState(0x5C) < 0) .right else .left;
    }
    return mods;
}

fn handleTextInput(surface: *Surface, msg: UINT, wparam: WPARAM) LRESULT {
    _ = msg;
    if (surface.core_surface) |core| {
        const mods = getModifiers();
        const codepoint: u21 = @intCast(wparam);
        if (codepoint < 0x20 or codepoint == 0x7f) return 0;
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
        if (len > 0) {
            const input = @import("../../input.zig");
            var consumed_mods: input.Mods = .{};

            // AltGr commonly appears as Left Ctrl + Right Alt on Windows.
            // When it generates text, those modifiers were consumed to
            // produce the character and should not be interpreted as a
            // Ctrl+Alt shortcut by the core.
            if (mods.ctrl and mods.alt and mods.sides.alt == .right) {
                consumed_mods.ctrl = true;
                consumed_mods.alt = true;
            }

            const event = input.KeyEvent{
                .action = .press,
                .mods = mods,
                .consumed_mods = consumed_mods,
                .utf8 = utf8_buf[0..len],
            };
            _ = core.keyCallback(event) catch |err| {
                log.err("key callback error: {}", .{err});
            };
        }
    }
    return 0;
}

fn isTextVirtualKey(vk: WPARAM) bool {
    return switch (vk) {
        0x41...0x5A,
        0x30...0x39,
        0x20,
        0xBA,
        0xBB,
        0xBC,
        0xBD,
        0xBE,
        0xBF,
        0xC0,
        0xDB,
        0xDC,
        0xDD,
        0xDE,
        => true,
        else => false,
    };
}

fn shouldDispatchKeyPress(vk: WPARAM, mods: @import("../../input.zig").Mods) bool {
    if (!isTextVirtualKey(vk)) return true;

    // Text-producing keys should usually be delivered through WM_CHAR /
    // WM_SYSCHAR so the core receives a single event with the generated
    // character instead of a duplicate press+text pair. Keep raw key
    // presses only for actual shortcuts.
    if (mods.super) return true;
    if (mods.alt and mods.sides.alt != .right) return true;
    if (mods.ctrl and !(mods.alt and mods.sides.alt == .right)) return true;

    return false;
}

fn mapVirtualKey(vk: WPARAM) @import("../../input.zig").Key {
    return switch (vk) {
        0x41 => .key_a, 0x42 => .key_b, 0x43 => .key_c, 0x44 => .key_d,
        0x45 => .key_e, 0x46 => .key_f, 0x47 => .key_g, 0x48 => .key_h,
        0x49 => .key_i, 0x4A => .key_j, 0x4B => .key_k, 0x4C => .key_l,
        0x4D => .key_m, 0x4E => .key_n, 0x4F => .key_o, 0x50 => .key_p,
        0x51 => .key_q, 0x52 => .key_r, 0x53 => .key_s, 0x54 => .key_t,
        0x55 => .key_u, 0x56 => .key_v, 0x57 => .key_w, 0x58 => .key_x,
        0x59 => .key_y, 0x5A => .key_z,
        0x30 => .digit_0, 0x31 => .digit_1, 0x32 => .digit_2, 0x33 => .digit_3,
        0x34 => .digit_4, 0x35 => .digit_5, 0x36 => .digit_6, 0x37 => .digit_7,
        0x38 => .digit_8, 0x39 => .digit_9,
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => .enter,
        0x1B => .escape,
        0x20 => .space,
        0x25 => .arrow_left,
        0x26 => .arrow_up,
        0x27 => .arrow_right,
        0x28 => .arrow_down,
        0x2E => .delete,
        0x24 => .home,
        0x23 => .end,
        0x21 => .page_up,
        0x22 => .page_down,
        0x2D => .insert,
        0x10 => .shift_left,
        0x11 => .control_left,
        0x12 => .alt_left,
        0xBD => .minus,
        0xBB => .equal,
        0xDB => .bracket_left,
        0xDD => .bracket_right,
        0xDC => .backslash,
        0xBA => .semicolon,
        0xDE => .quote,
        0xBC => .comma,
        0xBE => .period,
        0xBF => .slash,
        0x70 => .f1, 0x71 => .f2, 0x72 => .f3, 0x73 => .f4,
        0x74 => .f5, 0x75 => .f6, 0x76 => .f7, 0x77 => .f8,
        0x78 => .f9, 0x79 => .f10, 0x7A => .f11, 0x7B => .f12,
        else => .unidentified,
    };
}

// ============================================================================
// Main window procedure (for top-level windows)
// ============================================================================

fn getWindow(hwnd: HWND) ?*Window {
    const ptr = sys.GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

pub fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    if (getWindow(hwnd)) |window| {
        if (window.handleTopLevelMessage(msg, wparam, lparam)) |result| return result;
    }
    switch (msg) {
        WM_COPYDATA => {
            const window = getWindow(hwnd) orelse return 0;
            const cds: *const COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (cds.dwData != IPC_COPYDATA_NEW_WINDOW_ARGS or cds.lpData == null) return 0;

            const payload: []const u8 = @as([*]const u8, @ptrCast(cds.lpData.?))[0..cds.cbData];
            const args = deserializeNewWindowArguments(window.app.alloc, payload) catch |err| {
                log.err("failed to decode Win32 IPC args: {}", .{err});
                return 0;
            };
            defer {
                for (args) |arg| window.app.alloc.free(arg);
                window.app.alloc.free(args);
            }

            var opts = parseNewWindowArguments(window.app.alloc, args) catch |err| {
                log.err("failed to parse Win32 IPC args: {}", .{err});
                return 0;
            };
            defer opts.deinit(window.app.alloc);

            window.app.newWindow(opts) catch |err| {
                log.err("new_window from WM_COPYDATA failed: {}", .{err});
                return 0;
            };
            return 1;
        },
        WM_CLOSE => {
            if (getWindow(hwnd)) |window| {
                // Close the focused surface's core, which will trigger
                // Surface.close -> Window.closeSurface -> App.closeWindow
                if (window.getFocusedSurface()) |s| {
                    if (s.core_surface) |core| {
                        core.close();
                        return 0;
                    }
                }
                // Fallback: close the window directly
                window.app.closeWindow(window);
            }
            return 0;
        },
        WM_SIZE => {
            if (getWindow(hwnd)) |window| {
                if (window.surface_initialized and window.tree != null) {
                    window.relayout();
                }
            }
            return 0;
        },
        0x001A => { // WM_SETTINGCHANGE
            if (getWindow(hwnd)) |window| {
                if (window.focused_surface) |s| {
                    if (s.core_surface) |core| {
                        core.colorSchemeCallback(window.app.detectColorScheme()) catch {};
                    }
                }
            }
            return 0;
        },
        0x0007, 0x0008 => { // WM_SETFOCUS, WM_KILLFOCUS
            if (getWindow(hwnd)) |window| {
                const focused = msg == 0x0007;
                window.app.core_app.focusEvent(focused);
                if (focused) {
                    window.app.focused_window = window;
                    if (window.getFocusedSurface()) |s| _ = sys.SetFocus(s.hwnd);
                }
            }
            return 0;
        },
        WM_WAKEUP => {
            if (getWindow(hwnd)) |window| {
                window.app.core_app.tick(window.app) catch |err| {
                    log.err("core app tick failed: {}", .{err});
                };
            }
            return 0;
        },
        sys.WM_APP_NEW_WINDOW => {
            // Another instance requested that we open a new window.
            if (getWindow(hwnd)) |window| {
                window.app.newWindow(.none) catch |err| {
                    log.err("new_window from IPC failed: {}", .{err});
                };
            }
            return 0;
        },
        else => return sys.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ============================================================================
// Surface child window message dispatch
// ============================================================================

pub fn surfaceDispatch(app: *App, surface: *Surface, hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) LRESULT {
    switch (msg) {
        WM_PAINT => {
            var ps: PAINTSTRUCT = std.mem.zeroes(PAINTSTRUCT);
            _ = sys.BeginPaint(hwnd, &ps);
            _ = sys.EndPaint(hwnd, &ps);
            return 0;
        },
        WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            if (width > 0 and height > 0) {
                surface.width = width;
                surface.height = height;
                if (surface.core_surface) |core| {
                    core.sizeCallback(.{
                        .width = width,
                        .height = height,
                    }) catch |err| {
                        log.err("size callback error: {}", .{err});
                    };
                }
            }
            return 0;
        },
        WM_CHAR, 0x0106 => return handleTextInput(surface, msg, wparam),
        WM_KEYDOWN, 0x0104 => {
            if (surface.core_surface) |core| {
                const mods = getModifiers();
                if (!shouldDispatchKeyPress(wparam, mods)) return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
                const key = mapVirtualKey(wparam);
                if (key != .unidentified) {
                    const input = @import("../../input.zig");
                    const unshifted: u21 = switch (wparam) {
                        0x41...0x5A => @intCast(wparam + 32),
                        0x30...0x39 => @intCast(wparam),
                        0x20 => ' ',
                        0xBD => '-',
                        0xBB => '=',
                        0xDB => '[',
                        0xDD => ']',
                        0xDC => '\\',
                        0xBA => ';',
                        0xDE => '\'',
                        0xBC => ',',
                        0xBE => '.',
                        0xBF => '/',
                        0xC0 => '`',
                        else => 0,
                    };
                    const event = input.KeyEvent{
                        .action = .press,
                        .key = key,
                        .mods = mods,
                        .unshifted_codepoint = unshifted,
                    };
                    const effect = core.keyCallback(event) catch |err| {
                        log.err("key callback error: {}", .{err});
                        return 0;
                    };
                    if (effect == .consumed or effect == .closed) return 0;
                }
            }
            return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        0x0101, 0x0105 => {
            if (surface.core_surface) |core| {
                const mods = getModifiers();
                const key = mapVirtualKey(wparam);
                if (key != .unidentified) {
                    const input = @import("../../input.zig");
                    const event = input.KeyEvent{
                        .action = .release,
                        .key = key,
                        .mods = mods,
                    };
                    _ = core.keyCallback(event) catch {};
                }
            }
            return 0;
        },
        0x0200 => {
            if (surface.core_surface) |core| {
                const x: f32 = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF)));
                const y: f32 = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
                surface.cursor_pos = .{ .x = x, .y = y };
                core.cursorPosCallback(.{ .x = x, .y = y }, getModifiers()) catch {};
            }
            return 0;
        },
        0x0201, 0x0204, 0x0207 => {
            if (surface.core_surface) |core| {
                surface.cursor_pos = .{
                    .x = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF))),
                    .y = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF))),
                };
                const input = @import("../../input.zig");
                const button: input.MouseButton = switch (msg) {
                    0x0201 => .left,
                    0x0204 => .right,
                    0x0207 => .middle,
                    else => .unknown,
                };
                _ = core.mouseButtonCallback(.press, button, getModifiers()) catch false;
                _ = SetCapture(hwnd);
                _ = sys.SetFocus(hwnd);
                if (surface.window) |w| {
                    w.focusSurface(surface);
                    app.focused_window = w;
                }
            }
            return 0;
        },
        0x0202, 0x0205, 0x0208 => {
            if (surface.core_surface) |core| {
                surface.cursor_pos = .{
                    .x = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF))),
                    .y = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF))),
                };
                const input = @import("../../input.zig");
                const button: input.MouseButton = switch (msg) {
                    0x0202 => .left,
                    0x0205 => .right,
                    0x0208 => .middle,
                    else => .unknown,
                };
                _ = core.mouseButtonCallback(.release, button, getModifiers()) catch false;
                _ = ReleaseCapture();
            }
            return 0;
        },
        0x020A => {
            if (surface.core_surface) |core| {
                surface.cursor_pos = .{
                    .x = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF))),
                    .y = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF))),
                };
                const delta: i16 = @truncate(@as(isize, @bitCast(wparam)) >> 16);
                const yoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
                const input = @import("../../input.zig");
                core.scrollCallback(0, yoff, input.ScrollMods{}) catch {};
            }
            return 0;
        },
        0x010D => { // WM_IME_STARTCOMPOSITION
            if (surface.core_surface) |core| {
                core.renderer_state.mutex.lock();
                const cursor = core.renderer_state.terminal.screens.active.cursor;
                core.renderer_state.mutex.unlock();
                const x: i32 = @intCast(cursor.x * core.size.cell.width + core.size.padding.left);
                const y: i32 = @intCast(cursor.y * core.size.cell.height + core.size.padding.top);

                const himc = ImmGetContext(hwnd);
                if (himc) |ctx| {
                    defer _ = ImmReleaseContext(hwnd, ctx);
                    var cf = COMPOSITIONFORM{
                        .dwStyle = 0x0002,
                        .ptCurrentPos = .{ .x = x, .y = y },
                        .rcArea = std.mem.zeroes(RECT),
                    };
                    _ = ImmSetCompositionWindow(ctx, &cf);

                    const dpi = sys.GetDpiForWindow(hwnd);
                    const dpi_f: f32 = if (dpi > 0) @floatFromInt(dpi) else 96.0;
                    const font_px: i32 = @intFromFloat(app.config.@"font-size" * dpi_f / 72.0);
                    var lf: LOGFONTW = std.mem.zeroes(LOGFONTW);
                    lf.lfHeight = -font_px;
                    lf.lfWidth = 0;
                    lf.lfCharSet = 1;
                    _ = ImmSetCompositionFontW(ctx, &lf);
                }
            }
            return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        0x0007, 0x0008 => {
            if (surface.core_surface) |core| {
                const focused = msg == 0x0007;
                core.focusCallback(focused) catch {};
                if (focused) {
                    if (surface.window) |w| {
                        w.focusSurface(surface);
                        app.focused_window = w;
                    }
                }
            }
            return 0;
        },
        else => return sys.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
