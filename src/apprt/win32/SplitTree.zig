//! Binary split tree for managing multiple Surfaces within a single window.
//!
//! Each leaf in the tree holds a *Surface, and each internal node is either
//! a horizontal or vertical split with two children and a split ratio.
const SplitTree = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");

pub const Direction = enum { horizontal, vertical };

pub const Node = union(enum) {
    leaf: *Surface,
    split: struct {
        direction: Direction,
        ratio: f32 = 0.5,
        children: [2]*Node,
    },
};

/// Root node of the tree.
root: *Node,

pub fn initLeaf(alloc: Allocator, surface: *Surface) !SplitTree {
    const node = try alloc.create(Node);
    node.* = .{ .leaf = surface };
    return .{ .root = node };
}

pub fn deinit(self: *SplitTree, alloc: Allocator) void {
    destroyNode(alloc, self.root);
}

fn destroyNode(alloc: Allocator, node: *Node) void {
    switch (node.*) {
        .leaf => {},
        .split => |sp| {
            destroyNode(alloc, sp.children[0]);
            destroyNode(alloc, sp.children[1]);
        },
    }
    alloc.destroy(node);
}

/// Find the leaf node containing the given surface and its parent pointer.
const FindResult = struct {
    /// Pointer to the slot in the parent that holds the leaf (or root).
    slot: **Node,
    /// The containing split node, or null if the leaf is the root.
    parent: ?*Node,
};

pub fn findLeaf(self: *SplitTree, surface: *Surface) ?FindResult {
    return findLeafIn(&self.root, null, surface);
}

fn findLeafIn(slot: **Node, parent: ?*Node, surface: *Surface) ?FindResult {
    const node = slot.*;
    switch (node.*) {
        .leaf => |s| if (s == surface) return .{ .slot = slot, .parent = parent } else return null,
        .split => |*sp| {
            if (findLeafIn(&sp.children[0], node, surface)) |r| return r;
            if (findLeafIn(&sp.children[1], node, surface)) |r| return r;
            return null;
        },
    }
}

/// Split the leaf containing `existing` by inserting `new` as a sibling
/// in the given direction.
pub fn split(
    self: *SplitTree,
    alloc: Allocator,
    existing: *Surface,
    new: *Surface,
    direction: Direction,
    /// If true, the new surface is placed after the existing one
    /// (right/down); otherwise before (left/up).
    after: bool,
) !void {
    const result = self.findLeaf(existing) orelse return error.SurfaceNotFound;

    const old_node = result.slot.*;
    const new_leaf = try alloc.create(Node);
    errdefer alloc.destroy(new_leaf);
    new_leaf.* = .{ .leaf = new };

    const split_node = try alloc.create(Node);
    errdefer alloc.destroy(split_node);
    split_node.* = .{
        .split = .{
            .direction = direction,
            .ratio = 0.5,
            .children = if (after) .{ old_node, new_leaf } else .{ new_leaf, old_node },
        },
    };

    result.slot.* = split_node;
}

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Compute the rect for each leaf surface by recursively applying the
/// tree layout within the given bounds.
pub fn layout(self: *SplitTree, bounds: Rect, cb: *const fn (surface: *Surface, rect: Rect) void) void {
    layoutNode(self.root, bounds, cb);
}

fn layoutNode(node: *Node, bounds: Rect, cb: *const fn (surface: *Surface, rect: Rect) void) void {
    switch (node.*) {
        .leaf => |s| cb(s, bounds),
        .split => |sp| {
            const ratio = sp.ratio;
            switch (sp.direction) {
                .horizontal => {
                    const w1: i32 = @intFromFloat(@as(f32, @floatFromInt(bounds.w)) * ratio);
                    const w2 = bounds.w - w1;
                    layoutNode(sp.children[0], .{ .x = bounds.x, .y = bounds.y, .w = w1, .h = bounds.h }, cb);
                    layoutNode(sp.children[1], .{ .x = bounds.x + w1, .y = bounds.y, .w = w2, .h = bounds.h }, cb);
                },
                .vertical => {
                    const h1: i32 = @intFromFloat(@as(f32, @floatFromInt(bounds.h)) * ratio);
                    const h2 = bounds.h - h1;
                    layoutNode(sp.children[0], .{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = h1 }, cb);
                    layoutNode(sp.children[1], .{ .x = bounds.x, .y = bounds.y + h1, .w = bounds.w, .h = h2 }, cb);
                },
            }
        },
    }
}

/// Remove the leaf containing the given surface. The sibling is promoted
/// to replace the parent split node. Returns true if the tree is now empty.
pub fn removeLeaf(self: *SplitTree, alloc: Allocator, surface: *Surface) bool {
    const result = self.findLeaf(surface) orelse return false;

    // If the leaf is the root, the tree becomes empty.
    if (result.parent == null) {
        alloc.destroy(result.slot.*);
        return true;
    }

    // Find which child of the parent we are, promote the sibling.
    const parent = result.parent.?;
    const parent_split = &parent.split;
    const leaf_node = result.slot.*;
    const sibling = if (parent_split.children[0] == leaf_node)
        parent_split.children[1]
    else
        parent_split.children[0];

    // The parent becomes the sibling (copy contents).
    alloc.destroy(leaf_node);
    parent.* = sibling.*;
    alloc.destroy(sibling);

    return false;
}

/// Collect all leaf surfaces into the given buffer, returning the count.
pub fn collectLeaves(self: *SplitTree, buf: []*Surface) usize {
    var i: usize = 0;
    collectLeavesIn(self.root, buf, &i);
    return i;
}

fn collectLeavesIn(node: *Node, buf: []*Surface, i: *usize) void {
    switch (node.*) {
        .leaf => |s| {
            if (i.* < buf.len) {
                buf[i.*] = s;
                i.* += 1;
            }
        },
        .split => |sp| {
            collectLeavesIn(sp.children[0], buf, i);
            collectLeavesIn(sp.children[1], buf, i);
        },
    }
}
