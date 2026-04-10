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

pub fn init(alloc: Allocator, app: *App) CommandPalette {
    return .{ .alloc = alloc, .app = app };
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
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
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
    );

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
    );

    // Populate with all commands initially
    self.filter("") catch {};

    _ = ShowWindow(self.hwnd.?, 1); // SW_SHOWNORMAL
    _ = SetFocus(self.edit_hwnd.?);
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

var class_registered: bool = false;

fn registerClass() !void {
    if (class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyCommandPalette");
    const hinstance = sys.GetModuleHandleW(null);
    var wc: sys.WNDCLASSEXW = std.mem.zeroes(sys.WNDCLASSEXW);
    wc.cbSize = @sizeOf(sys.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.hCursor = sys.LoadCursorW(null, sys.IDC_ARROW);
    wc.hbrBackground = @ptrFromInt(6); // COLOR_WINDOW + 1
    wc.lpszClassName = class_name;
    if (sys.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn getPalette(hwnd: HWND) ?*CommandPalette {
    const ptr = GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
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
            // Close when losing focus (popup dismissal)
            if ((wparam & 0xFFFF) == 0) { // WA_INACTIVE
                if (getPalette(hwnd)) |self| self.close();
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
