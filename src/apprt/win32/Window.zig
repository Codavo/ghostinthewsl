//! A single top-level Win32 window. Each Window owns one HWND and a set of
//! tabs. Every tab owns its own split tree and active surface state.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("SplitTree.zig");
const sys = @import("sys.zig");

const App = @import("App.zig");

const HWND = sys.HWND;
const RECT = sys.RECT;
const BOOL = sys.BOOL;
const UINT = sys.UINT;
const DWORD = sys.DWORD;
const LPARAM = sys.LPARAM;
const WPARAM = sys.WPARAM;
const LRESULT = sys.LRESULT;

const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_TABSTOP: u32 = 0x00010000;
const TCS_FIXEDWIDTH: u32 = 0x0400;
const WM_NOTIFY: UINT = 0x004E;
const WM_SETFONT: UINT = 0x0030;
const WM_PAINT: UINT = 0x000F;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_CAPTURECHANGED: UINT = 0x0215;
const WM_SETCURSOR: UINT = 0x0020;
const SW_HIDE: c_int = 0;
const TCM_FIRST: UINT = 0x1300;
const TCM_GETCURSEL: UINT = TCM_FIRST + 11;
const TCM_SETCURSEL: UINT = TCM_FIRST + 12;
const TCM_DELETEITEM: UINT = TCM_FIRST + 8;
const TCM_DELETEALLITEMS: UINT = TCM_FIRST + 9;
const TCM_INSERTITEMW: UINT = TCM_FIRST + 62;
const TCM_SETITEMW: UINT = TCM_FIRST + 61;
const TCM_SETITEMSIZE: UINT = TCM_FIRST + 41;
const TCIF_TEXT: UINT = 0x0001;
const TCN_FIRST: i32 = -550;
const TCN_SELCHANGE: i32 = TCN_FIRST - 1;
const NM_CLICK: i32 = -2;
const ICC_TAB_CLASSES: DWORD = 0x00000008;
const TAB_HEIGHT: i32 = 30;
const DIVIDER_THICKNESS: i32 = 10;
const BTN_WIDTH: i32 = 30;
const BTN_NEW_TAB_ID: c_int = 200;
const BTN_DROPDOWN_ID: c_int = 201;
const WM_COMMAND: UINT = 0x0111;
const WM_DRAWITEM: UINT = 0x002B;
const TCM_HITTEST: UINT = TCM_FIRST + 13;
const TCM_GETITEMRECT: UINT = TCM_FIRST + 10;
const TCS_OWNERDRAWFIXED: u32 = 0x2000;
const ODS_SELECTED: UINT = 0x0001;
const BS_OWNERDRAW: u32 = 0x0000000B;
const DT_CENTER: UINT = 0x0001;
const DT_VCENTER: UINT = 0x0004;
const DT_SINGLELINE: UINT = 0x0020;
const DT_LEFT: UINT = 0x0000;
const TRANSPARENT: i32 = 1;
const GWLP_WNDPROC: c_int = -4;
const TME_LEAVE: DWORD = 0x00000002;
const WM_MOUSELEAVE: UINT = 0x02A3;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};

const DRAWITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemAction: UINT,
    itemState: UINT,
    hwndItem: HWND,
    hDC: ?*anyopaque,
    rcItem: RECT,
    itemData: usize,
};

const TCHITTESTINFO = extern struct {
    pt: sys.POINT,
    flags: UINT = 0,
};

extern "gdi32" fn SetTextColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkMode(hdc: ?*anyopaque, mode: i32) callconv(.winapi) i32;
extern "user32" fn DrawTextW(hdc: ?*anyopaque, lpchText: [*:0]const u16, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;
extern "gdi32" fn SelectObject(hdc: ?*anyopaque, h: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn GetStockObject(i: i32) callconv(.winapi) ?*anyopaque;
extern "user32" fn CreatePopupMenu() callconv(.winapi) ?*anyopaque;
extern "user32" fn AppendMenuW(hMenu: *anyopaque, uFlags: u32, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) i32;
extern "user32" fn TrackPopupMenu(hMenu: *anyopaque, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*anyopaque) callconv(.winapi) i32;
extern "user32" fn DestroyMenu(hMenu: *anyopaque) callconv(.winapi) i32;
extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *sys.POINT) callconv(.winapi) BOOL;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *sys.POINT) callconv(.winapi) BOOL;
extern "user32" fn GetCursorPos(lpPoint: *sys.POINT) callconv(.winapi) BOOL;
extern "user32" fn GetParent(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn CallWindowProcW(lpPrevWndFunc: WNDPROC, hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;

const MF_STRING: u32 = 0x0000;
const MF_SEPARATOR: u32 = 0x0800;
const MF_POPUP: u32 = 0x0010;
const TPM_LEFTALIGN: u32 = 0x0000;
const TPM_RETURNCMD: u32 = 0x0100;
const MENU_NEW_TAB: usize = 6003;
const MENU_DISTRO_BASE: usize = 6100;
const MENU_POWERSHELL: usize = 6200;
const MENU_CMD: usize = 6201;
const IDC_SIZEWE = @as(?[*:0]align(1) const u16, @ptrFromInt(32644));
const IDC_SIZENS = @as(?[*:0]align(1) const u16, @ptrFromInt(32645));

const NMHDR = extern struct {
    hwndFrom: HWND,
    idFrom: usize,
    code: i32,
};

const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD,
    dwICC: DWORD,
};

const TCITEMW = extern struct {
    mask: UINT,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    pszText: ?[*:0]u16 = null,
    cchTextMax: c_int = 0,
    iImage: c_int = 0,
    lParam: LPARAM = 0,
};

extern "comctl32" fn InitCommonControlsEx(lpInitCtrls: *const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
extern "gdi32" fn CreateFontW(cHeight: c_int, cWidth: c_int, cEscapement: c_int, cOrientation: c_int, cWeight: c_int, bItalic: DWORD, bUnderline: DWORD, bStrikeOut: DWORD, iCharSet: DWORD, iOutPrecision: DWORD, iClipPrecision: DWORD, iQuality: DWORD, iPitchAndFamily: DWORD, pszFaceName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) BOOL;
extern "user32" fn FillRect(hDC: ?*anyopaque, lprc: *const RECT, hbr: ?*anyopaque) callconv(.winapi) c_int;
extern "gdi32" fn CreateCompatibleDC(hdc: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateCompatibleBitmap(hdc: ?*anyopaque, cx: i32, cy: i32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteDC(hdc: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn BitBlt(hdcDest: ?*anyopaque, x: i32, y: i32, cx: i32, cy: i32, hdcSrc: ?*anyopaque, x1: i32, y1: i32, rop: u32) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn SetCursor(hCursor: sys.HCURSOR) callconv(.winapi) sys.HCURSOR;

var ui_font: ?*anyopaque = null;
var divider_class_registered: bool = false;

// DirectWrite/Direct2D state for color emoji text rendering (lazy-init)
var dw_factory: ?*anyopaque = null;
var dw_text_format: ?*anyopaque = null;
var d2d_factory: ?*anyopaque = null;
var d2d_dc_target: ?*anyopaque = null;
var d2d_init_attempted: bool = false;

/// GUID struct for COM IID parameters
const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

// {06152247-6f50-465a-9245-118bfd3b6007}
const IID_ID2D1Factory = GUID{ .a = 0x06152247, .b = 0x6f50, .c = 0x465a, .d = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 } };
// {b859ee5a-d838-4b5b-a2e8-1adc7d93db48}
const IID_IDWriteFactory = GUID{ .a = 0xb859ee5a, .b = 0xd838, .c = 0x4b5b, .d = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };

extern "d2d1" fn D2D1CreateFactory(factoryType: u32, riid: *const GUID, pFactoryOptions: ?*const anyopaque, ppIFactory: *?*anyopaque) callconv(.winapi) i32;
extern "dwrite" fn DWriteCreateFactory(factoryType: u32, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) i32;

/// Call a COM method at the given vtable index. All COM objects start with a
/// pointer to a vtable (array of function pointers).
fn comVtbl(obj: *anyopaque) [*]const *const anyopaque {
    return @as(*const [*]const *const anyopaque, @ptrCast(@alignCast(obj))).*;
}

/// D2D1_RENDER_TARGET_PROPERTIES with defaults for a DC render target
const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32 = 0, // D2D1_RENDER_TARGET_TYPE_DEFAULT
    pixelFormat: extern struct {
        format: u32 = 87, // DXGI_FORMAT_B8G8R8A8_UNORM
        alphaMode: u32 = 1, // D2D1_ALPHA_MODE_PREMULTIPLIED
    } = .{},
    dpiX: f32 = 0.0,
    dpiY: f32 = 0.0,
    usage: u32 = 0, // D2D1_RENDER_TARGET_USAGE_NONE
    minLevel: u32 = 0, // D2D1_FEATURE_LEVEL_DEFAULT
};

const D2D1_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
const D2D1_RECT_F = extern struct { left: f32, top: f32, right: f32, bottom: f32 };

/// Initialize DirectWrite + Direct2D factories and text format.
/// Returns true if D2D text rendering is available.
fn initD2D() bool {
    if (d2d_init_attempted) return d2d_dc_target != null;
    d2d_init_attempted = true;

    // Create DirectWrite factory (DWRITE_FACTORY_TYPE_SHARED = 0)
    var hr = DWriteCreateFactory(0, &IID_IDWriteFactory, &dw_factory);
    if (hr < 0 or dw_factory == null) return false;

    // IDWriteFactory::CreateTextFormat (vtable index 15)
    const CreateTextFormatFn = *const fn (
        self: *anyopaque,
        fontFamilyName: [*:0]const u16,
        fontCollection: ?*anyopaque,
        fontWeight: u32,
        fontStyle: u32,
        fontStretch: u32,
        fontSize: f32,
        localeName: [*:0]const u16,
        textFormat: *?*anyopaque,
    ) callconv(.winapi) i32;
    const createTextFormat: CreateTextFormatFn = @ptrCast(@alignCast(comVtbl(dw_factory.?)[15]));
    hr = createTextFormat(
        dw_factory.?,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        null,
        400, // DWRITE_FONT_WEIGHT_NORMAL
        0, // DWRITE_FONT_STYLE_NORMAL
        5, // DWRITE_FONT_STRETCH_MEDIUM
        14.0,
        std.unicode.utf8ToUtf16LeStringLiteral("en-US"),
        &dw_text_format,
    );
    if (hr < 0 or dw_text_format == null) return false;

    // IDWriteTextFormat::SetParagraphAlignment (vtable index 4)
    // DWRITE_PARAGRAPH_ALIGNMENT_CENTER = 1 — vertically centers tab text
    const SetParagraphAlignFn = *const fn (self: *anyopaque, alignment: u32) callconv(.winapi) i32;
    const setParagraphAlign: SetParagraphAlignFn = @ptrCast(@alignCast(comVtbl(dw_text_format.?)[4]));
    _ = setParagraphAlign(dw_text_format.?, 1);

    // Create D2D factory (D2D1_FACTORY_TYPE_SINGLE_THREADED = 0)
    hr = D2D1CreateFactory(0, &IID_ID2D1Factory, null, &d2d_factory);
    if (hr < 0 or d2d_factory == null) return false;

    // ID2D1Factory::CreateDCRenderTarget (vtable index 16)
    const CreateDCRenderTargetFn = *const fn (
        self: *anyopaque,
        renderTargetProperties: *const D2D1_RENDER_TARGET_PROPERTIES,
        dcRenderTarget: *?*anyopaque,
    ) callconv(.winapi) i32;
    const createDCRT: CreateDCRenderTargetFn = @ptrCast(@alignCast(comVtbl(d2d_factory.?)[16]));
    const rt_props = D2D1_RENDER_TARGET_PROPERTIES{};
    hr = createDCRT(d2d_factory.?, &rt_props, &d2d_dc_target);
    if (hr < 0 or d2d_dc_target == null) return false;

    return true;
}

/// Draw text using Direct2D with color emoji support. Falls back to GDI on failure.
fn drawTextD2D(hdc: ?*anyopaque, text: [*:0]const u16, text_len: u32, rect: *const RECT, color: D2D1_COLOR_F) bool {
    if (!initD2D()) return false;
    const rt = d2d_dc_target orelse return false;
    const vtbl = comVtbl(rt);

    // BindDC (vtable index 57)
    const BindDCFn = *const fn (self: *anyopaque, hDC: ?*anyopaque, pSubRect: *const RECT) callconv(.winapi) i32;
    const bindDC: BindDCFn = @ptrCast(@alignCast(vtbl[57]));
    if (bindDC(rt, hdc, rect) < 0) return false;

    // BeginDraw (vtable index 48)
    const BeginDrawFn = *const fn (self: *anyopaque) callconv(.winapi) void;
    const beginDraw: BeginDrawFn = @ptrCast(@alignCast(vtbl[48]));
    beginDraw(rt);

    // CreateSolidColorBrush (vtable index 8)
    const CreateBrushFn = *const fn (self: *anyopaque, color_ptr: *const D2D1_COLOR_F, brushProperties: ?*const anyopaque, brush: *?*anyopaque) callconv(.winapi) i32;
    const createBrush: CreateBrushFn = @ptrCast(@alignCast(vtbl[8]));
    var brush: ?*anyopaque = null;
    if (createBrush(rt, &color, null, &brush) < 0 or brush == null) {
        // EndDraw even on failure
        const EndDrawFn = *const fn (self: *anyopaque, tag1: ?*u64, tag2: ?*u64) callconv(.winapi) i32;
        const endDraw: EndDrawFn = @ptrCast(@alignCast(vtbl[49]));
        _ = endDraw(rt, null, null);
        return false;
    }

    // DrawText (vtable index 27)
    // Rect is in local coordinates (0,0 based) since BindDC mapped the DC region
    const d2d_rect = D2D1_RECT_F{
        .left = 0,
        .top = 0,
        .right = @floatFromInt(rect.right - rect.left),
        .bottom = @floatFromInt(rect.bottom - rect.top),
    };
    const DrawTextFn2 = *const fn (
        self: *anyopaque,
        string: [*:0]const u16,
        stringLength: u32,
        textFormat: ?*anyopaque,
        layoutRect: *const D2D1_RECT_F,
        defaultForegroundBrush: *anyopaque,
        options: u32,
        measuringMode: u32,
    ) callconv(.winapi) void;
    const drawText: DrawTextFn2 = @ptrCast(@alignCast(vtbl[27]));
    // D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT = 0x04
    drawText(rt, text, text_len, dw_text_format, &d2d_rect, brush.?, 0x04, 0);

    // Release brush
    const ReleaseFn = *const fn (self: *anyopaque) callconv(.winapi) u32;
    const releaseBrush: ReleaseFn = @ptrCast(@alignCast(comVtbl(brush.?)[2]));
    _ = releaseBrush(brush.?);

    // EndDraw (vtable index 49)
    const EndDrawFn = *const fn (self: *anyopaque, tag1: ?*u64, tag2: ?*u64) callconv(.winapi) i32;
    const endDraw: EndDrawFn = @ptrCast(@alignCast(vtbl[49]));
    _ = endDraw(rt, null, null);

    return true;
}

/// Convert config Color (RGB) to Win32 COLORREF (0x00BBGGRR)
fn configColorToRef(color: configpkg.Config.Color) u32 {
    return (@as(u32, color.b) << 16) | (@as(u32, color.g) << 8) | @as(u32, color.r);
}

/// Convert config Color to D2D1_COLOR_F (0.0-1.0 floats)
fn configColorToD2D(color: configpkg.Config.Color) D2D1_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(color.r)) / 255.0,
        .g = @as(f32, @floatFromInt(color.g)) / 255.0,
        .b = @as(f32, @floatFromInt(color.b)) / 255.0,
        .a = 1.0,
    };
}

fn colorRefToD2D(ref: u32) D2D1_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(ref & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((ref >> 8) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt((ref >> 16) & 0xFF)) / 255.0,
        .a = 1.0,
    };
}

const DividerState = struct {
    hwnd: HWND,
    window: *Window,
    node: *SplitTree.Node,
    direction: SplitTree.Direction,
    rect: SplitTree.Rect,
    bounds: SplitTree.Rect,
    active: bool = false,
};

const DividerDrag = struct {
    divider: *DividerState,
};

pub const CreateOptions = struct {
    command: ?configpkg.Command = null,
    working_directory: ?configpkg.WorkingDirectory = null,
    title: ?[:0]const u8 = null,
    quick_terminal: bool = false,
    /// WSL distribution to use for this tab (overrides global wsl-distro config).
    wsl_distro: ?[:0]const u8 = null,
    /// Shell backend for this tab (overrides global shell-mode config).
    shell_mode: ?configpkg.Config.ShellMode = null,

    pub const none: @This() = .{};

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        if (self.command) |cmd| cmd.deinit(alloc);
        if (self.working_directory) |wd| switch (wd) {
            .path => |path| alloc.free(path),
            else => {},
        };
        if (self.title) |title| alloc.free(title);
        if (self.wsl_distro) |distro| alloc.free(distro);
        self.* = .{};
    }
};

const TabState = struct {
    primary_surface: *Surface,
    tree: SplitTree,
    focused_surface: ?*Surface = null,
    title: [:0]const u8,
};

app: *App,
hwnd: ?HWND = null,
tab_hwnd: ?HWND = null,
btn_new_tab: ?HWND = null,
btn_dropdown: ?HWND = null,
hover_hwnd: ?HWND = null,
close_hover_tab: ?usize = null,
btn_orig_proc: ?WNDPROC = null,
tab_orig_proc: ?WNDPROC = null,
tab_drag_idx: ?usize = null,
tab_drag_start_x: i32 = 0,
tab_drag_active: bool = false,
primary_surface: *Surface,
tree: ?SplitTree = null,
focused_surface: ?*Surface = null,
surface_initialized: bool = false,
tabs: std.ArrayListUnmanaged(TabState) = .{},
current_tab: usize = 0,
fullscreen: FullscreenState = .{},
quick_terminal: bool = false,
dividers: std.ArrayListUnmanaged(*DividerState) = .{},
drag: ?DividerDrag = null,

const FullscreenState = struct {
    active: bool = false,
    style: i32 = 0,
    ex_style: i32 = 0,
    rect: RECT = std.mem.zeroes(RECT),
};

pub fn create(alloc: Allocator, app: *App, opts: CreateOptions) !*Window {
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .primary_surface = undefined,
        .quick_terminal = opts.quick_terminal,
    };

    try self.createHwnd(opts.title);
    errdefer {
        if (self.hwnd) |h| _ = sys.DestroyWindow(h);
    }

    try self.createTabControl();
    _ = sys.SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    _ = try self.insertTab(0, opts, true);
    if (self.quick_terminal) self.applyQuickTerminalLayout() else self.applyConfiguredWindowSize();
    self.relayout();

    if (self.focused_surface) |surface| {
        _ = sys.SetFocus(surface.hwnd);
        if (surface.core_surface) |core| {
            core.colorSchemeCallback(app.detectColorScheme()) catch {};
        }
    }

    return self;
}

pub fn deinit(self: *Window) void {
    self.destroyDividers();
    self.syncActiveTabFromWindow();
    for (self.tabs.items) |*tab| self.deinitTab(tab);
    self.tabs.deinit(self.app.alloc);
    self.tree = null;
    self.surface_initialized = false;
    if (self.btn_new_tab) |hwnd| {
        _ = sys.DestroyWindow(hwnd);
        self.btn_new_tab = null;
    }
    if (self.btn_dropdown) |hwnd| {
        _ = sys.DestroyWindow(hwnd);
        self.btn_dropdown = null;
    }
    if (self.tab_hwnd) |hwnd| {
        _ = sys.DestroyWindow(hwnd);
        self.tab_hwnd = null;
    }
    if (self.hwnd) |hwnd| {
        _ = sys.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

fn createHwnd(self: *Window, title_override: ?[:0]const u8) !void {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
    const hinstance = sys.GetModuleHandleW(null);
    const wc: sys.WNDCLASSEXW = .{
        .cbSize = @sizeOf(sys.WNDCLASSEXW),
        .style = sys.CS_HREDRAW | sys.CS_VREDRAW | sys.CS_OWNDC,
        .lpfnWndProc = App.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = sys.LoadIconW(hinstance, @ptrFromInt(1)),
        .hCursor = sys.LoadCursorW(null, sys.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = sys.LoadIconW(hinstance, @ptrFromInt(1)),
    };
    _ = sys.RegisterClassExW(&wc);

    const title = if (title_override) |title_utf8|
        try std.unicode.utf8ToUtf16LeAllocZ(self.app.alloc, title_utf8)
    else
        null;
    defer if (title) |v| self.app.alloc.free(v);

    self.hwnd = sys.CreateWindowExW(
        if (self.quick_terminal) @intCast(sys.WS_EX_TOPMOST) else 0,
        class_name,
        if (title) |v| v.ptr else std.unicode.utf8ToUtf16LeStringLiteral("GhostInTheWSL"),
        if (self.quick_terminal) sys.WS_OVERLAPPEDWINDOW & ~sys.WS_CAPTION_BIT else sys.WS_OVERLAPPEDWINDOW,
        sys.CW_USEDEFAULT,
        sys.CW_USEDEFAULT,
        900,
        650,
        null,
        null,
        hinstance,
        null,
    );
    if (self.hwnd == null) return error.Win32Error;
    _ = sys.ShowWindow(self.hwnd.?, sys.SW_SHOWNORMAL);
    _ = sys.UpdateWindow(self.hwnd.?);
}

fn createTabControl(self: *Window) !void {
    const icc: INITCOMMONCONTROLSEX = .{
        .dwSize = @sizeOf(INITCOMMONCONTROLSEX),
        .dwICC = ICC_TAB_CLASSES,
    };
    _ = InitCommonControlsEx(&icc);
    const hinstance = sys.GetModuleHandleW(null);
    self.tab_hwnd = sys.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("SysTabControl32"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | TCS_FIXEDWIDTH | TCS_OWNERDRAWFIXED,
        0,
        0,
        0,
        TAB_HEIGHT,
        self.hwnd,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    if (ui_font == null) {
        ui_font = CreateFontW(
            -18,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
    }
    if (ui_font) |font| {
        _ = sys.SendMessageW(self.tab_hwnd.?, WM_SETFONT, @intFromPtr(font), 1);
    }

    // Create "+" new tab button
    self.btn_new_tab = sys.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("+"),
        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
        0,
        0,
        BTN_WIDTH,
        TAB_HEIGHT,
        self.hwnd,
        @ptrFromInt(@as(usize, @intCast(BTN_NEW_TAB_ID))),
        hinstance,
        null,
    );

    // Create dropdown button for distro picker
    self.btn_dropdown = sys.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("\u{25BC}"),
        WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
        0,
        0,
        BTN_WIDTH,
        TAB_HEIGHT,
        self.hwnd,
        @ptrFromInt(@as(usize, @intCast(BTN_DROPDOWN_ID))),
        hinstance,
        null,
    );

    // Subclass buttons for hover tracking
    if (self.btn_new_tab) |btn| {
        const orig = sys.SetWindowLongPtrW(btn, GWLP_WNDPROC, @bitCast(@intFromPtr(&btnSubclassProc)));
        if (self.btn_orig_proc == null and orig != 0) {
            self.btn_orig_proc = @ptrFromInt(@as(usize, @bitCast(orig)));
        }
    }
    if (self.btn_dropdown) |btn| {
        const orig = sys.SetWindowLongPtrW(btn, GWLP_WNDPROC, @bitCast(@intFromPtr(&btnSubclassProc)));
        if (self.btn_orig_proc == null and orig != 0) {
            self.btn_orig_proc = @ptrFromInt(@as(usize, @bitCast(orig)));
        }
    }

    // Subclass tab control for close-button hover tracking
    {
        const orig = sys.SetWindowLongPtrW(self.tab_hwnd.?, GWLP_WNDPROC, @bitCast(@intFromPtr(&tabSubclassProc)));
        if (orig != 0) {
            self.tab_orig_proc = @ptrFromInt(@as(usize, @bitCast(orig)));
        }
    }
}

fn getWindowFromChild(child: HWND) ?*Window {
    const parent = GetParent(child) orelse return null;
    const ptr = sys.GetWindowLongPtrW(parent, sys.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn btnSubclassProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const window = getWindowFromChild(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
    const orig = window.btn_orig_proc orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        WM_MOUSEMOVE => {
            if (window.hover_hwnd == null or window.hover_hwnd.? != hwnd) {
                // Invalidate the previously hovered button so it redraws without hover
                if (window.hover_hwnd) |old| {
                    _ = sys.InvalidateRect(old, null, 0);
                }
                window.hover_hwnd = hwnd;
                var tme: TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(TRACKMOUSEEVENT),
                    .dwFlags = TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = TrackMouseEvent(&tme);
                _ = sys.InvalidateRect(hwnd, null, 0);
            }
        },
        WM_MOUSELEAVE => {
            if (window.hover_hwnd != null and window.hover_hwnd.? == hwnd) {
                window.hover_hwnd = null;
                _ = sys.InvalidateRect(hwnd, null, 0);
            }
        },
        else => {},
    }
    return CallWindowProcW(orig, hwnd, msg, wparam, lparam);
}

fn tabSubclassProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const window = getWindowFromChild(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
    const orig = window.tab_orig_proc orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        0x0014 => return 1, // WM_ERASEBKGND: suppress — let previous content stay until WM_DRAWITEM
        WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            var hit: TCHITTESTINFO = .{ .pt = .{ .x = x, .y = y } };
            const tab_idx_raw = sys.SendMessageW(hwnd, TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
            if (tab_idx_raw >= 0) {
                const tab_idx: usize = @intCast(tab_idx_raw);
                // Don't start drag if clicking the close button
                var tab_rect: RECT = std.mem.zeroes(RECT);
                _ = sys.SendMessageW(hwnd, TCM_GETITEMRECT, tab_idx, @bitCast(@intFromPtr(&tab_rect)));
                if (x < tab_rect.right - 20) {
                    window.tab_drag_idx = tab_idx;
                    window.tab_drag_start_x = x;
                    window.tab_drag_active = false;
                    _ = SetCapture(hwnd);
                }
            }
            // Let the original proc handle selection
            return CallWindowProcW(orig, hwnd, msg, wparam, lparam);
        },
        WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));

            // Drag-to-reorder logic
            if (window.tab_drag_idx != null) {
                const drag_idx = window.tab_drag_idx.?;
                // Activate drag after moving at least 5 pixels
                if (!window.tab_drag_active) {
                    const dx = x - window.tab_drag_start_x;
                    if (dx > 5 or dx < -5) {
                        window.tab_drag_active = true;
                    }
                }
                if (window.tab_drag_active) {
                    var hit: TCHITTESTINFO = .{ .pt = .{ .x = x, .y = y } };
                    const target_raw = sys.SendMessageW(hwnd, TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
                    if (target_raw >= 0) {
                        const target_idx: usize = @intCast(target_raw);
                        if (target_idx != drag_idx) {
                            window.moveTabTo(drag_idx, target_idx);
                            window.tab_drag_idx = target_idx;
                        }
                    }
                    // Don't update close hover while dragging
                    return CallWindowProcW(orig, hwnd, msg, wparam, lparam);
                }
            }

            // Close button hover tracking (only when not dragging)
            var tme: TRACKMOUSEEVENT = .{
                .cbSize = @sizeOf(TRACKMOUSEEVENT),
                .dwFlags = TME_LEAVE,
                .hwndTrack = hwnd,
                .dwHoverTime = 0,
            };
            _ = TrackMouseEvent(&tme);

            var hit: TCHITTESTINFO = .{ .pt = .{ .x = x, .y = y } };
            const tab_idx_raw = sys.SendMessageW(hwnd, TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));

            var new_hover: ?usize = null;
            if (tab_idx_raw >= 0) {
                const tab_idx: usize = @intCast(tab_idx_raw);
                var tab_rect: RECT = std.mem.zeroes(RECT);
                _ = sys.SendMessageW(hwnd, TCM_GETITEMRECT, tab_idx, @bitCast(@intFromPtr(&tab_rect)));
                if (x >= tab_rect.right - 20) {
                    new_hover = tab_idx;
                }
            }

            if (!optionalEql(window.close_hover_tab, new_hover)) {
                const old_hover = window.close_hover_tab;
                window.close_hover_tab = new_hover;
                // Only invalidate the specific tab(s) that changed, not the whole control
                if (old_hover) |idx| invalidateTab(hwnd, idx);
                if (new_hover) |idx| invalidateTab(hwnd, idx);
            }
        },
        WM_LBUTTONUP => {
            if (window.tab_drag_idx != null) {
                window.tab_drag_idx = null;
                window.tab_drag_active = false;
                _ = ReleaseCapture();
            }
            return CallWindowProcW(orig, hwnd, msg, wparam, lparam);
        },
        WM_CAPTURECHANGED => {
            window.tab_drag_idx = null;
            window.tab_drag_active = false;
        },
        WM_MOUSELEAVE => {
            if (window.close_hover_tab) |idx| {
                window.close_hover_tab = null;
                invalidateTab(hwnd, idx);
            }
        },
        else => {},
    }
    return CallWindowProcW(orig, hwnd, msg, wparam, lparam);
}

fn optionalEql(a: ?usize, b: ?usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// Invalidate just one tab's rect instead of the entire tab control.
/// Inflates by 4px to account for the selected-tab rect expansion that
/// WM_DRAWITEM applies on top of TCM_GETITEMRECT.
fn invalidateTab(hwnd: HWND, tab_idx: usize) void {
    var tab_rect: RECT = std.mem.zeroes(RECT);
    _ = sys.SendMessageW(hwnd, TCM_GETITEMRECT, tab_idx, @bitCast(@intFromPtr(&tab_rect)));
    tab_rect.left -= 4;
    tab_rect.top -= 4;
    tab_rect.right += 4;
    tab_rect.bottom += 4;
    _ = sys.InvalidateRect(hwnd, &tab_rect, 0);
}

fn registerDividerClass() !void {
    if (divider_class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDivider");
    const hinstance = sys.GetModuleHandleW(null);
    const wc: sys.WNDCLASSEXW = .{
        .cbSize = @sizeOf(sys.WNDCLASSEXW),
        .style = sys.CS_HREDRAW | sys.CS_VREDRAW,
        .lpfnWndProc = dividerWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = sys.LoadCursorW(null, sys.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (sys.RegisterClassExW(&wc) == 0) return error.Win32Error;
    divider_class_registered = true;
}

fn dividerWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const ptr = sys.GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
    const divider: *DividerState = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return divider.window.handleDividerMessage(divider, hwnd, msg, wparam, lparam);
}

fn destroyDividers(self: *Window) void {
    if (self.drag != null) {
        _ = ReleaseCapture();
        self.drag = null;
    }
    for (self.dividers.items) |divider| {
        _ = sys.DestroyWindow(divider.hwnd);
        self.app.alloc.destroy(divider);
    }
    self.dividers.deinit(self.app.alloc);
}

fn ensureDividerCount(self: *Window, count: usize) !void {
    try registerDividerClass();
    while (self.dividers.items.len < count) {
        const divider = try self.app.alloc.create(DividerState);
        errdefer self.app.alloc.destroy(divider);
        const hwnd = sys.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDivider"),
            null,
            WS_CHILD | WS_VISIBLE,
            0,
            0,
            0,
            0,
            self.hwnd,
            null,
            sys.GetModuleHandleW(null),
            null,
        ) orelse return error.Win32Error;
        divider.* = .{
            .hwnd = hwnd,
            .window = self,
            .node = undefined,
            .direction = .horizontal,
            .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        };
        _ = sys.SetWindowLongPtrW(hwnd, sys.GWLP_USERDATA, @bitCast(@intFromPtr(divider)));
        try self.dividers.append(self.app.alloc, divider);
    }
}

fn updateDividers(self: *Window, bounds: SplitTree.Rect) void {
    const tree = &(self.tree orelse {
        self.hideAllDividers();
        return;
    });
    var buf: [64]SplitTree.DividerRect = undefined;
    const count = tree.collectDividerRects(bounds, &buf);
    self.ensureDividerCount(count) catch return;

    for (self.dividers.items, 0..) |divider, i| {
        if (i >= count) {
            divider.active = false;
            _ = sys.ShowWindow(divider.hwnd, SW_HIDE);
            continue;
        }
        const info = buf[i];
        divider.node = info.node;
        divider.direction = info.direction;
        divider.rect = info.rect;
        divider.bounds = info.bounds;
        divider.active = true;
        _ = sys.SetWindowPos(
            divider.hwnd,
            null,
            info.rect.x,
            info.rect.y,
            info.rect.w,
            info.rect.h,
            0x0004,
        );
        _ = sys.ShowWindow(divider.hwnd, sys.SW_SHOWNORMAL);
        _ = sys.InvalidateRect(divider.hwnd, null, 1);
    }
}

fn hideAllDividers(self: *Window) void {
    for (self.dividers.items) |divider| {
        divider.active = false;
        _ = sys.ShowWindow(divider.hwnd, SW_HIDE);
    }
}

fn adjustDividerRatio(self: *Window, divider: *DividerState, lparam: LPARAM) void {
    const sp = switch (divider.node.*) {
        .split => |*sp| sp,
        else => return,
    };
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    const new_ratio: f32 = switch (divider.direction) {
        .horizontal => blk: {
            if (divider.bounds.w <= DIVIDER_THICKNESS) break :blk sp.ratio;
            const absolute_x = divider.rect.x + x;
            const offset = std.math.clamp(absolute_x - divider.bounds.x, 0, divider.bounds.w);
            break :blk @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(divider.bounds.w));
        },
        .vertical => blk: {
            if (divider.bounds.h <= DIVIDER_THICKNESS) break :blk sp.ratio;
            const absolute_y = divider.rect.y + y;
            const offset = std.math.clamp(absolute_y - divider.bounds.y, 0, divider.bounds.h);
            break :blk @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(divider.bounds.h));
        },
    };
    sp.ratio = std.math.clamp(new_ratio, 0.1, 0.9);
    self.relayout();
}

fn handleDividerMessage(self: *Window, divider: *DividerState, hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) LRESULT {
    switch (msg) {
        WM_PAINT => {
            var ps: sys.PAINTSTRUCT = std.mem.zeroes(sys.PAINTSTRUCT);
            const hdc = sys.BeginPaint(hwnd, &ps);
            var rect: RECT = std.mem.zeroes(RECT);
            _ = sys.GetClientRect(hwnd, &rect);
            const bg_brush = CreateSolidBrush(0x00E4E4E4);
            if (bg_brush != null) {
                _ = FillRect(hdc, &rect, bg_brush);
                _ = DeleteObject(bg_brush);
            }
            var line_rect = rect;
            if (divider.direction == .horizontal) {
                line_rect.left = @divTrunc(rect.right - rect.left - 2, 2);
                line_rect.right = line_rect.left + 2;
            } else {
                line_rect.top = @divTrunc(rect.bottom - rect.top - 2, 2);
                line_rect.bottom = line_rect.top + 2;
            }
            const line_brush = CreateSolidBrush(0x00858585);
            if (line_brush != null) {
                _ = FillRect(hdc, &line_rect, line_brush);
                _ = DeleteObject(line_brush);
            }
            _ = sys.EndPaint(hwnd, &ps);
            return 0;
        },
        WM_SETCURSOR => {
            _ = SetCursor(sys.LoadCursorW(
                null,
                if (divider.direction == .horizontal) IDC_SIZEWE else IDC_SIZENS,
            ));
            return 1;
        },
        WM_LBUTTONDOWN => {
            self.drag = .{ .divider = divider };
            _ = SetCapture(hwnd);
            self.adjustDividerRatio(divider, lparam);
            return 0;
        },
        WM_MOUSEMOVE => {
            if (self.drag) |drag| {
                if (drag.divider == divider) self.adjustDividerRatio(divider, lparam);
            }
            return 0;
        },
        WM_LBUTTONUP, WM_CAPTURECHANGED => {
            if (self.drag) |drag| {
                if (drag.divider == divider) {
                    self.drag = null;
                    _ = ReleaseCapture();
                }
            }
            return 0;
        },
        else => return sys.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn makeTabTitle(self: *Window, requested: ?[:0]const u8, index: usize) ![:0]const u8 {
    if (requested) |title| return try self.app.alloc.dupeZ(u8, title);
    return try std.fmt.allocPrintSentinel(self.app.alloc, "Tab {d}", .{index + 1}, 0);
}

fn insertTab(self: *Window, raw_index: usize, opts: CreateOptions, select: bool) !usize {
    const alloc = self.app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    surface.* = .{ .hwnd = undefined };

    try surface.init(self.hwnd.?, self.app);
    surface.window = self;
    errdefer surface.deinit();

    try self.initCoreSurface(surface, opts);
    errdefer {
        if (surface.core_surface) |core| {
            core.deinit();
            alloc.destroy(core);
            surface.core_surface = null;
        }
    }

    const tab: TabState = .{
        .primary_surface = surface,
        .tree = try SplitTree.initLeaf(alloc, surface),
        .focused_surface = surface,
        .title = try self.makeTabTitle(opts.title, raw_index),
    };
    errdefer alloc.free(tab.title);

    const index = @min(raw_index, self.tabs.items.len);
    if (self.tabs.items.len > 0) self.syncActiveTabFromWindow();
    try self.tabs.insert(alloc, index, tab);

    if (self.tabs.items.len == 1) {
        self.current_tab = 0;
        self.loadActiveTabIntoWindow();
    } else if (index <= self.current_tab and !select) {
        self.current_tab += 1;
    }

    self.rebuildTabControl();
    self.updateTabVisibility();

    if (select or self.tabs.items.len == 1) {
        try self.activateTab(index);
    } else {
        self.hideTabSurfaces(&self.tabs.items[index]);
        _ = sys.SendMessageW(self.tab_hwnd.?, TCM_SETCURSEL, self.current_tab, 0);
    }

    return index;
}

fn deinitTab(self: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    const count = tab.tree.collectLeaves(&leaves);
    for (leaves[0..count]) |surface| {
        self.app.core_app.deleteSurface(surface);
        if (surface.core_surface) |core| {
            core.deinit();
            self.app.alloc.destroy(core);
            surface.core_surface = null;
        }
        surface.deinit();
        self.app.alloc.destroy(surface);
    }
    tab.tree.deinit(self.app.alloc);
    self.app.alloc.free(tab.title);
}

fn syncActiveTabFromWindow(self: *Window) void {
    if (self.tabs.items.len == 0 or self.current_tab >= self.tabs.items.len) return;
    const tab = &self.tabs.items[self.current_tab];
    tab.primary_surface = self.primary_surface;
    tab.tree = self.tree orelse return;
    tab.focused_surface = self.focused_surface orelse self.primary_surface;
}

fn loadActiveTabIntoWindow(self: *Window) void {
    const tab = &self.tabs.items[self.current_tab];
    self.primary_surface = tab.primary_surface;
    self.tree = tab.tree;
    self.focused_surface = tab.focused_surface orelse tab.primary_surface;
    self.surface_initialized = true;
}

fn activeTab(self: *Window) ?*TabState {
    if (self.tabs.items.len == 0 or self.current_tab >= self.tabs.items.len) return null;
    return &self.tabs.items[self.current_tab];
}

pub fn getFocusedSurface(self: *Window) ?*Surface {
    return self.focused_surface orelse if (self.tabs.items.len > 0) self.primary_surface else null;
}

pub fn getActiveTabTitle(self: *Window) ?[:0]const u8 {
    const tab = self.activeTab() orelse return null;
    return tab.title;
}

pub fn setActiveTabTitle(self: *Window, title: [:0]const u8) !void {
    const tab = self.activeTab() orelse return;
    self.app.alloc.free(tab.title);
    tab.title = try self.app.alloc.dupeZ(u8, title);
    self.updateTabControlTitle(self.current_tab);
}

/// Set the title for the tab that contains the given surface.
/// If the surface isn't in any tab yet (e.g. during init), this is a no-op
/// since the tab will get its title from CreateOptions when inserted.
/// Returns true if the updated tab is the currently active tab.
pub fn setTabTitleForSurface(self: *Window, surface: *Surface, title: [:0]const u8) !bool {
    const idx = self.findTabIndexForSurface(surface) orelse return false;
    if (idx >= self.tabs.items.len) return false;
    const tab = &self.tabs.items[idx];
    self.app.alloc.free(tab.title);
    tab.title = try self.app.alloc.dupeZ(u8, title);
    self.updateTabControlTitle(idx);
    return idx == self.current_tab;
}

fn updateTabVisibility(self: *Window) void {
    const hwnd = self.tab_hwnd orelse return;
    _ = sys.ShowWindow(hwnd, sys.SW_SHOWNORMAL);
    self.updateTabMetrics();
}

fn tabClientHeight(self: *Window) i32 {
    _ = self;
    return TAB_HEIGHT;
}

fn tabLeaves(tab: *TabState, buf: []*Surface) []const *Surface {
    const count = tab.tree.collectLeaves(buf);
    return buf[0..count];
}

fn hideTabSurfaces(_: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    for (tabLeaves(tab, &leaves)) |surface| {
        surface.setVisible(false);
    }
}

fn showTabSurfaces(_: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    for (tabLeaves(tab, &leaves)) |surface| {
        surface.setVisible(true);
    }
}

fn rebuildTabControl(self: *Window) void {
    const hwnd = self.tab_hwnd orelse return;
    _ = sys.SendMessageW(hwnd, TCM_DELETEALLITEMS, 0, 0);
    for (self.tabs.items, 0..) |_, i| self.insertTabControlItem(i) catch {};
    if (self.tabs.items.len > 0) {
        _ = sys.SendMessageW(hwnd, TCM_SETCURSEL, self.current_tab, 0);
    }
    self.updateTabMetrics();
}

fn updateTabMetrics(self: *Window) void {
    const hwnd = self.tab_hwnd orelse return;

    var rect: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(self.hwnd orelse return, &rect) == 0) return;

    const total_width = rect.right - rect.left;
    if (total_width <= 0) return;

    const button_area = 2 * BTN_WIDTH;
    const tabs_i32: i32 = @max(1, @as(i32, @intCast(self.tabs.items.len)));
    const width = @max(110, @divTrunc(total_width - button_area - 8, tabs_i32));
    const size_param: LPARAM = (@as(LPARAM, TAB_HEIGHT) << 16) | @as(LPARAM, @intCast(width & 0xFFFF));
    _ = sys.SendMessageW(hwnd, TCM_SETITEMSIZE, 0, size_param);
    _ = sys.InvalidateRect(hwnd, null, 0);
}

fn insertTabControlItem(self: *Window, index: usize) !void {
    const hwnd = self.tab_hwnd orelse return;
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(self.app.alloc, self.tabs.items[index].title);
    defer self.app.alloc.free(utf16);
    var item: TCITEMW = .{
        .mask = TCIF_TEXT,
        .pszText = utf16.ptr,
    };
    _ = sys.SendMessageW(hwnd, TCM_INSERTITEMW, index, @bitCast(@intFromPtr(&item)));
}

fn updateTabControlTitle(self: *Window, index: usize) void {
    const hwnd = self.tab_hwnd orelse return;
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(self.app.alloc, self.tabs.items[index].title) catch return;
    defer self.app.alloc.free(utf16);
    var item: TCITEMW = .{
        .mask = TCIF_TEXT,
        .pszText = utf16.ptr,
    };
    _ = sys.SendMessageW(hwnd, TCM_SETITEMW, index, @bitCast(@intFromPtr(&item)));
}

fn activateTab(self: *Window, index: usize) !void {
    if (self.tabs.items.len == 0 or index >= self.tabs.items.len) return;
    if (index == self.current_tab and self.tree != null) {
        _ = sys.SendMessageW(self.tab_hwnd.?, TCM_SETCURSEL, index, 0);
        self.relayout();
        if (self.focused_surface) |surface| _ = sys.SetFocus(surface.hwnd);
        return;
    }

    if (self.tabs.items.len > 0 and self.tree != null and self.current_tab < self.tabs.items.len) {
        self.syncActiveTabFromWindow();
        self.hideTabSurfaces(&self.tabs.items[self.current_tab]);
    }

    self.current_tab = index;
    self.loadActiveTabIntoWindow();
    // Relayout BEFORE showing — this resizes the surface HWNDs to current
    // window dimensions while they are still hidden, so the GL backbuffer
    // is at the correct size when the surface becomes visible.
    if (self.tab_hwnd) |hwnd| _ = sys.SendMessageW(hwnd, TCM_SETCURSEL, index, 0);
    self.relayout();
    self.showTabSurfaces(&self.tabs.items[self.current_tab]);
    if (self.focused_surface) |surface| _ = sys.SetFocus(surface.hwnd);
    // Update window title bar to match the newly active tab
    if (self.hwnd) |hwnd| {
        const utf16 = std.unicode.utf8ToUtf16LeAllocZ(self.app.alloc, self.tabs.items[index].title) catch return;
        defer self.app.alloc.free(utf16);
        _ = sys.SetWindowTextW(hwnd, utf16.ptr);
    }
}

fn findTabIndexForSurface(self: *Window, surface: *Surface) ?usize {
    if (self.tabs.items.len == 0) return null;
    if (self.tree) |tree| {
        if (tree.findLeaf(surface) != null and self.current_tab < self.tabs.items.len) return self.current_tab;
    }
    for (self.tabs.items, 0..) |tab, i| {
        if (i == self.current_tab and self.tree != null) continue;
        if (tab.tree.findLeaf(surface) != null) return i;
    }
    return null;
}

fn closeTabAt(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    const was_current = index == self.current_tab;

    if (was_current and self.tree != null) {
        self.syncActiveTabFromWindow();
        self.tree = null;
        self.focused_surface = null;
        self.surface_initialized = false;
    }

    var tab = self.tabs.orderedRemove(index);
    self.deinitTab(&tab);
    if (self.tab_hwnd) |hwnd| _ = sys.SendMessageW(hwnd, TCM_DELETEITEM, index, 0);

    if (self.tabs.items.len == 0) {
        self.tree = null;
        self.focused_surface = null;
        self.surface_initialized = false;
        self.app.closeWindow(self);
        return;
    }

    if (index < self.current_tab or self.current_tab >= self.tabs.items.len) {
        self.current_tab = if (self.current_tab == 0) 0 else self.current_tab - 1;
    }

    if (was_current) {
        // Rebind window state to the newly active tab before rebuilding the
        // tab control so any reentrant messages do not see a freed surface.
        self.loadActiveTabIntoWindow();
        // The newly active tab's surfaces may have been hidden by a prior tab
        // switch.  Make them visible now so the window is not blank.
        self.showTabSurfaces(&self.tabs.items[self.current_tab]);
    }

    self.updateTabVisibility();
    self.rebuildTabControl();
    self.activateTab(self.current_tab) catch {};
}

fn closeEmptyTabAt(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    const was_current = index == self.current_tab;

    if (was_current) {
        self.tree = null;
        self.focused_surface = null;
        self.surface_initialized = false;
    }

    const tab = self.tabs.orderedRemove(index);
    self.app.alloc.free(tab.title);

    if (self.tabs.items.len == 0) {
        self.app.closeWindow(self);
        return;
    }

    if (index < self.current_tab or self.current_tab >= self.tabs.items.len) {
        self.current_tab = if (self.current_tab == 0) 0 else self.current_tab - 1;
    }

    if (was_current) {
        // Rebind window state to the newly active tab before rebuilding the
        // tab control so any reentrant messages do not see a freed surface.
        self.loadActiveTabIntoWindow();
        // The newly active tab's surfaces may have been hidden by a prior tab
        // switch.  Make them visible now so the window is not blank.
        self.showTabSurfaces(&self.tabs.items[self.current_tab]);
    }

    self.updateTabVisibility();
    self.rebuildTabControl();
    self.activateTab(self.current_tab) catch {};
}

pub fn closeTab(self: *Window, mode: apprt.action.CloseTabMode) void {
    if (self.tabs.items.len == 0) return;
    switch (mode) {
        .this => self.closeTabAt(self.current_tab),
        .other => {
            var i = self.tabs.items.len;
            while (i > 0) {
                i -= 1;
                if (i == self.current_tab) continue;
                self.closeTabAt(i);
            }
        },
        .right => {
            var i = self.tabs.items.len;
            while (i > self.current_tab + 1) {
                i -= 1;
                self.closeTabAt(i);
            }
        },
    }
}

pub fn moveTab(self: *Window, amount: isize) bool {
    if (self.tabs.items.len <= 1 or amount == 0) return false;
    self.syncActiveTabFromWindow();
    const old_idx = self.current_tab;
    var desired: isize = @intCast(old_idx);
    desired = std.math.clamp(desired + amount, 0, @as(isize, @intCast(self.tabs.items.len - 1)));
    const new_idx: usize = @intCast(desired);
    if (new_idx == old_idx) return false;
    const moved = self.tabs.orderedRemove(old_idx);
    self.tabs.insert(self.app.alloc, new_idx, moved) catch return false;
    self.current_tab = new_idx;
    self.rebuildTabControl();
    self.activateTab(new_idx) catch {};
    return true;
}

/// Move the tab at `from` to position `to`. Used by drag-to-reorder.
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tabs.items.len or to >= self.tabs.items.len) return;
    self.syncActiveTabFromWindow();
    const moved = self.tabs.orderedRemove(from);
    self.tabs.insert(self.app.alloc, to, moved) catch return;
    // Update current_tab to follow the moved tab
    if (self.current_tab == from) {
        self.current_tab = to;
    } else if (from < self.current_tab and to >= self.current_tab) {
        self.current_tab -= 1;
    } else if (from > self.current_tab and to <= self.current_tab) {
        self.current_tab += 1;
    }
    self.rebuildTabControl();
    self.activateTab(self.current_tab) catch {};
}

pub fn gotoTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tabs.items.len == 0) return false;
    const idx: usize = switch (target) {
        .previous => (self.current_tab + self.tabs.items.len - 1) % self.tabs.items.len,
        .next => (self.current_tab + 1) % self.tabs.items.len,
        .last => self.tabs.items.len - 1,
        else => blk: {
            const raw: i32 = @intFromEnum(target);
            if (raw < 0) break :blk self.current_tab;
            break :blk @min(@as(usize, @intCast(raw)), self.tabs.items.len - 1);
        },
    };
    self.activateTab(idx) catch return false;
    return true;
}

pub fn focusSurface(self: *Window, surface: *Surface) void {
    const idx = self.findTabIndexForSurface(surface) orelse return;
    if (idx != self.current_tab) self.activateTab(idx) catch return;
    self.focused_surface = surface;
    if (self.current_tab < self.tabs.items.len) {
        self.tabs.items[self.current_tab].focused_surface = surface;
    }
}

pub fn initCoreSurface(self: *Window, surface: *Surface, opts: CreateOptions) !void {
    const wsl_log = @import("wsl_log.zig");
    wsl_log.print("initCoreSurface: start (shell_mode={s}, has_command={s})", .{
        if (opts.shell_mode) |m| @tagName(m) else "null",
        if (opts.command != null) "yes" else "no",
    });

    const alloc = self.app.alloc;
    const core = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core);

    try self.app.core_app.addSurface(surface);
    errdefer self.app.core_app.deleteSurface(surface);

    var config = try apprt.surface.newConfig(self.app.core_app, self.app.config, .window);
    defer config.deinit();

    if (opts.command) |cmd| config.command = try cmd.clone(alloc);
    if (opts.working_directory) |wd| config.@"working-directory" = try wd.clone(alloc);
    if (opts.title) |title| config.title = try alloc.dupeZ(u8, title);
    if (opts.wsl_distro) |distro| config.@"wsl-distro" = try alloc.dupeZ(u8, distro);
    if (opts.shell_mode) |mode| config.@"shell-mode" = mode;

    wsl_log.print("initCoreSurface: config ready, shell-mode={s}, calling core.init", .{
        @tagName(config.@"shell-mode"),
    });

    try core.init(alloc, &config, self.app.core_app, self.app, surface);
    errdefer core.deinit();
    surface.core_surface = core;

    wsl_log.print("initCoreSurface: core.init completed OK", .{});
}

pub fn applyConfiguredWindowSize(self: *Window) void {
    const cfg_w = if (self.app.config.@"window-width" > 0) self.app.config.@"window-width" else 80;
    const cfg_h = if (self.app.config.@"window-height" > 0) self.app.config.@"window-height" else 24;
    const hwnd = self.hwnd orelse return;
    const core = self.primary_surface.core_surface orelse return;

    const cell_width = core.size.cell.width;
    const cell_height = core.size.cell.height;
    if (cell_width == 0 or cell_height == 0) return;

    const w: i32 = @intCast(@max(10, cfg_w) * cell_width);
    const h: i32 = @intCast(@as(i32, @intCast(@max(4, cfg_h) * cell_height)) + self.tabClientHeight());

    var rect: RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    _ = sys.AdjustWindowRectEx(&rect, sys.WS_OVERLAPPEDWINDOW, 0, 0);
    _ = sys.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, 0x0002 | 0x0004);
}

pub fn applyQuickTerminalLayout(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var mi: sys.MONITORINFO = std.mem.zeroes(sys.MONITORINFO);
    mi.cbSize = @sizeOf(sys.MONITORINFO);
    const monitor = sys.MonitorFromWindow(hwnd, 2);
    if (sys.GetMonitorInfoW(monitor, &mi) == 0) return;

    const dims: configpkg.Config.QuickTerminalSize.Dimensions = .{
        .width = @intCast(mi.rcWork.right - mi.rcWork.left),
        .height = @intCast(mi.rcWork.bottom - mi.rcWork.top),
    };
    const size = self.app.config.@"quick-terminal-size".calculate(
        self.app.config.@"quick-terminal-position",
        dims,
    );

    const width: i32 = @intCast(size.width);
    const height: i32 = @intCast(size.height);
    const work_w = mi.rcWork.right - mi.rcWork.left;
    const work_h = mi.rcWork.bottom - mi.rcWork.top;
    const origin: struct { x: i32, y: i32 } = switch (self.app.config.@"quick-terminal-position") {
        .top => .{ .x = mi.rcWork.left + @divTrunc(work_w - width, 2), .y = mi.rcWork.top },
        .bottom => .{ .x = mi.rcWork.left + @divTrunc(work_w - width, 2), .y = mi.rcWork.bottom - height },
        .left => .{ .x = mi.rcWork.left, .y = mi.rcWork.top + @divTrunc(work_h - height, 2) },
        .right => .{ .x = mi.rcWork.right - width, .y = mi.rcWork.top + @divTrunc(work_h - height, 2) },
        .center => .{
            .x = mi.rcWork.left + @divTrunc(work_w - width, 2),
            .y = mi.rcWork.top + @divTrunc(work_h - height, 2),
        },
    };

    _ = sys.SetWindowPos(hwnd, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))), origin.x, origin.y, width, height, 0x0004);
}

pub fn relayout(self: *Window) void {
    const tree = &(self.tree orelse return);
    const hwnd = self.hwnd orelse return;
    var rect: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(hwnd, &rect) == 0) return;
    self.updateTabMetrics();
    const tab_h = self.tabClientHeight();
    const total_width = rect.right - rect.left;
    const tab_ctrl_width = total_width - 2 * BTN_WIDTH;
    if (self.tab_hwnd) |tab_hwnd| {
        _ = sys.SetWindowPos(tab_hwnd, null, 0, 0, tab_ctrl_width, tab_h, 0x0004);
    }
    if (self.btn_new_tab) |btn| {
        _ = sys.SetWindowPos(btn, null, tab_ctrl_width, 0, BTN_WIDTH, tab_h, 0x0004);
    }
    if (self.btn_dropdown) |btn| {
        _ = sys.SetWindowPos(btn, null, tab_ctrl_width + BTN_WIDTH, 0, BTN_WIDTH, tab_h, 0x0004);
    }
    // Overlap the surface 2px into the tab bar to cover the tab control's
    // built-in bottom border (a system-colored 1-2px edge).
    const overlap = 2;
    const bounds = SplitTree.Rect{
        .x = 0,
        .y = tab_h - overlap,
        .w = total_width,
        .h = rect.bottom - rect.top - tab_h + overlap,
    };
    tree.layout(bounds, relayoutCb);
    self.updateDividers(bounds);
}

fn relayoutCb(surface: *Surface, rect: SplitTree.Rect) void {
    surface.setLayoutRect(rect.x, rect.y, rect.w, rect.h);
    _ = sys.SetWindowPos(surface.hwnd, null, rect.x, rect.y, rect.w, rect.h, 0x0004);
}

pub fn newTab(self: *Window, opts: CreateOptions) !void {
    const insert_at = if (self.tabs.items.len == 0) 0 else self.current_tab + 1;
    _ = try self.insertTab(insert_at, opts, true);
}

pub fn newSplit(self: *Window, existing: *Surface, dir: apprt.action.SplitDirection) !void {
    const tree = &(self.tree orelse return error.NoTree);
    const alloc = self.app.alloc;

    const new_surface = try alloc.create(Surface);
    errdefer alloc.destroy(new_surface);
    new_surface.* = .{ .hwnd = undefined };

    try new_surface.init(self.hwnd.?, self.app);
    new_surface.window = self;
    errdefer new_surface.deinit();

    try self.initCoreSurface(new_surface, .none);
    errdefer {
        if (new_surface.core_surface) |core| {
            core.deinit();
            alloc.destroy(core);
        }
    }

    const split_dir: SplitTree.Direction = switch (dir) {
        .right, .left => .horizontal,
        .down, .up => .vertical,
    };
    const after = dir == .right or dir == .down;
    try tree.split(alloc, existing, new_surface, split_dir, after);

    self.focused_surface = new_surface;
    if (self.current_tab < self.tabs.items.len) {
        self.tabs.items[self.current_tab].focused_surface = new_surface;
    }
    _ = sys.SetFocus(new_surface.hwnd);
    self.relayout();
}

pub fn closeSurface(self: *Window, surface: *Surface) void {
    const tab_idx = self.findTabIndexForSurface(surface) orelse return;
    const use_active = tab_idx == self.current_tab and self.tree != null;
    var tree_copy = if (use_active) self.tree.? else self.tabs.items[tab_idx].tree;
    const tree = &tree_copy;
    const alloc = self.app.alloc;

    self.app.core_app.deleteSurface(surface);
    if (surface.core_surface) |core| {
        core.deinit();
        alloc.destroy(core);
        surface.core_surface = null;
    }
    surface.deinit();

    const result = tree.removeLeaf(alloc, surface);
    alloc.destroy(surface);

    if (result.empty) {
        self.closeEmptyTabAt(tab_idx);
        return;
    }

    if (use_active) {
        self.tree = tree_copy;
        self.focused_surface = result.focus;
        if (self.current_tab < self.tabs.items.len) {
            self.tabs.items[self.current_tab].focused_surface = result.focus;
        }
        if (result.focus) |focus| _ = sys.SetFocus(focus.hwnd);
        self.relayout();
    } else {
        self.tabs.items[tab_idx].tree = tree_copy;
        self.tabs.items[tab_idx].focused_surface = result.focus;
    }
}

pub fn gotoSplit(self: *Window, target: apprt.action.GotoSplit) void {
    const tree = &(self.tree orelse return);
    const current = self.focused_surface orelse return;

    var buf: [32]SplitTree.LeafRect = undefined;
    const hwnd = self.hwnd orelse return;
    var cr: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(hwnd, &cr) == 0) return;
    const bounds: SplitTree.Rect = .{
        .x = 0,
        .y = self.tabClientHeight(),
        .w = cr.right - cr.left,
        .h = cr.bottom - cr.top - self.tabClientHeight(),
    };
    const count = tree.collectLeafRects(bounds, &buf);
    if (count == 0) return;

    var current_idx: usize = 0;
    for (buf[0..count], 0..) |lr, i| {
        if (lr.surface == current) {
            current_idx = i;
            break;
        }
    }

    const next_idx: usize = switch (target) {
        .next => (current_idx + 1) % count,
        .previous => (current_idx + count - 1) % count,
        .up, .down, .left, .right => blk: {
            const cur = buf[current_idx].rect;
            const cx = cur.x + @divTrunc(cur.w, 2);
            const cy = cur.y + @divTrunc(cur.h, 2);
            var best: ?usize = null;
            var best_dist: i64 = std.math.maxInt(i64);
            for (buf[0..count], 0..) |lr, i| {
                if (i == current_idx) continue;
                const lx = lr.rect.x + @divTrunc(lr.rect.w, 2);
                const ly = lr.rect.y + @divTrunc(lr.rect.h, 2);
                const in_direction = switch (target) {
                    .up => ly < cy,
                    .down => ly > cy,
                    .left => lx < cx,
                    .right => lx > cx,
                    else => false,
                };
                if (!in_direction) continue;
                const dx: i64 = @as(i64, lx) - @as(i64, cx);
                const dy: i64 = @as(i64, ly) - @as(i64, cy);
                const dist = dx * dx + dy * dy;
                if (dist < best_dist) {
                    best_dist = dist;
                    best = i;
                }
            }
            break :blk best orelse return;
        },
    };

    const new_focus = buf[next_idx].surface;
    self.focused_surface = new_focus;
    if (self.current_tab < self.tabs.items.len) self.tabs.items[self.current_tab].focused_surface = new_focus;
    _ = sys.SetFocus(new_focus.hwnd);
}

pub fn equalizeSplits(self: *Window) void {
    const tree = &(self.tree orelse return);
    equalizeNode(tree.root);
    self.relayout();
}

fn equalizeNode(node: *SplitTree.Node) void {
    switch (node.*) {
        .leaf => {},
        .split => |*sp| {
            sp.ratio = 0.5;
            equalizeNode(sp.children[0]);
            equalizeNode(sp.children[1]);
        },
    }
}

pub fn resizeSplit(self: *Window, req: apprt.action.ResizeSplit) void {
    const tree = &(self.tree orelse return);
    const current = self.focused_surface orelse return;
    const want_horizontal = req.direction == .left or req.direction == .right;
    const grow = req.direction == .right or req.direction == .down;

    var path: [32]*SplitTree.Node = undefined;
    var path_len: usize = 0;
    if (!findPath(tree.root, current, &path, &path_len)) return;

    var i = path_len;
    while (i > 0) {
        i -= 1;
        const node = path[i];
        const sp = switch (node.*) {
            .split => |*v| v,
            .leaf => continue,
        };
        const matches = switch (sp.direction) {
            .horizontal => want_horizontal,
            .vertical => !want_horizontal,
        };
        if (!matches) continue;

        const first_contains = containsLeaf(sp.children[0], current);
        const delta: f32 = @as(f32, @floatFromInt(req.amount)) / 400.0;
        var new_ratio = sp.ratio;
        if (first_contains) {
            new_ratio += if (grow) delta else -delta;
        } else {
            new_ratio += if (grow) -delta else delta;
        }
        sp.ratio = std.math.clamp(new_ratio, 0.1, 0.9);
        self.relayout();
        return;
    }
}

fn findPath(node: *SplitTree.Node, target: *Surface, path: []*SplitTree.Node, len: *usize) bool {
    if (len.* >= path.len) return false;
    path[len.*] = node;
    len.* += 1;
    switch (node.*) {
        .leaf => |s| if (s == target) return true,
        .split => |sp| {
            if (findPath(sp.children[0], target, path, len)) return true;
            if (findPath(sp.children[1], target, path, len)) return true;
        },
    }
    len.* -= 1;
    return false;
}

fn containsLeaf(node: *SplitTree.Node, target: *Surface) bool {
    return switch (node.*) {
        .leaf => |s| s == target,
        .split => |sp| containsLeaf(sp.children[0], target) or containsLeaf(sp.children[1], target),
    };
}

pub fn handleTopLevelMessage(self: *Window, msg: UINT, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    switch (msg) {
        WM_NOTIFY => {
            const hdr: *const NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (self.tab_hwnd != null and hdr.hwndFrom == self.tab_hwnd.?) {
                if (hdr.code == TCN_SELCHANGE) {
                    const sel = sys.SendMessageW(self.tab_hwnd.?, TCM_GETCURSEL, 0, 0);
                    const idx: usize = @intCast(sel);
                    self.activateTab(idx) catch {};
                    return 0;
                }
                if (hdr.code == NM_CLICK) {
                    // Check if the click landed on a tab's close button
                    if (self.hitTestTabClose()) |close_idx| {
                        self.closeTabAt(close_idx);
                        return 0;
                    }
                }
            }
        },
        WM_COMMAND => {
            const ctrl_id: u16 = @truncate(wparam & 0xFFFF);
            const notify_code: u16 = @truncate((wparam >> 16) & 0xFFFF);
            // BN_CLICKED == 0
            if (notify_code == 0) {
                if (ctrl_id == BTN_NEW_TAB_ID) {
                    self.newTab(.none) catch {};
                    return 0;
                } else if (ctrl_id == BTN_DROPDOWN_ID) {
                    self.showDropdownMenu();
                    return 0;
                }
            }
        },
        WM_DRAWITEM => {
            const dis: *const DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (self.tab_hwnd != null and dis.hwndItem == self.tab_hwnd.?) {
                self.drawTab(dis);
                return 1;
            }
            // Owner-draw buttons (+ and dropdown)
            if ((self.btn_new_tab != null and dis.hwndItem == self.btn_new_tab.?) or
                (self.btn_dropdown != null and dis.hwndItem == self.btn_dropdown.?))
            {
                self.drawButton(dis);
                return 1;
            }
        },
        // WM_CONTEXTMENU on the tab bar — always show, regardless of mouse reporting
        0x007B => {
            const source_hwnd: HWND = @ptrFromInt(@as(usize, @bitCast(wparam)));
            if (self.tab_hwnd != null and source_hwnd == self.tab_hwnd.?) {
                const screen_x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
                const screen_y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
                const parent_hwnd = self.hwnd orelse return null;
                App.showContextMenu(self.app, self, parent_hwnd, screen_x, screen_y);
                return 0;
            }
        },
        else => {},
    }
    return null;
}

fn showDropdownMenu(self: *Window) void {
    const app = self.app;
    const distros = app.getWslDistros();
    const menu = CreatePopupMenu() orelse return;
    defer _ = DestroyMenu(menu);

    // WSL entries
    _ = AppendMenuW(menu, MF_STRING, MENU_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("WSL (default)"));

    for (distros, 0..) |distro, i| {
        const wtext = std.unicode.utf8ToUtf16LeAllocZ(app.alloc, distro) catch continue;
        defer app.alloc.free(wtext);
        _ = AppendMenuW(menu, MF_STRING, MENU_DISTRO_BASE + i, wtext.ptr);
    }

    // Separator + local shell entries
    _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(menu, MF_STRING, MENU_POWERSHELL, std.unicode.utf8ToUtf16LeStringLiteral("PowerShell"));
    _ = AppendMenuW(menu, MF_STRING, MENU_CMD, std.unicode.utf8ToUtf16LeStringLiteral("Command Prompt"));

    // Position the menu below the dropdown button
    var pt: sys.POINT = .{ .x = 0, .y = TAB_HEIGHT };
    if (self.btn_dropdown) |btn| {
        var btn_rect: RECT = std.mem.zeroes(RECT);
        _ = sys.GetWindowRect(btn, &btn_rect);
        pt = .{ .x = btn_rect.left, .y = btn_rect.bottom };
    } else if (self.hwnd) |hwnd| {
        _ = ClientToScreen(hwnd, &pt);
    }

    const parent_hwnd = self.hwnd orelse return;
    const cmd = TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_RETURNCMD, pt.x, pt.y, 0, parent_hwnd, null);
    const cmd_id: usize = if (cmd > 0) @intCast(cmd) else return;

    if (cmd_id == MENU_NEW_TAB) {
        self.newTab(.none) catch {};
    } else if (cmd_id >= MENU_DISTRO_BASE and cmd_id < MENU_DISTRO_BASE + distros.len) {
        const idx = cmd_id - MENU_DISTRO_BASE;
        const distro = distros[idx];
        const owned = app.alloc.dupeZ(u8, distro) catch return;
        self.newTab(.{ .wsl_distro = owned }) catch {
            app.alloc.free(owned);
        };
    } else if (cmd_id == MENU_POWERSHELL) {
        const wsl_log = @import("wsl_log.zig");
        wsl_log.print("showDropdownMenu: PowerShell selected, creating tab", .{});
        const cmd_str = app.alloc.dupeZ(u8, "powershell.exe") catch return;
        self.newTab(.{ .shell_mode = .local, .command = .{ .shell = cmd_str }, .title = "PowerShell" }) catch |err| {
            wsl_log.print("showDropdownMenu: PowerShell newTab FAILED: {s}", .{@errorName(err)});
            app.alloc.free(cmd_str);
        };
        wsl_log.print("showDropdownMenu: PowerShell newTab returned OK", .{});
    } else if (cmd_id == MENU_CMD) {
        const wsl_log = @import("wsl_log.zig");
        wsl_log.print("showDropdownMenu: Command Prompt selected, creating tab", .{});
        const cmd_str = app.alloc.dupeZ(u8, "cmd.exe") catch return;
        self.newTab(.{ .shell_mode = .local, .command = .{ .shell = cmd_str }, .title = "Command Prompt" }) catch |err| {
            wsl_log.print("showDropdownMenu: CMD newTab FAILED: {s}", .{@errorName(err)});
            app.alloc.free(cmd_str);
        };
        wsl_log.print("showDropdownMenu: CMD newTab returned OK", .{});
    }
}

fn drawTab(self: *Window, dis: *const DRAWITEMSTRUCT) void {
    const screen_dc = dis.hDC orelse return;
    const tab_idx = dis.itemID;
    if (tab_idx >= self.tabs.items.len) return;
    const selected = (dis.itemState & ODS_SELECTED) != 0;
    const close_hovered = self.close_hover_tab != null and self.close_hover_tab.? == tab_idx;

    const rc = dis.rcItem;
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;

    // Double-buffer: draw to off-screen bitmap, then blit in one shot.
    const mem_dc = CreateCompatibleDC(screen_dc);
    const bmp = if (mem_dc) |dc| CreateCompatibleBitmap(screen_dc, w, h) orelse {
        _ = DeleteDC(dc);
        return;
    } else return;
    const old_bmp = SelectObject(mem_dc, bmp);

    // All coordinates below are relative to (0,0) in the memory DC.
    const hdc = mem_dc;

    // Use config background for selected tab, slightly lighter for unselected
    const cfg_bg = self.app.config.background;
    const sel_color = configColorToRef(cfg_bg);
    const unsel_color = brighten(sel_color, 20);
    const bg_color: u32 = if (selected) sel_color else unsel_color;
    const text_color: u32 = configColorToRef(self.app.config.foreground);

    // Fill tab background
    var local_rc: RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    const bg_brush = CreateSolidBrush(bg_color);
    if (bg_brush) |brush| {
        _ = FillRect(hdc, &local_rc, brush);
        _ = DeleteObject(brush);
    }

    // Draw close button background highlight when hovered
    var close_rc: RECT = .{
        .left = w - 22,
        .top = 5,
        .right = w - 2,
        .bottom = h - 5,
    };
    if (close_hovered) {
        const close_bg = CreateSolidBrush(brighten(bg_color, 30));
        if (close_bg) |brush| {
            _ = FillRect(hdc, &close_rc, brush);
            _ = DeleteObject(brush);
        }
    }

    // Draw tab title (left-aligned with padding, leaving room for close button)
    const utf16_title = std.unicode.utf8ToUtf16LeAllocZ(self.app.alloc, self.tabs.items[tab_idx].title) catch {
        _ = SelectObject(mem_dc, old_bmp);
        _ = DeleteObject(bmp);
        _ = DeleteDC(mem_dc);
        return;
    };
    defer self.app.alloc.free(utf16_title);
    var text_rc: RECT = .{ .left = 8, .top = 0, .right = w - 24, .bottom = h };
    // Clamp height so vertical centering isn't thrown off by the selected
    // tab's inflated rcItem (which extends below the visible tab strip).
    const max_text_h = TAB_HEIGHT - 4;
    if (text_rc.bottom - text_rc.top > max_text_h) {
        text_rc.bottom = text_rc.top + max_text_h;
    }

    // Try Direct2D for color emoji support, fall back to GDI
    const title_len: u32 = @intCast(std.mem.indexOfSentinel(u16, 0, utf16_title.ptr));
    if (!drawTextD2D(hdc, utf16_title.ptr, title_len, &text_rc, colorRefToD2D(text_color))) {
        _ = SetBkMode(hdc, TRANSPARENT);
        _ = SetTextColor(hdc, text_color);
        const old_font = SelectObject(hdc, ui_font);
        _ = DrawTextW(hdc, utf16_title.ptr, -1, &text_rc, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        _ = SelectObject(hdc, old_font);
    }

    // Draw close button "x" (always GDI — no emoji needed)
    _ = SetBkMode(hdc, TRANSPARENT);
    const close_text_color: u32 = if (close_hovered) text_color else brighten(bg_color, 60);
    _ = SetTextColor(hdc, close_text_color);
    const old_font = SelectObject(hdc, ui_font);
    close_rc = .{
        .left = w - 20,
        .top = 0,
        .right = w - 2,
        .bottom = h,
    };
    _ = DrawTextW(hdc, std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"), -1, &close_rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    _ = SelectObject(hdc, old_font);

    // Blit completed tab to screen in one operation
    const SRCCOPY: u32 = 0x00CC0020;
    _ = BitBlt(screen_dc, rc.left, rc.top, w, h, mem_dc, 0, 0, SRCCOPY);

    // Cleanup
    _ = SelectObject(mem_dc, old_bmp);
    _ = DeleteObject(bmp);
    _ = DeleteDC(mem_dc);
}

/// Brighten a COLORREF by adding `amount` to each channel (clamped to 255).
fn brighten(color: u32, amount: u32) u32 {
    const r: u32 = @min((color & 0xFF) + amount, 255);
    const g: u32 = @min(((color >> 8) & 0xFF) + amount, 255);
    const b: u32 = @min(((color >> 16) & 0xFF) + amount, 255);
    return (b << 16) | (g << 8) | r;
}

fn drawButton(self: *Window, dis: *const DRAWITEMSTRUCT) void {
    const hdc = dis.hDC orelse return;
    const pressed = (dis.itemState & ODS_SELECTED) != 0;
    const hovered = self.hover_hwnd != null and self.hover_hwnd.? == dis.hwndItem;

    const base_bg = configColorToRef(self.app.config.background);
    const base_unsel = brighten(base_bg, 20);
    const bg_color: u32 = if (pressed) brighten(base_unsel, 30) else if (hovered) brighten(base_unsel, 15) else base_unsel;
    const text_color: u32 = if (pressed or hovered) configColorToRef(self.app.config.foreground) else brighten(base_bg, 100);

    var rc = dis.rcItem;
    const bg_brush = CreateSolidBrush(bg_color);
    if (bg_brush) |brush| {
        _ = FillRect(hdc, &rc, brush);
        _ = DeleteObject(brush);
    }

    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, text_color);
    const old_font = SelectObject(hdc, ui_font);

    const is_new_tab = self.btn_new_tab != null and dis.hwndItem == self.btn_new_tab.?;
    const label = if (is_new_tab)
        std.unicode.utf8ToUtf16LeStringLiteral("+")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("\u{25BC}");

    _ = DrawTextW(hdc, label, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    _ = SelectObject(hdc, old_font);
}

/// Hit-test the current cursor position against the close-button area of
/// each tab. Returns the tab index if the cursor is over an "X", else null.
fn hitTestTabClose(self: *Window) ?usize {
    const tab_hwnd = self.tab_hwnd orelse return null;

    // Get cursor in screen coords, convert to tab control client coords
    var pt: sys.POINT = std.mem.zeroes(sys.POINT);
    _ = GetCursorPos(&pt);
    _ = ScreenToClient(tab_hwnd, &pt);

    var hit: TCHITTESTINFO = .{ .pt = pt };
    const tab_idx_raw = sys.SendMessageW(tab_hwnd, TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
    if (tab_idx_raw < 0) return null;
    const tab_idx: usize = @intCast(tab_idx_raw);

    // Get the tab's bounding rect
    var tab_rect: RECT = std.mem.zeroes(RECT);
    _ = sys.SendMessageW(tab_hwnd, TCM_GETITEMRECT, tab_idx, @bitCast(@intFromPtr(&tab_rect)));

    // Close button occupies the rightmost 20 pixels
    if (pt.x >= tab_rect.right - 20) return tab_idx;
    return null;
}

pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.fullscreen.active) {
        _ = sys.SetWindowLongW(hwnd, sys.GWL_STYLE, self.fullscreen.style);
        _ = sys.SetWindowLongW(hwnd, sys.GWL_EXSTYLE, self.fullscreen.ex_style);
        _ = sys.SetWindowPos(
            hwnd,
            null,
            self.fullscreen.rect.left,
            self.fullscreen.rect.top,
            self.fullscreen.rect.right - self.fullscreen.rect.left,
            self.fullscreen.rect.bottom - self.fullscreen.rect.top,
            0x0020 | 0x0004,
        );
        self.fullscreen.active = false;
    } else {
        self.fullscreen.style = @intCast(sys.GetWindowLongW(hwnd, sys.GWL_STYLE));
        self.fullscreen.ex_style = @intCast(sys.GetWindowLongW(hwnd, sys.GWL_EXSTYLE));
        _ = sys.GetWindowRect(hwnd, &self.fullscreen.rect);

        var mi: sys.MONITORINFO = std.mem.zeroes(sys.MONITORINFO);
        mi.cbSize = @sizeOf(sys.MONITORINFO);
        const monitor = sys.MonitorFromWindow(hwnd, 2);
        if (sys.GetMonitorInfoW(monitor, &mi) == 0) return;

        const new_style = self.fullscreen.style & ~@as(i32, @bitCast(@as(u32, sys.WS_OVERLAPPEDWINDOW)));
        _ = sys.SetWindowLongW(hwnd, sys.GWL_STYLE, new_style);
        _ = sys.SetWindowPos(
            hwnd,
            null,
            mi.rcMonitor.left,
            mi.rcMonitor.top,
            mi.rcMonitor.right - mi.rcMonitor.left,
            mi.rcMonitor.bottom - mi.rcMonitor.top,
            0x0020 | 0x0004,
        );
        self.fullscreen.active = true;
    }
}
