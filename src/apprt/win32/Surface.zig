/// Win32 surface - represents a terminal surface within a window.
/// Manages the WGL OpenGL context and provides the interface
/// expected by CoreSurface.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const CoreApp = @import("../../App.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.win32_surface);

// Win32 types
const HWND = std.os.windows.HWND;
const HINSTANCE = std.os.windows.HINSTANCE;
const BOOL = i32;
const HDC = ?*anyopaque;
const HGLRC = ?*anyopaque;
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: u32,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8,
    cRedShift: u8,
    cGreenBits: u8,
    cGreenShift: u8,
    cBlueBits: u8,
    cBlueShift: u8,
    cAlphaBits: u8,
    cAlphaShift: u8,
    cAccumBits: u8,
    cAccumRedBits: u8,
    cAccumGreenBits: u8,
    cAccumBlueBits: u8,
    cAccumAlphaBits: u8,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8,
    iLayerType: u8,
    bReserved: u8,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

// WGL / GDI constants
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_TYPE_RGBA = 0;
const PFD_MAIN_PLANE = 0;

// WGL / GDI extern declarations
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;
extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const std.os.windows.RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, x: i32, y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.winapi) BOOL;
extern "user32" fn FillRect(hDC: ?*anyopaque, lprc: *const RECT, hbr: ?*anyopaque) callconv(.winapi) c_int;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// Scrollbar / layered window API
extern "user32" fn SetLayeredWindowAttributes(hWnd: HWND, crKey: u32, bAlpha: u8, dwFlags: u32) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn GetParent(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;

// Clipboard API
const UINT = u32;
const HANDLE = ?*anyopaque;
extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) HANDLE;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;

/// The window this surface belongs to.
hwnd: HWND,

/// Pointer back to the App.
app: ?*App = null,

/// Pointer back to the Window that contains this Surface.
window: ?*Window = null,

/// GDI device context.
hdc: HDC = null,

/// OpenGL rendering context.
hglrc: HGLRC = null,

/// The core surface, if initialized.
core_surface: ?*CoreSurface = null,

/// Window dimensions.
width: u32 = 800,
height: u32 = 600,

/// Last known cursor position in client pixels.
cursor_pos: apprt.CursorPos = .{ .x = 0, .y = 0 },

/// UTF-8 window title cache for title reporting.
title_buf: [1024:0]u8 = [_:0]u8{0} ** 1024,
progress_hwnd: ?HWND = null,
progress_visible: bool = false,
progress_state: terminal.osc.Command.ProgressReport.State = .remove,
progress_value: ?u8 = null,
progress_phase: u8 = 0,
layout_x: i32 = 0,
layout_y: i32 = 0,
layout_w: i32 = 0,

// Scrollbar overlay state
scrollbar_hwnd: ?HWND = null,
scrollbar_state: terminal.Scrollbar = .zero,
scrollbar_visible: bool = false,
scrollbar_dragging: bool = false,
scrollbar_drag_anchor: i32 = 0,
scrollbar_fade_phase: u8 = 255,
scrollbar_activity: bool = false,

const App = @import("App.zig");
const Window = @import("Window.zig");
const ProgressState = terminal.osc.Command.ProgressReport.State;
const progress_overlay_height: i32 = 12;
const progress_timeout_ms: UINT = 15_000;
const progress_pulse_ms: UINT = 120;
const progress_timeout_timer_id: usize = 1;
const progress_pulse_timer_id: usize = 2;
const scrollbar_width: i32 = 8;
const scrollbar_min_thumb: i32 = 20;
const scrollbar_fade_delay_ms: UINT = 1500;
const scrollbar_fade_step_ms: UINT = 30;
pub const scrollbar_hover_zone: i32 = 24;
const scrollbar_activity_timer_id: usize = 3;
const scrollbar_fade_timer_id: usize = 4;
const SW_HIDE: c_int = 0;
const SW_SHOWNORMAL: c_int = 1;
const WM_PAINT: UINT = 0x000F;
const WM_TIMER: UINT = 0x0113;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_MOUSEWHEEL: UINT = 0x020A;
const LWA_ALPHA: u32 = 0x00000002;
const WS_EX_LAYERED: u32 = 0x00080000;
var progress_class_registered: bool = false;
var scrollbar_class_registered: bool = false;

pub fn core(self: *Self) *CoreSurface {
    return self.core_surface.?;
}

pub fn rtApp(self: *Self) *App {
    return self.app.?;
}

pub fn init(self: *Self, parent: HWND, app: *App) !void {
    self.* = .{ .hwnd = undefined, .app = app };

    // Create a child window for this surface.
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

    // Ensure the surface window class is registered (idempotent).
    try registerSurfaceClass();

    var rect: RECT = undefined;
    _ = GetClientRect(parent, &rect);
    const cw: i32 = rect.right - rect.left;
    const ch: i32 = rect.bottom - rect.top;

    const hinstance = GetModuleHandleW(null);
    const WS_CHILD: u32 = 0x40000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_CLIPCHILDREN: u32 = 0x02000000;
    const child = CreateWindowExW(
        0,
        class_name,
        null,
        WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
        0,
        0,
        cw,
        ch,
        parent,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = child;
    self.width = @intCast(@max(1, cw));
    self.height = @intCast(@max(1, ch));

    // Store self pointer on the child window for message handling
    _ = SetWindowLongPtrW(child, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    try self.createProgressOverlay();
    self.createScrollbarOverlay();

    try self.initOpenGL();
}

var surface_class_registered: bool = false;

fn registerSurfaceClass() !void {
    if (surface_class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");
    const hinstance = GetModuleHandleW(null);
    const CS_HREDRAW: u32 = 0x0002;
    const CS_VREDRAW: u32 = 0x0001;
    const CS_OWNDC: u32 = 0x0020;
    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    wc.lpfnWndProc = surfaceWndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(null, @ptrFromInt(32512));
    wc.lpszClassName = class_name;
    if (RegisterClassExW(&wc) == 0) return error.Win32Error;
    surface_class_registered = true;
}

fn surfaceWndProc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Self = @ptrFromInt(@as(usize, @bitCast(ptr)));
    const app = self.app orelse return DefWindowProcW(hwnd, msg, wparam, lparam);
    return App.surfaceDispatch(app, self, hwnd, msg, wparam, lparam);
}

fn progressWndProc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Self = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        WM_PAINT => {
            self.paintProgress(hwnd);
            return 0;
        },
        WM_TIMER => {
            switch (wparam) {
                progress_timeout_timer_id => {
                    self.hideProgressOverlay();
                    return 0;
                },
                progress_pulse_timer_id => {
                    self.progress_phase +%= 1;
                    _ = InvalidateRect(hwnd, null, 0);
                    return 0;
                },
                else => {},
            }
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn scrollbarWndProc(hwnd: HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Self = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        WM_PAINT => {
            self.paintScrollbar(hwnd);
            return 0;
        },
        WM_TIMER => {
            switch (wparam) {
                scrollbar_activity_timer_id => {
                    // Activity timeout expired — start fade-out
                    _ = KillTimer(hwnd, scrollbar_activity_timer_id);
                    _ = SetTimer(hwnd, scrollbar_fade_timer_id, scrollbar_fade_step_ms, null);
                    self.scrollbar_activity = false;
                    return 0;
                },
                scrollbar_fade_timer_id => {
                    // No alpha fading (WS_EX_LAYERED conflicts with OpenGL).
                    // Just hide immediately after the activity timeout.
                    _ = KillTimer(hwnd, scrollbar_fade_timer_id);
                    _ = ShowWindow(hwnd, SW_HIDE);
                    self.scrollbar_visible = false;
                    return 0;
                },
                else => {},
            }
        },
        WM_LBUTTONDOWN => {
            const mouse_y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            const thumb = self.scrollbarThumbRect();
            if (mouse_y >= thumb.top and mouse_y < thumb.bottom) {
                // Thumb hit — start drag
                self.scrollbar_dragging = true;
                self.scrollbar_drag_anchor = mouse_y - thumb.top;
                _ = SetCapture(hwnd);
            } else {
                // Track hit — jump scroll
                const row = self.scrollbarRowFromY(mouse_y);
                self.scrollToRow(row);
            }
            return 0;
        },
        WM_MOUSEMOVE => {
            if (self.scrollbar_dragging) {
                const mouse_y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
                const row = self.scrollbarRowFromDragY(mouse_y - self.scrollbar_drag_anchor);
                self.scrollToRow(row);
            }
            // Reset fade on any mouse activity over scrollbar
            self.showScrollbar();
            return 0;
        },
        WM_LBUTTONUP => {
            if (self.scrollbar_dragging) {
                self.scrollbar_dragging = false;
                _ = ReleaseCapture();
            }
            return 0;
        },
        WM_MOUSEWHEEL => {
            // Forward mouse wheel to parent surface
            const parent = GetParent(hwnd);
            if (parent) |p| {
                return SendMessageW(p, WM_MOUSEWHEEL, wparam, lparam);
            }
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn deinit(self: *Self) void {
    self.hideProgressOverlay();
    if (self.scrollbar_hwnd) |hwnd| {
        _ = DestroyWindow(hwnd);
        self.scrollbar_hwnd = null;
    }
    if (self.progress_hwnd) |hwnd| {
        _ = DestroyWindow(hwnd);
        self.progress_hwnd = null;
    }
    if (self.core_surface) |surface| {
        surface.deinit();
        // core_surface is allocated by CoreApp, freed there
    }
    if (self.hglrc != null) {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.hglrc);
    }
    if (self.hdc != null) {
        _ = ReleaseDC(self.hwnd, self.hdc);
    }
}

fn initOpenGL(self: *Self) !void {
    self.hdc = GetDC(self.hwnd);
    if (self.hdc == null) {
        log.err("GetDC failed", .{});
        return error.Win32Error;
    }

    var pfd: PIXELFORMATDESCRIPTOR = std.mem.zeroes(PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType = PFD_MAIN_PLANE;

    const pixel_format = ChoosePixelFormat(self.hdc, &pfd);
    if (pixel_format == 0) {
        log.err("ChoosePixelFormat failed", .{});
        return error.Win32Error;
    }

    if (SetPixelFormat(self.hdc, pixel_format, &pfd) == 0) {
        log.err("SetPixelFormat failed", .{});
        return error.Win32Error;
    }

    self.hglrc = wglCreateContext(self.hdc);
    if (self.hglrc == null) {
        log.err("wglCreateContext failed", .{});
        return error.Win32Error;
    }

    if (wglMakeCurrent(self.hdc, self.hglrc) == 0) {
        log.err("wglMakeCurrent failed", .{});
        return error.Win32Error;
    }

    // Set initial viewport to client area
    var client_rect: RECT = std.mem.zeroes(RECT);
    if (GetClientRect(self.hwnd, &client_rect) != 0) {
        self.width = @intCast(client_rect.right - client_rect.left);
        self.height = @intCast(client_rect.bottom - client_rect.top);
    }
    glViewport(0, 0, @intCast(self.width), @intCast(self.height));

    log.info("WGL OpenGL context created, client area {}x{}", .{ self.width, self.height });
}

extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: u32, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn DefWindowProcW(hWnd: HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
const GWLP_USERDATA: i32 = -21;

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16,
    hIconSm: ?*anyopaque,
};

pub fn swapBuffers(self: *Self) void {
    if (self.hdc != null) {
        _ = SwapBuffers(self.hdc);
    }
}

fn createProgressOverlay(self: *Self) !void {
    try registerProgressClass();
    const hwnd = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyProgressOverlay"),
        null,
        0x40000000,
        0,
        0,
        0,
        progress_overlay_height,
        self.hwnd,
        null,
        GetModuleHandleW(null),
        null,
    ) orelse return error.Win32Error;
    self.progress_hwnd = hwnd;
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

fn registerProgressClass() !void {
    if (progress_class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyProgressOverlay");
    const hinstance = GetModuleHandleW(null);
    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = 0x0002 | 0x0001;
    wc.lpfnWndProc = progressWndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(null, @ptrFromInt(32512));
    wc.lpszClassName = class_name;
    if (RegisterClassExW(&wc) == 0) return error.Win32Error;
    progress_class_registered = true;
}

fn createScrollbarOverlay(self: *Self) void {
    registerScrollbarClass() catch |err| {
        const wsl_log = @import("wsl_log.zig");
        const sys = @import("sys.zig");
        wsl_log.print("scrollbar: registerClass failed: {s} (win32={d})", .{ @errorName(err), sys.GetLastError() });
        return;
    };
    const WS_CHILD: u32 = 0x40000000;
    // Don't use WS_EX_LAYERED — it conflicts with the parent's OpenGL surface
    // on some systems/drivers (CreateWindowExW returns NULL with error 0).
    // Use simple show/hide instead of alpha fading.
    const hwnd = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyScrollbarOverlay"),
        null,
        WS_CHILD,
        0,
        0,
        scrollbar_width,
        @intCast(self.height),
        self.hwnd,
        null,
        GetModuleHandleW(null),
        null,
    ) orelse {
        const wsl_log = @import("wsl_log.zig");
        const sys = @import("sys.zig");
        wsl_log.print("scrollbar: CreateWindowExW failed (win32={d})", .{sys.GetLastError()});
        return;
    };
    self.scrollbar_hwnd = hwnd;
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

fn registerScrollbarClass() !void {
    if (scrollbar_class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyScrollbarOverlay");
    const hinstance = GetModuleHandleW(null);
    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = 0x0002 | 0x0001;
    wc.lpfnWndProc = scrollbarWndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(null, @ptrFromInt(32512));
    wc.lpszClassName = class_name;
    if (RegisterClassExW(&wc) == 0) return error.Win32Error;
    scrollbar_class_registered = true;
}

/// Disable VSync via WGL extension for lower input latency.
pub fn disableVSync(_: *Self) void {
    const func: ?*const fn (i32) callconv(.winapi) i32 = @ptrCast(wglGetProcAddress("wglSwapIntervalEXT"));
    if (func) |setInterval| {
        _ = setInterval(0);
    }
}

/// Set the mouse cursor shape. Called from performAction.
pub fn setMouseShape(self: *Self, shape: @import("../../terminal/main.zig").MouseShape) void {
    _ = self;
    const cursor_name: ?[*:0]align(1) const u16 = switch (shape) {
        .text, .vertical_text, .cell => @ptrFromInt(32513), // IDC_IBEAM
        .pointer => @ptrFromInt(32649), // IDC_HAND
        .wait, .progress => @ptrFromInt(32514), // IDC_WAIT
        .crosshair => @ptrFromInt(32515), // IDC_CROSS
        .not_allowed, .no_drop => @ptrFromInt(32648), // IDC_NO
        .move, .all_scroll => @ptrFromInt(32646), // IDC_SIZEALL
        .ns_resize, .n_resize, .s_resize, .row_resize => @ptrFromInt(32645), // IDC_SIZENS
        .ew_resize, .e_resize, .w_resize, .col_resize => @ptrFromInt(32644), // IDC_SIZEWE
        .nesw_resize, .ne_resize, .sw_resize => @ptrFromInt(32643), // IDC_SIZENESW
        .nwse_resize, .nw_resize, .se_resize => @ptrFromInt(32642), // IDC_SIZENWSE
        .help => @ptrFromInt(32651), // IDC_HELP
        else => @ptrFromInt(32512), // IDC_ARROW
    };
    const cursor = LoadCursorW(null, cursor_name);
    _ = SetCursor(cursor);
}

pub fn setMouseVisibility(self: *Self, visible: bool) void {
    _ = self;
    _ = ShowCursor(if (visible) 1 else 0);
}

extern "user32" fn LoadCursorW(hInstance: ?*anyopaque, lpCursorName: ?[*:0]align(1) const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetCursor(hCursor: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn ShowCursor(bShow: i32) callconv(.winapi) i32;

/// Update the OpenGL viewport to match the current window size.
/// Called from the renderer thread before each frame.
pub fn updateViewport(self: *Self) void {
    glViewport(0, 0, @intCast(self.width), @intCast(self.height));
}

extern "opengl32" fn glViewport(x: i32, y: i32, width: i32, height: i32) callconv(.winapi) void;

/// Make the WGL context current on the calling thread.
pub fn makeContextCurrent(self: *Self) void {
    if (self.hdc != null and self.hglrc != null) {
        _ = wglMakeCurrent(self.hdc, self.hglrc);
    }
}

/// Release the WGL context from the calling thread.
pub fn releaseContext() void {
    _ = wglMakeCurrent(null, null);
}

/// Release context from the main thread before handing off to renderer thread.
pub fn releaseMainThreadContext(self: *Self) void {
    _ = self;
    _ = wglMakeCurrent(null, null);
}

pub fn setLayoutRect(self: *Self, x: i32, y: i32, w: i32, h: i32) void {
    _ = x;
    _ = y;
    _ = h;
    self.layout_w = w;
    self.updateProgressOverlayRect();
    self.updateScrollbarRect();
}

pub fn setVisible(self: *Self, visible: bool) void {
    _ = ShowWindow(self.hwnd, if (visible) SW_SHOWNORMAL else SW_HIDE);
    if (self.progress_hwnd) |hwnd| {
        _ = ShowWindow(hwnd, if (visible and self.progress_visible) SW_SHOWNORMAL else SW_HIDE);
    }
    if (self.scrollbar_hwnd) |hwnd| {
        _ = ShowWindow(hwnd, if (visible and self.scrollbar_visible) SW_SHOWNORMAL else SW_HIDE);
    }
}

pub fn setProgressReport(self: *Self, value: terminal.osc.Command.ProgressReport) void {
    const app = self.app orelse return;
    if (!app.config.@"progress-style") {
        self.hideProgressOverlay();
        return;
    }

    self.stopProgressTimers();
    switch (value.state) {
        .remove => {
            self.hideProgressOverlay();
            return;
        },
        .set, .@"error", .pause, .indeterminate => {
            self.progress_state = value.state;
            self.progress_value = value.progress;
            self.progress_phase = 0;
            self.progress_visible = true;
            if (value.state == .indeterminate or ((value.state == .set or value.state == .@"error") and value.progress == null)) {
                _ = SetTimer(self.progress_hwnd, progress_pulse_timer_id, progress_pulse_ms, null);
            }
            _ = SetTimer(self.progress_hwnd, progress_timeout_timer_id, progress_timeout_ms, null);
            self.updateProgressOverlayRect();
            if (self.progress_hwnd) |hwnd| {
                _ = ShowWindow(hwnd, SW_SHOWNORMAL);
                _ = InvalidateRect(hwnd, null, 0);
            }
        },
    }
}

fn hideProgressOverlay(self: *Self) void {
    self.stopProgressTimers();
    self.progress_visible = false;
    self.progress_state = .remove;
    self.progress_value = null;
    if (self.progress_hwnd) |hwnd| _ = ShowWindow(hwnd, SW_HIDE);
}

fn stopProgressTimers(self: *Self) void {
    if (self.progress_hwnd) |hwnd| {
        _ = KillTimer(hwnd, progress_timeout_timer_id);
        _ = KillTimer(hwnd, progress_pulse_timer_id);
    }
}

fn updateProgressOverlayRect(self: *Self) void {
    const hwnd = self.progress_hwnd orelse return;
    if (!self.progress_visible or self.layout_w <= 0) {
        _ = ShowWindow(hwnd, SW_HIDE);
        return;
    }
    _ = SetWindowPos(hwnd, null, 0, 0, self.layout_w, progress_overlay_height, 0x0004);
}

fn paintProgress(self: *Self, hwnd: HWND) void {
    var ps: PAINTSTRUCT = std.mem.zeroes(PAINTSTRUCT);
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);

    var rect: RECT = std.mem.zeroes(RECT);
    _ = GetClientRect(hwnd, &rect);

    const trough = CreateSolidBrush(0x00C8C8C8);
    if (trough != null) {
        _ = FillRect(hdc, &rect, trough);
        _ = DeleteObject(trough);
    }

    var fill = rect;
    switch (self.progress_state) {
        .indeterminate => {
            const span = @max(24, @divTrunc(rect.right - rect.left, 4));
            const travel = @max(1, (rect.right - rect.left) + span);
            const start = @mod(@as(i32, self.progress_phase) * 6, travel) - span;
            fill.left = std.math.clamp(start, rect.left, rect.right);
            fill.right = std.math.clamp(start + span, rect.left, rect.right);
        },
        .set, .@"error", .pause => {
            const progress: u8 = self.progress_value orelse if (self.progress_state == .pause) @as(u8, 100) else @as(u8, 0);
            fill.right = rect.left + @divTrunc((rect.right - rect.left) * progress, 100);
        },
        .remove => return,
    }
    if (fill.right <= fill.left) return;

    const brush = CreateSolidBrush(switch (self.progress_state) {
        .@"error" => 0x002020E0,
        else => 0x0000A0FF,
    });
    if (brush != null) {
        _ = FillRect(hdc, &fill, brush);
        _ = DeleteObject(brush);
    }
}

// --- Scrollbar overlay logic ---

pub fn updateScrollbar(self: *Self, value: terminal.Scrollbar) void {
    self.scrollbar_state = value;
    if (value.total > value.len) {
        self.showScrollbar();
        if (self.scrollbar_hwnd) |hwnd| _ = InvalidateRect(hwnd, null, 0);
    } else {
        self.hideScrollbar();
    }
}

pub fn showScrollbar(self: *Self) void {
    if (self.scrollbar_state.total <= self.scrollbar_state.len) return;
    const hwnd = self.scrollbar_hwnd orelse return;
    self.scrollbar_visible = true;
    _ = ShowWindow(hwnd, SW_SHOWNORMAL);
    // Kill any running fade timer, start/restart activity timer
    _ = KillTimer(hwnd, scrollbar_fade_timer_id);
    _ = KillTimer(hwnd, scrollbar_activity_timer_id);
    _ = SetTimer(hwnd, scrollbar_activity_timer_id, scrollbar_fade_delay_ms, null);
    self.scrollbar_activity = true;
}

fn hideScrollbar(self: *Self) void {
    const hwnd = self.scrollbar_hwnd orelse return;
    _ = KillTimer(hwnd, scrollbar_activity_timer_id);
    _ = KillTimer(hwnd, scrollbar_fade_timer_id);
    self.scrollbar_visible = false;
    self.scrollbar_dragging = false;
    _ = ShowWindow(hwnd, SW_HIDE);
}

fn updateScrollbarRect(self: *Self) void {
    const hwnd = self.scrollbar_hwnd orelse return;
    if (self.layout_w <= 0) return;
    const h: i32 = @intCast(self.height);
    const x = self.layout_w - scrollbar_width;
    const HWND_TOP: ?HWND = null;
    const SWP_NOACTIVATE: UINT = 0x0010;
    _ = SetWindowPos(hwnd, HWND_TOP, x, 0, scrollbar_width, h, SWP_NOACTIVATE);
}

const ThumbRect = struct { top: i32, bottom: i32 };

fn scrollbarThumbRect(self: *Self) ThumbRect {
    const state = self.scrollbar_state;
    if (state.total == 0 or state.len >= state.total) return .{ .top = 0, .bottom = 0 };
    const track_height: i32 = @intCast(self.height);
    const thumb_height = @max(scrollbar_min_thumb, @divTrunc(@as(i32, @intCast(state.len)) * track_height, @as(i32, @intCast(state.total))));
    const max_offset: i32 = @intCast(state.total - state.len);
    const thumb_top = if (max_offset > 0)
        @divTrunc(@as(i32, @intCast(state.offset)) * (track_height - thumb_height), max_offset)
    else
        0;
    return .{ .top = thumb_top, .bottom = thumb_top + thumb_height };
}

fn scrollbarRowFromY(self: *Self, y: i32) usize {
    const state = self.scrollbar_state;
    if (state.total <= state.len) return 0;
    const track_height: i32 = @intCast(self.height);
    const thumb_height = @max(scrollbar_min_thumb, @divTrunc(@as(i32, @intCast(state.len)) * track_height, @as(i32, @intCast(state.total))));
    const usable = track_height - thumb_height;
    if (usable <= 0) return 0;
    const max_offset = state.total - state.len;
    const clamped_y = std.math.clamp(y, 0, usable);
    return @as(usize, @intCast(clamped_y)) * max_offset / @as(usize, @intCast(usable));
}

fn scrollbarRowFromDragY(self: *Self, thumb_top_y: i32) usize {
    const state = self.scrollbar_state;
    if (state.total <= state.len) return 0;
    const track_height: i32 = @intCast(self.height);
    const thumb_height = @max(scrollbar_min_thumb, @divTrunc(@as(i32, @intCast(state.len)) * track_height, @as(i32, @intCast(state.total))));
    const usable = track_height - thumb_height;
    if (usable <= 0) return 0;
    const max_offset = state.total - state.len;
    const clamped = std.math.clamp(thumb_top_y, 0, usable);
    return @as(usize, @intCast(clamped)) * max_offset / @as(usize, @intCast(usable));
}

fn scrollToRow(self: *Self, row: usize) void {
    const cs = self.core_surface orelse return;
    cs.renderer_state.mutex.lock();
    defer cs.renderer_state.mutex.unlock();
    const t: *terminal.Terminal = cs.renderer_state.terminal;
    t.screens.active.scroll(.{ .row = row });
    cs.renderer_thread.wakeup.notify() catch {};
}

fn paintScrollbar(self: *Self, hwnd: HWND) void {
    var ps: PAINTSTRUCT = std.mem.zeroes(PAINTSTRUCT);
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);

    var rect: RECT = std.mem.zeroes(RECT);
    _ = GetClientRect(hwnd, &rect);

    // Track background (dark, semi-transparent via layered window alpha)
    const track_brush = CreateSolidBrush(0x00303030);
    if (track_brush != null) {
        _ = FillRect(hdc, &rect, track_brush);
        _ = DeleteObject(track_brush);
    }

    // Thumb
    const thumb = self.scrollbarThumbRect();
    if (thumb.bottom > thumb.top) {
        var thumb_rect: RECT = .{
            .left = rect.left,
            .top = thumb.top,
            .right = rect.right,
            .bottom = thumb.bottom,
        };
        const color: u32 = if (self.scrollbar_dragging) 0x00B0B0B0 else 0x00808080;
        const thumb_brush = CreateSolidBrush(color);
        if (thumb_brush != null) {
            _ = FillRect(hdc, &thumb_rect, thumb_brush);
            _ = DeleteObject(thumb_brush);
        }
    }
}

// --- Interface methods required by CoreSurface ---

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    const dpi = GetDpiForWindow(self.hwnd);
    if (dpi == 0) return .{ .x = 1.0, .y = 1.0 };
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    return .{ .x = scale, .y = scale };
}

extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.winapi) u32;

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return .{
        .width = self.width,
        .height = self.height,
    };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    const window = self.window orelse return null;
    const hwnd = window.hwnd orelse return null;

    var title_utf16: [512]u16 = undefined;
    const len = GetWindowTextW(hwnd, &title_utf16, title_utf16.len);
    if (len <= 0) return null;

    const title_slice: []const u16 = title_utf16[0..@intCast(len)];
    const out_len = std.unicode.utf16LeToUtf8(self.title_buf[0 .. self.title_buf.len - 1], title_slice) catch
        return null;
    self.title_buf[out_len] = 0;
    return self.title_buf[0..out_len :0];
}

pub fn close(self: *Self, process_active: bool) void {
    _ = process_active; // Core already gated on needsConfirmQuit
    const wsl_log = @import("wsl_log.zig");
    wsl_log.print("Surface.close called (has window={s})", .{if (self.window != null) "yes" else "no"});
    // Ask the window to remove this surface from the tree, destroying the
    // child window. If this is the last surface in the last window, the
    // app will quit.
    if (self.window) |window| {
        window.closeSurface(self);
    } else {
        wsl_log.print("Surface.close: no window, posting WM_QUIT directly", .{});
        PostQuitMessage(0);
    }
}

extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: u32) callconv(.winapi) c_int;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;

pub fn supportsClipboard(_: *Self, _: apprt.Clipboard) bool {
    // Windows has only one clipboard; alias selection/primary to standard.
    return true;
}

pub fn clipboardRequest(
    self: *Self,
    _: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !bool {
    const surface = self.core_surface orelse return false;

    // Try to read text from the Win32 clipboard synchronously
    if (OpenClipboard(self.hwnd) == 0) return false;
    defer _ = CloseClipboard();

    const CF_UNICODETEXT: UINT = 13;
    const handle = GetClipboardData(CF_UNICODETEXT);
    if (handle == null) return false;

    const ptr: ?[*:0]const u16 = @ptrCast(@alignCast(GlobalLock(handle)));
    if (ptr == null) return false;
    defer _ = GlobalUnlock(handle);

    // Convert UTF-16 to UTF-8
    const alloc = if (self.app) |app| app.alloc else std.heap.page_allocator;
    const utf8 = std.unicode.utf16LeToUtf8AllocZ(alloc, std.mem.span(ptr.?)) catch return false;
    defer alloc.free(utf8);

    try surface.completeClipboardRequest(req, utf8, true);
    return true;
}

pub fn setClipboard(
    self: *Self,
    _: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    _: bool,
) !void {
    if (contents.len == 0) return;

    const text = contents[0].data;
    const alloc = if (self.app) |app| app.alloc else std.heap.page_allocator;

    // Convert UTF-8 to UTF-16
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(utf16);

    const byte_len = (utf16.len + 1) * 2; // include null terminator
    const GMEM_MOVEABLE: UINT = 0x0002;
    const hmem = GlobalAlloc(GMEM_MOVEABLE, byte_len);
    if (hmem == null) return;

    const dst: ?[*]u16 = @ptrCast(@alignCast(GlobalLock(hmem)));
    if (dst == null) {
        _ = GlobalFree(hmem);
        return;
    }
    @memcpy(dst.?[0..utf16.len], utf16);
    dst.?[utf16.len] = 0;
    _ = GlobalUnlock(hmem);

    if (OpenClipboard(self.hwnd) == 0) {
        _ = GlobalFree(hmem);
        return;
    }
    _ = EmptyClipboard();
    const CF_UNICODETEXT: UINT = 13;
    _ = SetClipboardData(CF_UNICODETEXT, hmem);
    _ = CloseClipboard();
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    const alloc = if (self.app) |app| app.alloc else std.heap.page_allocator;
    return try @import("../../os/main.zig").getEnvMap(alloc);
}

pub fn redrawInspector(self: *Self) void {
    _ = InvalidateRect(self.hwnd, null, 0);
}
