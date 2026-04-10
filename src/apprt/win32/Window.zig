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
const ICC_TAB_CLASSES: DWORD = 0x00000008;
const TAB_HEIGHT: i32 = 30;

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

var ui_font: ?*anyopaque = null;

pub const CreateOptions = struct {
    command: ?configpkg.Command = null,
    working_directory: ?configpkg.WorkingDirectory = null,
    title: ?[:0]const u8 = null,
    quick_terminal: bool = false,

    pub const none: @This() = .{};

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        if (self.command) |cmd| cmd.deinit(alloc);
        if (self.working_directory) |wd| switch (wd) {
            .path => |path| alloc.free(path),
            else => {},
        };
        if (self.title) |title| alloc.free(title);
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
primary_surface: *Surface,
tree: ?SplitTree = null,
focused_surface: ?*Surface = null,
surface_initialized: bool = false,
tabs: std.ArrayListUnmanaged(TabState) = .{},
current_tab: usize = 0,
fullscreen: FullscreenState = .{},
quick_terminal: bool = false,

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
    self.syncActiveTabFromWindow();
    for (self.tabs.items) |*tab| self.deinitTab(tab);
    self.tabs.deinit(self.app.alloc);
    self.tree = null;
    self.surface_initialized = false;
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
        if (title) |v| v.ptr else std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
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
    self.tab_hwnd = sys.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("SysTabControl32"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | TCS_FIXEDWIDTH,
        0,
        0,
        0,
        TAB_HEIGHT,
        self.hwnd,
        null,
        sys.GetModuleHandleW(null),
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

fn updateTabVisibility(self: *Window) void {
    const hwnd = self.tab_hwnd orelse return;
    _ = sys.ShowWindow(hwnd, if (self.tabs.items.len > 1) sys.SW_SHOWNORMAL else SW_HIDE);
    self.updateTabMetrics();
}

fn tabClientHeight(self: *Window) i32 {
    return if (self.tabs.items.len > 1) TAB_HEIGHT else 0;
}

fn tabLeaves(tab: *TabState, buf: []*Surface) []const *Surface {
    const count = tab.tree.collectLeaves(buf);
    return buf[0..count];
}

fn hideTabSurfaces(_: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    for (tabLeaves(tab, &leaves)) |surface| {
        _ = sys.ShowWindow(surface.hwnd, SW_HIDE);
    }
}

fn showTabSurfaces(_: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    for (tabLeaves(tab, &leaves)) |surface| {
        _ = sys.ShowWindow(surface.hwnd, sys.SW_SHOWNORMAL);
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
    if (self.tabs.items.len <= 1) return;

    var rect: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(self.hwnd orelse return, &rect) == 0) return;

    const total_width = rect.right - rect.left;
    if (total_width <= 0) return;

    const tabs_i32: i32 = @intCast(self.tabs.items.len);
    const width = @max(110, @divTrunc(total_width - 24, tabs_i32));
    const size_param: LPARAM = (@as(LPARAM, TAB_HEIGHT) << 16) | @as(LPARAM, @intCast(width & 0xFFFF));
    _ = sys.SendMessageW(hwnd, TCM_SETITEMSIZE, 0, size_param);
    _ = sys.InvalidateRect(hwnd, null, 1);
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
    self.showTabSurfaces(&self.tabs.items[self.current_tab]);
    if (self.tab_hwnd) |hwnd| _ = sys.SendMessageW(hwnd, TCM_SETCURSEL, index, 0);
    self.relayout();
    if (self.focused_surface) |surface| _ = sys.SetFocus(surface.hwnd);
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

    try core.init(alloc, &config, self.app.core_app, self.app, surface);
    errdefer core.deinit();
    surface.core_surface = core;
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
    if (self.tab_hwnd) |tab_hwnd| {
        _ = sys.SetWindowPos(tab_hwnd, null, 0, 0, rect.right - rect.left, tab_h, 0x0004);
    }
    const bounds = SplitTree.Rect{
        .x = 0,
        .y = tab_h,
        .w = rect.right - rect.left,
        .h = rect.bottom - rect.top - tab_h,
    };
    tree.layout(bounds, relayoutCb);
}

fn relayoutCb(surface: *Surface, rect: SplitTree.Rect) void {
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
    _ = wparam;
    switch (msg) {
        WM_NOTIFY => {
            const hdr: *const NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (self.tab_hwnd != null and hdr.hwndFrom == self.tab_hwnd.? and hdr.code == TCN_SELCHANGE) {
                const sel = sys.SendMessageW(self.tab_hwnd.?, TCM_GETCURSEL, 0, 0);
                const idx: usize = @intCast(sel);
                self.activateTab(idx) catch {};
                return 0;
            }
        },
        else => {},
    }
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
