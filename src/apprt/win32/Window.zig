//! A single top-level Win32 window. Each Window owns one HWND, one primary
//! Surface (embedded in the child HWND), and a SplitTree that can manage
//! additional Surfaces for split panes.
//!
//! An App may own multiple Windows.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("SplitTree.zig");
const sys = @import("sys.zig");

const App = @import("App.zig");

const log = std.log.scoped(.win32_window);

const HWND = sys.HWND;
const RECT = sys.RECT;
const BOOL = sys.BOOL;
const UINT = sys.UINT;
const DWORD = sys.DWORD;

pub const CreateOptions = struct {
    command: ?configpkg.Command = null,
    working_directory: ?configpkg.WorkingDirectory = null,
    title: ?[:0]const u8 = null,

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

/// Back-pointer to the owning App.
app: *App,

/// The top-level window handle.
hwnd: ?HWND = null,

/// The primary (first) surface created with this window. Additional surfaces
/// live in the split tree. All surfaces are heap-allocated.
primary_surface: *Surface,

/// Split tree managing all surfaces within this window.
tree: ?SplitTree = null,

/// The surface that currently has focus within this window.
focused_surface: ?*Surface = null,

/// Whether the primary surface has been initialized yet.
surface_initialized: bool = false,

/// Fullscreen state (for restoring from fullscreen).
fullscreen: FullscreenState = .{},

const FullscreenState = struct {
    active: bool = false,
    style: i32 = 0,
    ex_style: i32 = 0,
    rect: RECT = std.mem.zeroes(RECT),
};

/// Allocate and initialize a new Window. The caller owns the returned pointer.
pub fn create(alloc: Allocator, app: *App, opts: CreateOptions) !*Window {
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    const primary = try alloc.create(Surface);
    errdefer alloc.destroy(primary);
    primary.* = .{ .hwnd = undefined };

    self.* = .{
        .app = app,
        .primary_surface = primary,
    };

    // Create the top-level window
    try self.createHwnd(opts.title);
    errdefer {
        if (self.hwnd) |h| {
            _ = sys.DestroyWindow(h);
        }
    }

    // Initialize the primary surface (creates a child HWND with WGL context)
    try primary.init(self.hwnd.?, app);
    primary.window = self;
    self.surface_initialized = true;

    // Set back-pointer from the HWND so the wndProc can find us
    _ = sys.SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Initialize split tree with primary surface as root leaf
    self.tree = try SplitTree.initLeaf(alloc, primary);
    self.focused_surface = primary;

    // Initialize the CoreSurface for the primary surface
    try self.initCoreSurface(primary, opts);

    // Resize window to configured grid size and apply layout
    self.applyConfiguredWindowSize();
    self.relayout();

    // Focus the primary surface
    _ = sys.SetFocus(primary.hwnd);

    // Apply initial color scheme
    if (primary.core_surface) |core| {
        core.colorSchemeCallback(app.detectColorScheme()) catch {};
    }

    return self;
}

/// Deinitialize this window and all its surfaces. Does not free `self`.
pub fn deinit(self: *Window) void {
    if (self.tree) |*tree| {
        var buf: [32]*Surface = undefined;
        const count = tree.collectLeaves(&buf);
        for (buf[0..count]) |s| {
            if (s.core_surface) |core| {
                core.deinit();
                self.app.alloc.destroy(core);
                s.core_surface = null;
            }
            s.deinit();
            self.app.alloc.destroy(s);
        }
        tree.deinit(self.app.alloc);
        self.tree = null;
    }
    if (self.hwnd) |hwnd| {
        _ = sys.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

fn createHwnd(self: *Window, title_override: ?[:0]const u8) !void {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
    const hinstance = sys.GetModuleHandleW(null);

    // Register the window class (idempotent across windows — only first call succeeds)
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
    _ = sys.RegisterClassExW(&wc); // Ignore duplicate registrations

    const title = if (title_override) |title_utf8|
        try std.unicode.utf8ToUtf16LeAllocZ(self.app.alloc, title_utf8)
    else
        null;
    defer if (title) |v| self.app.alloc.free(v);
    self.hwnd = sys.CreateWindowExW(
        0,
        class_name,
        if (title) |v| v.ptr else std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        sys.WS_OVERLAPPEDWINDOW,
        sys.CW_USEDEFAULT,
        sys.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    );

    if (self.hwnd == null) return error.Win32Error;
    _ = sys.ShowWindow(self.hwnd.?, sys.SW_SHOWNORMAL);
    _ = sys.UpdateWindow(self.hwnd.?);
}

pub fn initCoreSurface(self: *Window, surface: *Surface, opts: CreateOptions) !void {
    const alloc = self.app.alloc;
    const core = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core);

    try self.app.core_app.addSurface(surface);
    errdefer self.app.core_app.deleteSurface(surface);

    var config = try apprt.surface.newConfig(self.app.core_app, self.app.config, .window);
    defer config.deinit();

    if (opts.command) |cmd| {
        config.command = try cmd.clone(alloc);
    }
    if (opts.working_directory) |wd| {
        config.@"working-directory" = try wd.clone(alloc);
    }
    if (opts.title) |title| {
        config.title = try alloc.dupeZ(u8, title);
    }

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
    const h: i32 = @intCast(@max(4, cfg_h) * cell_height);

    var rect: RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    _ = sys.AdjustWindowRectEx(&rect, sys.WS_OVERLAPPEDWINDOW, 0, 0);
    _ = sys.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, 0x0002 | 0x0004);
}

pub fn relayout(self: *Window) void {
    const tree = &(self.tree orelse return);
    const hwnd = self.hwnd orelse return;
    var rect: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(hwnd, &rect) == 0) return;
    const bounds = SplitTree.Rect{
        .x = 0,
        .y = 0,
        .w = rect.right - rect.left,
        .h = rect.bottom - rect.top,
    };
    tree.layout(bounds, relayoutCb);
}

fn relayoutCb(surface: *Surface, rect: SplitTree.Rect) void {
    _ = sys.SetWindowPos(surface.hwnd, null, rect.x, rect.y, rect.w, rect.h, 0x0004);
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
    _ = sys.SetFocus(new_surface.hwnd);
    self.relayout();
}

/// Remove a surface from this window. If it was the last one, the window
/// is closed (which may close the app if it was the last window).
pub fn closeSurface(self: *Window, surface: *Surface) void {
    const tree = &(self.tree orelse return);
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
        // Last surface closed in this window -> close the window
        self.tree = null;
        self.surface_initialized = false;
        self.app.closeWindow(self);
        return;
    }

    if (result.focus) |new_focus| {
        self.focused_surface = new_focus;
        _ = sys.SetFocus(new_focus.hwnd);
    } else {
        self.focused_surface = null;
    }

    self.relayout();
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
        .y = 0,
        .w = cr.right - cr.left,
        .h = cr.bottom - cr.top,
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
        .leaf => |s| {
            if (s == target) return true;
        },
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
