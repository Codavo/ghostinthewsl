const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const CoreSurface = @import("../../Surface.zig");
const sys = @import("sys.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");

const HWND = sys.HWND;
const UINT = sys.UINT;
const WPARAM = sys.WPARAM;
const LPARAM = sys.LPARAM;
const LRESULT = sys.LRESULT;
const DWORD = sys.DWORD;

const WS_POPUP: u32 = 0x80000000;
const WS_BORDER: u32 = 0x00800000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CHILD: u32 = 0x40000000;
const WS_TABSTOP: u32 = 0x00010000;
const WS_EX_TOOLWINDOW: u32 = 0x00000080;
const ES_AUTOHSCROLL: u32 = 0x0080;
const BS_DEFPUSHBUTTON: u32 = 0x00000001;

const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_KEYDOWN: UINT = 0x0100;
const WM_SETFONT: UINT = 0x0030;
const WM_ACTIVATE: UINT = 0x0006;
const EN_CHANGE: u16 = 0x0300;

const VK_ESCAPE: WPARAM = 0x1B;

const EDIT_ID: usize = 200;
const PREV_ID: usize = 201;
const NEXT_ID: usize = 202;
const CLOSE_ID: usize = 203;
const STATUS_ID: usize = 204;

extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *sys.RECT) callconv(.winapi) sys.BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) sys.BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) sys.BOOL;
extern "user32" fn GetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*]u16, cchMax: c_int) callconv(.winapi) UINT;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) sys.BOOL;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.winapi) isize;
extern "gdi32" fn CreateFontW(cHeight: c_int, cWidth: c_int, cEscapement: c_int, cOrientation: c_int, cWeight: c_int, bItalic: DWORD, bUnderline: DWORD, bStrikeOut: DWORD, iCharSet: DWORD, iOutPrecision: DWORD, iClipPrecision: DWORD, iQuality: DWORD, iPitchAndFamily: DWORD, pszFaceName: [*:0]const u16) callconv(.winapi) ?*anyopaque;

alloc: Allocator,
app: *App,
hwnd: ?HWND = null,
edit_hwnd: ?HWND = null,
status_hwnd: ?HWND = null,
target_window: ?*Window = null,
target_surface: ?*CoreSurface = null,
opening: bool = false,
total: ?usize = null,
selected: ?usize = null,

pub fn init(alloc: Allocator, app: *App) Self {
    return .{ .alloc = alloc, .app = app };
}

pub fn deinit(self: *Self) void {
    if (self.hwnd) |h| _ = DestroyWindow(h);
}

pub fn open(self: *Self, window: *Window, surface: *CoreSurface, initial: [:0]const u8) !void {
    if (self.hwnd == null) {
        self.target_window = window;
        self.target_surface = surface;
        self.opening = true;
        defer self.opening = false;

        try registerClass();
        const parent = window.hwnd orelse return error.NoParent;
        var parent_rect: sys.RECT = std.mem.zeroes(sys.RECT);
        _ = GetWindowRect(parent, &parent_rect);
        const width: i32 = 460;
        const height: i32 = 120;
        const x = parent_rect.left + @divTrunc((parent_rect.right - parent_rect.left) - width, 2);
        const y = parent_rect.top + 20;
        const hinstance = sys.GetModuleHandleW(null);
        self.hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchPanel"), std.unicode.utf8ToUtf16LeStringLiteral("Search"), WS_POPUP | WS_BORDER, x, y, width, height, parent, null, hinstance, null) orelse return error.Win32Error;
        errdefer self.close(false);
        _ = SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.edit_hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL | WS_TABSTOP, 10, 10, width - 20, 28, self.hwnd, @ptrFromInt(EDIT_ID), hinstance, null) orelse return error.Win32Error;
        self.status_hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE, 10, 45, 200, 20, self.hwnd, @ptrFromInt(STATUS_ID), hinstance, null) orelse return error.Win32Error;
        const button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
        _ = CreateWindowExW(0, button_class, std.unicode.utf8ToUtf16LeStringLiteral("Prev"), WS_CHILD | WS_VISIBLE | WS_TABSTOP, width - 210, 70, 60, 28, self.hwnd, @ptrFromInt(PREV_ID), hinstance, null) orelse return error.Win32Error;
        _ = CreateWindowExW(0, button_class, std.unicode.utf8ToUtf16LeStringLiteral("Next"), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, width - 145, 70, 60, 28, self.hwnd, @ptrFromInt(NEXT_ID), hinstance, null) orelse return error.Win32Error;
        _ = CreateWindowExW(0, button_class, std.unicode.utf8ToUtf16LeStringLiteral("Close"), WS_CHILD | WS_VISIBLE | WS_TABSTOP, width - 80, 70, 60, 28, self.hwnd, @ptrFromInt(CLOSE_ID), hinstance, null) orelse return error.Win32Error;

        if (ui_font == null) ui_font = CreateFontW(-18, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 0, 0, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"));
        if (ui_font) |font| {
            if (self.edit_hwnd) |eh| _ = SendMessageW(eh, WM_SETFONT, @intFromPtr(font), 1);
            if (self.status_hwnd) |sh| _ = SendMessageW(sh, WM_SETFONT, @intFromPtr(font), 1);
        }
        _ = ShowWindow(self.hwnd.?, 1);
    } else {
        self.target_window = window;
        self.target_surface = surface;
    }

    try self.setSearchContents(initial);
    self.total = null;
    self.selected = null;
    self.updateStatus();
    if (self.edit_hwnd) |eh| _ = SetFocus(eh);
}

pub fn preTranslateMessage(self: *Self, message: UINT, hwnd: HWND, wparam: WPARAM) bool {
    if (self.hwnd == null) return false;
    if (message != WM_KEYDOWN) return false;
    if (hwnd != self.edit_hwnd) return false;
    switch (wparam) {
        VK_ESCAPE => {
            self.close(true);
            return true;
        },
        else => return false,
    }
}

pub fn close(self: *Self, notify_core: bool) void {
    if (notify_core) {
        if (self.target_surface) |surface| {
            _ = surface.performBindingAction(.end_search) catch {};
        }
    }
    if (self.hwnd) |h| _ = DestroyWindow(h);
    self.hwnd = null;
    self.edit_hwnd = null;
    self.status_hwnd = null;
    if (self.target_window) |w| {
        if (w.focused_surface) |s| _ = SetFocus(s.hwnd);
    }
}

pub fn setSearchContents(self: *Self, needle: [:0]const u8) !void {
    if (self.edit_hwnd) |eh| {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, needle);
        defer self.alloc.free(w);
        _ = SetWindowTextW(eh, w.ptr);
    }
    self.performSearch(needle);
}

pub fn setSearchTotal(self: *Self, total: ?usize) void {
    self.total = total;
    self.updateStatus();
}

pub fn setSearchSelected(self: *Self, selected: ?usize) void {
    self.selected = selected;
    self.updateStatus();
}

fn updateStatus(self: *Self) void {
    const status = if (self.total) |t|
        if (self.selected) |s|
            std.fmt.allocPrint(self.alloc, "{d}/{d}", .{ s + 1, t }) catch return
        else
            std.fmt.allocPrint(self.alloc, "0/{d}", .{t}) catch return
    else
        std.fmt.allocPrint(self.alloc, "", .{}) catch return;
    defer self.alloc.free(status);
    const w = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, status) catch return;
    defer self.alloc.free(w);
    if (self.status_hwnd) |sh| _ = SetWindowTextW(sh, w.ptr);
}

fn emitSearchChanged(self: *Self) void {
    if (self.hwnd == null or self.target_surface == null) return;
    var buf: [512]u16 = undefined;
    const len = if (self.hwnd) |h| GetDlgItemTextW(h, EDIT_ID, &buf, buf.len) else 0;
    const utf8 = std.unicode.utf16LeToUtf8AllocZ(self.alloc, buf[0..@intCast(len)]) catch return;
    defer self.alloc.free(utf8);
    self.performSearch(utf8);
}

fn performSearch(self: *Self, needle: [:0]const u8) void {
    const surface = self.target_surface orelse return;
    _ = surface.performBindingAction(.{ .search = needle }) catch {};
}

fn navigate(self: *Self, dir: @TypeOf(@as(@import("../../input/Binding.zig").Action, .{ .navigate_search = .next }).navigate_search)) void {
    const surface = self.target_surface orelse return;
    _ = surface.performBindingAction(.{ .navigate_search = dir }) catch {};
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const ptr = GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Self = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        WM_COMMAND => {
            const id: usize = wparam & 0xFFFF;
            const code: u16 = @truncate((wparam >> 16) & 0xFFFF);
            switch (id) {
                EDIT_ID => if (code == EN_CHANGE) self.emitSearchChanged(),
                PREV_ID => {
                    self.navigate(.previous);
                },
                NEXT_ID => {
                    self.navigate(.next);
                },
                CLOSE_ID => self.close(true),
                else => {},
            }
            return 0;
        },
        WM_KEYDOWN => if (wparam == VK_ESCAPE) {
            self.close(true);
            return 0;
        },
        WM_ACTIVATE => {
            if (!self.opening and @as(u16, @truncate(wparam & 0xFFFF)) == 0) self.close(true);
            return 0;
        },
        WM_CLOSE => {
            self.close(true);
            return 0;
        },
        else => {},
    }
    return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
}

var class_registered = false;
var ui_font: ?*anyopaque = null;

fn registerClass() !void {
    if (class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchPanel");
    const wc: sys.WNDCLASSEXW = .{
        .cbSize = @sizeOf(sys.WNDCLASSEXW),
        .style = sys.CS_HREDRAW | sys.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = sys.GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = sys.LoadCursorW(null, sys.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (sys.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}
