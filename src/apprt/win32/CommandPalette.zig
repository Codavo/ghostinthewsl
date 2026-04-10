//! Native Win32 command palette. A modal popup window with an edit control
//! for filtering and a list box showing matching commands.
const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const Command = input.command.Command;
const sys = @import("sys.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_cmd_palette);

const HWND = sys.HWND;
const LRESULT = sys.LRESULT;
const WPARAM = sys.WPARAM;
const LPARAM = sys.LPARAM;
const UINT = sys.UINT;
const DWORD = sys.DWORD;

// Win32 constants
const WS_POPUP: u32 = 0x80000000;
const WS_BORDER: u32 = 0x00800000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CHILD: u32 = 0x40000000;
const WS_VSCROLL: u32 = 0x00200000;
const WS_EX_TOPMOST: u32 = 0x00000008;
const WS_EX_TOOLWINDOW: u32 = 0x00000080;
const ES_AUTOHSCROLL: u32 = 0x0080;
const LBS_NOTIFY: u32 = 0x0001;
const LBS_HASSTRINGS: u32 = 0x0040;
const LBS_NOINTEGRALHEIGHT: u32 = 0x0100;

const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_DESTROY: UINT = 0x0002;
const WM_KEYDOWN: UINT = 0x0100;
const WM_CHAR: UINT = 0x0102;
const WM_ACTIVATE: UINT = 0x0006;
const WM_SETFONT: UINT = 0x0030;

const LB_RESETCONTENT: UINT = 0x0184;
const LB_ADDSTRING: UINT = 0x0180;
const LB_SETCURSEL: UINT = 0x0186;
const LB_GETCURSEL: UINT = 0x0188;
const LB_GETCOUNT: UINT = 0x018B;

const EN_CHANGE: u16 = 0x0300;
const LBN_DBLCLK: u16 = 2;

const VK_ESCAPE: WPARAM = 0x1B;
const VK_RETURN: WPARAM = 0x0D;
const VK_UP: WPARAM = 0x26;
const VK_DOWN: WPARAM = 0x28;

const EDIT_ID: usize = 100;
const LIST_ID: usize = 101;

// Additional externs
extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetParent(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *sys.RECT) callconv(.winapi) sys.BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) sys.BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) sys.BOOL;
extern "user32" fn GetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*]u16, cchMax: c_int) callconv(.winapi) UINT;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.winapi) isize;

/// Allocator
alloc: Allocator,

/// The app that owns this palette
app: *App,

/// The currently open popup window (null when closed)
hwnd: ?HWND = null,

/// Child controls
edit_hwnd: ?HWND = null,
list_hwnd: ?HWND = null,

/// The window that opened this palette (where the command will execute)
target_window: ?*Window = null,

/// Currently filtered command indices (into input.command.defaults)
filtered: std.ArrayListUnmanaged(usize) = .{},

/// True while open() is in progress; blocks WM_ACTIVATE-driven close.
opening: bool = false,

pub fn init(alloc: Allocator, app: *App) CommandPalette {
    return .{
        .alloc = alloc,
        .app = app,
        .hwnd = null,
        .edit_hwnd = null,
        .list_hwnd = null,
        .target_window = null,
        .filtered = .{},
        .opening = false,
    };
}

pub fn deinit(self: *CommandPalette) void {
    self.filtered.deinit(self.alloc);
    if (self.hwnd) |h| _ = DestroyWindow(h);
}

pub fn toggle(self: *CommandPalette, window: *Window) void {
    if (self.hwnd != null) {
        self.close();
    } else {
        self.open(window) catch |err| {
            log.err("failed to open command palette: {}", .{err});
        };
    }
}

fn open(self: *CommandPalette, window: *Window) !void {
    self.target_window = window;
    self.opening = true;
    defer self.opening = false;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyCommandPalette");
    try registerClass();

    // Position the popup centered on the parent window
    const parent = window.hwnd orelse return error.NoParent;
    var parent_rect: sys.RECT = std.mem.zeroes(sys.RECT);
    _ = GetWindowRect(parent, &parent_rect);
    const parent_w = parent_rect.right - parent_rect.left;
    const parent_h = parent_rect.bottom - parent_rect.top;
    const width: i32 = @min(600, parent_w - 40);
    const height: i32 = @min(400, parent_h - 60);
    const x = parent_rect.left + @divTrunc(parent_w - width, 2);
    const y = parent_rect.top + @divTrunc(parent_h - height, 4);

    const hinstance = sys.GetModuleHandleW(null);
    self.hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Command Palette"),
        WS_POPUP | WS_BORDER,
        x,
        y,
        width,
        height,
        parent,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    errdefer {
        if (self.hwnd) |h| {
            _ = DestroyWindow(h);
            self.hwnd = null;
            self.edit_hwnd = null;
            self.list_hwnd = null;
        }
    }

    // Store `self` on the window so the wndProc can access it
    _ = SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Create edit box (search input)
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    self.edit_hwnd = CreateWindowExW(
        0,
        edit_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL,
        10,
        10,
        width - 20,
        28,
        self.hwnd,
        @ptrFromInt(EDIT_ID),
        hinstance,
        null,
    ) orelse return error.Win32Error;

    // Create list box
    const listbox_class = std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX");
    self.list_hwnd = CreateWindowExW(
        0,
        listbox_class,
        null,
        WS_CHILD | WS_VISIBLE | WS_BORDER | WS_VSCROLL | LBS_NOTIFY | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT,
        10,
        46,
        width - 20,
        height - 56,
        self.hwnd,
        @ptrFromInt(LIST_ID),
        hinstance,
        null,
    ) orelse return error.Win32Error;

    // Create a nicer UI font (Segoe UI) and apply to child controls
    if (ui_font == null) {
        const face_name = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        ui_font = CreateFontW(
            -18, // height in pixels (negative = em height)
            0, 0, 0,
            400, // FW_NORMAL
            0, 0, 0,
            1, // DEFAULT_CHARSET
            0, 0, 0,
            0,
            face_name,
        );
    }
    if (ui_font) |font| {
        if (self.edit_hwnd) |eh| _ = SendMessageW(eh, WM_SETFONT, @intFromPtr(font), 1);
        if (self.list_hwnd) |lb| _ = SendMessageW(lb, WM_SETFONT, @intFromPtr(font), 1);
    }

    // Populate with all commands initially
    self.filter("") catch {};

    _ = ShowWindow(self.hwnd.?, 1); // SW_SHOWNORMAL
    if (self.edit_hwnd) |eh| _ = SetFocus(eh);
}

pub fn close(self: *CommandPalette) void {
    if (self.hwnd) |h| {
        _ = DestroyWindow(h);
        self.hwnd = null;
        self.edit_hwnd = null;
        self.list_hwnd = null;
        // Return focus to the target window's focused surface
        if (self.target_window) |w| {
            if (w.focused_surface) |s| _ = SetFocus(s.hwnd);
        }
    }
}

fn filter(self: *CommandPalette, query: []const u8) !void {
    self.filtered.clearRetainingCapacity();

    for (input.command.defaults, 0..) |cmd, i| {
        if (query.len == 0 or matchesQuery(cmd, query)) {
            try self.filtered.append(self.alloc, i);
        }
    }

    // Populate the listbox
    if (self.list_hwnd) |lb| {
        _ = SendMessageW(lb, LB_RESETCONTENT, 0, 0);
        for (self.filtered.items) |idx| {
            const cmd = input.command.defaults[idx];
            const wtext = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, cmd.title) catch continue;
            defer self.alloc.free(wtext);
            _ = SendMessageW(lb, LB_ADDSTRING, 0, @bitCast(@intFromPtr(wtext.ptr)));
        }
        if (self.filtered.items.len > 0) {
            _ = SendMessageW(lb, LB_SETCURSEL, 0, 0);
        }
    }
}

fn matchesQuery(cmd: Command, query: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(cmd.title, query) != null or
        std.ascii.indexOfIgnoreCase(@tagName(cmd.action), query) != null;
}

fn executeSelected(self: *CommandPalette) void {
    const lb = self.list_hwnd orelse return;
    const sel: isize = @bitCast(@as(usize, @intCast(SendMessageW(lb, LB_GETCURSEL, 0, 0))));
    if (sel < 0 or @as(usize, @intCast(sel)) >= self.filtered.items.len) return;
    const cmd_idx = self.filtered.items[@intCast(sel)];
    const cmd = input.command.defaults[cmd_idx];

    // Close the palette first so focus returns to the terminal
    const target = self.target_window;
    self.close();

    // Perform the action on the target surface
    _ = self.app;
    if (target) |w| {
        const surface = w.focused_surface orelse w.primary_surface;
        if (surface.core_surface) |core| {
            _ = core.performBindingAction(cmd.action) catch |err| {
                log.err("failed to execute command {s}: {}", .{ cmd.title, err });
            };
        }
    }
}

extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;

/// Called by App.run() before DispatchMessageW to pre-process messages
/// while the command palette is open. Returns true if the message was
/// consumed and should not be dispatched further.
pub fn preTranslateMessage(self: *CommandPalette, msg: UINT, hwnd: HWND, wparam: WPARAM) bool {
    if (self.hwnd == null) return false;
    // Only intercept keys targeted at our edit control
    if (self.edit_hwnd) |eh| {
        if (hwnd != eh) return false;
    } else return false;

    if (msg != WM_KEYDOWN) return false;

    switch (wparam) {
        VK_ESCAPE => {
            self.close();
            return true;
        },
        VK_RETURN => {
            self.executeSelected();
            return true;
        },
        VK_UP, VK_DOWN => {
            const lb = self.list_hwnd orelse return true;
            const count: isize = @bitCast(@as(usize, @intCast(SendMessageW(lb, LB_GETCOUNT, 0, 0))));
            if (count <= 0) return true;
            var sel: isize = @bitCast(@as(usize, @intCast(SendMessageW(lb, LB_GETCURSEL, 0, 0))));
            if (wparam == VK_UP and sel > 0) sel -= 1;
            if (wparam == VK_DOWN and sel < count - 1) sel += 1;
            _ = SendMessageW(lb, LB_SETCURSEL, @bitCast(sel), 0);
            return true;
        },
        else => return false,
    }
}

/// Re-run the filter from the current edit control text.
pub fn refilter(self: *CommandPalette) void {
    const eh = self.edit_hwnd orelse return;
    var buf: [256]u16 = undefined;
    const len_raw = GetWindowTextW(eh, &buf, buf.len);
    const len: usize = if (len_raw > 0) @intCast(len_raw) else 0;
    var u8_buf: [1024]u8 = undefined;
    const u8_len = std.unicode.utf16LeToUtf8(&u8_buf, buf[0..len]) catch 0;
    self.filter(u8_buf[0..u8_len]) catch {};
}
extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetTextColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;
extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: [*:0]const u16,
) callconv(.winapi) ?*anyopaque;

// Dark theme colors (COLORREF: 0x00BBGGRR)
const BG_COLOR: u32 = 0x001E1E1E;
const FG_COLOR: u32 = 0x00E0E0E0;
var dark_brush: ?*anyopaque = null;
var ui_font: ?*anyopaque = null;

var class_registered: bool = false;

fn registerClass() !void {
    if (class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyCommandPalette");
    const hinstance = sys.GetModuleHandleW(null);
    if (dark_brush == null) dark_brush = CreateSolidBrush(BG_COLOR);
    var wc: sys.WNDCLASSEXW = std.mem.zeroes(sys.WNDCLASSEXW);
    wc.cbSize = @sizeOf(sys.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.hCursor = sys.LoadCursorW(null, sys.IDC_ARROW);
    wc.hbrBackground = dark_brush;
    wc.lpszClassName = class_name;
    if (sys.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn getPalette(hwnd: HWND) ?*CommandPalette {
    const ptr = GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

const WM_CTLCOLOREDIT: UINT = 0x0133;
const WM_CTLCOLORLISTBOX: UINT = 0x0134;
const WM_CTLCOLORSTATIC: UINT = 0x0138;

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX, WM_CTLCOLORSTATIC => {
            // wparam is the HDC; just reinterpret it as an opaque pointer.
            const hdc: ?*anyopaque = @ptrFromInt(wparam);
            _ = SetTextColor(hdc, FG_COLOR);
            _ = SetBkColor(hdc, BG_COLOR);
            const brush = dark_brush orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            // @bitCast preserves the bit pattern (pointer may have high bit set)
            return @bitCast(@intFromPtr(brush));
        },
        WM_COMMAND => {
            const self = getPalette(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            const ctl_id: u16 = @truncate(wparam & 0xFFFF);
            const notify: u16 = @truncate((wparam >> 16) & 0xFFFF);
            if (ctl_id == EDIT_ID and notify == EN_CHANGE) {
                // Get current text and filter
                var buf: [256]u16 = undefined;
                const len = GetDlgItemTextW(hwnd, EDIT_ID, &buf, buf.len);
                var u8_buf: [1024]u8 = undefined;
                const u8_len = std.unicode.utf16LeToUtf8(&u8_buf, buf[0..len]) catch 0;
                self.filter(u8_buf[0..u8_len]) catch {};
            } else if (ctl_id == LIST_ID and notify == LBN_DBLCLK) {
                self.executeSelected();
            }
            return 0;
        },
        WM_CLOSE => {
            if (getPalette(hwnd)) |self| self.close();
            return 0;
        },
        WM_ACTIVATE => {
            // When we lose activation, schedule a close via PostMessage to
            // avoid re-entrancy. `opening` guards against closing during open().
            if ((wparam & 0xFFFF) == 0) { // WA_INACTIVE
                if (getPalette(hwnd)) |self| {
                    if (!self.opening) {
                        _ = sys.PostMessageW(hwnd, WM_CLOSE, 0, 0);
                    }
                }
            }
            return 0;
        },
        else => return sys.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Called from App.surfaceDispatch or similar to intercept keys while
/// the palette is open. Returns true if the key was consumed.
pub fn handleKey(self: *CommandPalette, vk: WPARAM) bool {
    if (self.hwnd == null) return false;
    const lb = self.list_hwnd orelse return false;
    switch (vk) {
        VK_ESCAPE => {
            self.close();
            return true;
        },
        VK_RETURN => {
            self.executeSelected();
            return true;
        },
        VK_UP => {
            const count = SendMessageW(lb, LB_GETCOUNT, 0, 0);
            if (count <= 0) return true;
            var sel = SendMessageW(lb, LB_GETCURSEL, 0, 0);
            if (sel > 0) sel -= 1;
            _ = SendMessageW(lb, LB_SETCURSEL, @bitCast(sel), 0);
            return true;
        },
        VK_DOWN => {
            const count = SendMessageW(lb, LB_GETCOUNT, 0, 0);
            if (count <= 0) return true;
            var sel = SendMessageW(lb, LB_GETCURSEL, 0, 0);
            if (sel < count - 1) sel += 1;
            _ = SendMessageW(lb, LB_SETCURSEL, @bitCast(sel), 0);
            return true;
        },
        else => return false,
    }
}
