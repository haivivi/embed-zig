//! MQTT Topic Trie — pattern matching with + and # wildcards
//!
//! Thread-safety is NOT provided here — the Mux wraps with a lock.
//! Uses std.mem.Allocator for dynamic node allocation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidTopic,
    OutOfMemory,
};

pub fn Trie(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            children: std.StringHashMap(*Node),
            match_any: ?*Node, // + wildcard
            match_all: ?*Node, // # wildcard
            values: std.ArrayListUnmanaged(T),
            allocator: Allocator,

            fn init(allocator: Allocator) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .children = std.StringHashMap(*Node).init(allocator),
                    .match_any = null,
                    .match_all = null,
                    .values = .empty,
                    .allocator = allocator,
                };
                return node;
            }

            fn deinit(self: *Node) void {
                var it = self.children.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit();
                    self.allocator.destroy(entry.value_ptr.*);
                }
                self.children.deinit();
                if (self.match_any) |n| {
                    n.deinit();
                    self.allocator.destroy(n);
                }
                if (self.match_all) |n| {
                    n.deinit();
                    self.allocator.destroy(n);
                }
                self.values.deinit(self.allocator);
            }
        };

        root: *Node,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {
            return .{
                .root = try Node.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.root.deinit();
            self.allocator.destroy(self.root);
        }

        /// Insert a value at the given topic pattern.
        pub fn insert(self: *Self, pattern: []const u8, value: T) !void {
            try self.insertAt(self.root, pattern, value);
        }

        /// Get all values matching a concrete topic (first match only, legacy).
        pub fn get(self: *const Self, topic: []const u8) []const T {
            return self.match(topic) orelse &.{};
        }

        /// Match returns the first matching node's values (legacy, single pattern).
        pub fn match(self: *const Self, topic: []const u8) ?[]const T {
            return matchNode(self.root, topic);
        }

        /// Collect ALL values from all matching patterns into result buffer.
        /// Returns the number of values written. Handles overlapping subscriptions
        /// (e.g., topic "a/b" matching both "a/+" and "a/#").
        pub fn matchAll(self: *const Self, topic: []const u8, result: []T) usize {
            var count: usize = 0;
            collectAll(self.root, topic, result, &count);
            return count;
        }

        /// Remove values matching predicate from a pattern.
        pub fn remove(self: *Self, pattern: []const u8, predicate: *const fn (T) bool) bool {
            return removeAt(self.root, pattern, predicate);
        }

        /// Remove values matching a contextual predicate (supports pointer comparison).
        pub fn removeCtx(
            self: *Self,
            pattern: []const u8,
            ctx: *anyopaque,
            predicate: *const fn (*anyopaque, T) bool,
        ) bool {
            return removeAtCtx(self.root, pattern, ctx, predicate);
        }

        /// Remove a specific value by equality (pointer comparison for pointer types).
        pub fn removeValue(self: *Self, pattern: []const u8, value: T) bool {
            return self.removeCtx(pattern, @ptrCast(@constCast(&value)), struct {
                fn pred(raw_ctx: *anyopaque, v: T) bool {
                    const expected: *const T = @ptrCast(@alignCast(raw_ctx));
                    return v == expected.*;
                }
            }.pred);
        }

        // ====================================================================
        // Private
        // ====================================================================

        fn insertAt(self: *Self, node: *Node, pattern: []const u8, value: T) !void {
            if (pattern.len == 0) {
                try node.values.append(self.allocator, value);
                return;
            }

            const sep = std.mem.indexOfScalar(u8, pattern, '/');
            const first = if (sep) |s| pattern[0..s] else pattern;
            const rest = if (sep) |s| pattern[s + 1 ..] else "";

            // Handle $share and $queue prefixes
            if (std.mem.eql(u8, first, "$share")) {
                // $share/<group>/<topic> — skip group, insert on actual topic
                const rest2 = rest;
                const sep2 = std.mem.indexOfScalar(u8, rest2, '/');
                if (sep2) |s2| {
                    const actual_topic = rest2[s2 + 1 ..];
                    try self.insertAt(node, actual_topic, value);
                    return;
                }
                return Error.InvalidTopic;
            }

            if (std.mem.eql(u8, first, "+")) {
                if (node.match_any == null) node.match_any = try Node.init(self.allocator);
                try self.insertAt(node.match_any.?, rest, value);
            } else if (std.mem.eql(u8, first, "#")) {
                if (rest.len != 0) return Error.InvalidTopic;
                if (node.match_all == null) node.match_all = try Node.init(self.allocator);
                try node.match_all.?.values.append(self.allocator, value);
            } else {
                // Check existing children
                if (node.children.get(first)) |child| {
                    try self.insertAt(child, rest, value);
                } else {
                    const child = try Node.init(self.allocator);
                    const key_dup = self.allocator.dupe(u8, first) catch |e| {
                        child.deinit();
                        self.allocator.destroy(child);
                        return e;
                    };
                    node.children.put(key_dup, child) catch |e| {
                        self.allocator.free(key_dup);
                        child.deinit();
                        self.allocator.destroy(child);
                        return e;
                    };
                    // child is now owned by children map — no errdefer needed
                    try self.insertAt(child, rest, value);
                }
            }
        }

        fn removeAtCtx(node: *Node, pattern: []const u8, ctx: *anyopaque, predicate: *const fn (*anyopaque, T) bool) bool {
            if (pattern.len == 0) {
                const before = node.values.items.len;
                var i: usize = 0;
                while (i < node.values.items.len) {
                    if (predicate(ctx, node.values.items[i])) {
                        _ = node.values.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
                return node.values.items.len < before;
            }
            const sep = std.mem.indexOfScalar(u8, pattern, '/');
            const first = if (sep) |s| pattern[0..s] else pattern;
            const rest = if (sep) |s| pattern[s + 1 ..] else "";
            if (std.mem.eql(u8, first, "+")) {
                if (node.match_any) |child| return removeAtCtx(child, rest, ctx, predicate);
            } else if (std.mem.eql(u8, first, "#")) {
                if (node.match_all) |child| {
                    const before = child.values.items.len;
                    var i: usize = 0;
                    while (i < child.values.items.len) {
                        if (predicate(ctx, child.values.items[i])) {
                            _ = child.values.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                    return child.values.items.len < before;
                }
            } else {
                if (node.children.get(first)) |child| return removeAtCtx(child, rest, ctx, predicate);
            }
            return false;
        }

        fn removeAt(node: *Node, pattern: []const u8, predicate: *const fn (T) bool) bool {
            if (pattern.len == 0) {
                const before = node.values.items.len;
                var i: usize = 0;
                while (i < node.values.items.len) {
                    if (predicate(node.values.items[i])) {
                        _ = node.values.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
                return node.values.items.len < before;
            }

            const sep = std.mem.indexOfScalar(u8, pattern, '/');
            const first = if (sep) |s| pattern[0..s] else pattern;
            const rest = if (sep) |s| pattern[s + 1 ..] else "";

            if (std.mem.eql(u8, first, "+")) {
                if (node.match_any) |child| return removeAt(child, rest, predicate);
            } else if (std.mem.eql(u8, first, "#")) {
                if (node.match_all) |child| {
                    const before = child.values.items.len;
                    var i: usize = 0;
                    while (i < child.values.items.len) {
                        if (predicate(child.values.items[i])) {
                            _ = child.values.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                    return child.values.items.len < before;
                }
            } else {
                if (node.children.get(first)) |child| return removeAt(child, rest, predicate);
            }
            return false;
        }

        fn matchNode(node: *const Node, topic: []const u8) ?[]const T {
            const sep = std.mem.indexOfScalar(u8, topic, '/');
            const first = if (sep) |s| topic[0..s] else topic;
            const rest = if (sep) |s| topic[s + 1 ..] else "";
            const at_end = rest.len == 0 and sep == null;

            // Try exact match first
            if (node.children.get(first)) |child| {
                if (at_end) {
                    if (child.values.items.len > 0) return child.values.items;
                } else {
                    if (matchNode(child, rest)) |vals| return vals;
                }
            }

            // Try single-level wildcard (+)
            if (node.match_any) |child| {
                if (at_end) {
                    if (child.values.items.len > 0) return child.values.items;
                } else {
                    if (matchNode(child, rest)) |vals| return vals;
                }
            }

            // Try multi-level wildcard (#)
            if (node.match_all) |child| {
                if (child.values.items.len > 0) return child.values.items;
            }

            return null;
        }

        /// Collect values from ALL matching patterns (not just first).
        fn collectAll(node: *const Node, topic: []const u8, result: []T, count: *usize) void {
            const sep = std.mem.indexOfScalar(u8, topic, '/');
            const first = if (sep) |s| topic[0..s] else topic;
            const rest = if (sep) |s| topic[s + 1 ..] else "";
            const at_end = rest.len == 0 and sep == null;

            // Exact match
            if (node.children.get(first)) |child| {
                if (at_end) {
                    appendValues(child, result, count);
                } else {
                    collectAll(child, rest, result, count);
                }
            }

            // Single-level wildcard (+) — also try
            if (node.match_any) |child| {
                if (at_end) {
                    appendValues(child, result, count);
                } else {
                    collectAll(child, rest, result, count);
                }
            }

            // Multi-level wildcard (#) — always matches remaining
            if (node.match_all) |child| {
                appendValues(child, result, count);
            }
        }

        fn appendValues(node: *const Node, result: []T, count: *usize) void {
            for (node.values.items) |v| {
                if (count.* < result.len) {
                    result[count.*] = v;
                    count.* += 1;
                }
            }
        }
    };
}

// ============================================================================
// Standalone topic matching (for Broker routing)
// ============================================================================

/// Check if a subscription pattern matches a topic.
/// Supports MQTT wildcards: + (single level) and # (multi level).
pub fn topicMatches(pattern: []const u8, topic: []const u8) bool {
    var pat_pos: usize = 0;
    var top_pos: usize = 0;

    while (true) {
        const pat_seg = nextSegment(pattern, pat_pos);
        const top_seg = nextSegment(topic, top_pos);

        if (pat_seg == null and top_seg == null) return true;

        if (pat_seg) |ps| {
            if (top_seg == null) {
                // # at end matches zero remaining levels
                if (std.mem.eql(u8, ps.seg, "#")) return true;
                return false;
            }
            const ts = top_seg.?;

            // MQTT spec: wildcards should not match $ topics at root level
            if (pat_pos == 0 and ts.seg.len > 0 and ts.seg[0] == '$') {
                if (std.mem.eql(u8, ps.seg, "+") or std.mem.eql(u8, ps.seg, "#")) return false;
            }

            // # matches everything remaining
            if (std.mem.eql(u8, ps.seg, "#")) return true;

            if (std.mem.eql(u8, ps.seg, "+")) {
                // + matches exactly one level
                pat_pos = ps.next;
                top_pos = ts.next;
                continue;
            }

            if (std.mem.eql(u8, ps.seg, ts.seg)) {
                pat_pos = ps.next;
                top_pos = ts.next;
                continue;
            }

            return false;
        }

        return false;
    }
}

const Segment = struct { seg: []const u8, next: usize };

fn nextSegment(s: []const u8, pos: usize) ?Segment {
    if (pos >= s.len) return null;
    const rest = s[pos..];
    const sep = std.mem.indexOfScalar(u8, rest, '/');
    if (sep) |idx| {
        return .{ .seg = rest[0..idx], .next = pos + idx + 1 };
    }
    return .{ .seg = rest, .next = s.len };
}

// ============================================================================
// Tests
// ============================================================================

test "topicMatches exact" {
    try std.testing.expect(topicMatches("a/b/c", "a/b/c"));
    try std.testing.expect(!topicMatches("a/b/c", "a/b/d"));
    try std.testing.expect(!topicMatches("a/b", "a/b/c"));
}

test "topicMatches single-level wildcard" {
    try std.testing.expect(topicMatches("a/+/c", "a/b/c"));
    try std.testing.expect(topicMatches("a/+/c", "a/x/c"));
    try std.testing.expect(!topicMatches("a/+/c", "a/b/d"));
    try std.testing.expect(!topicMatches("a/+/c", "a/b/c/d"));
}

test "topicMatches multi-level wildcard" {
    try std.testing.expect(topicMatches("a/#", "a/b"));
    try std.testing.expect(topicMatches("a/#", "a/b/c"));
    try std.testing.expect(topicMatches("a/#", "a/b/c/d"));
    try std.testing.expect(!topicMatches("a/#", "b/c"));
}

test "topicMatches dollar topics" {
    try std.testing.expect(!topicMatches("+/info", "$SYS/info"));
    try std.testing.expect(!topicMatches("#", "$SYS/info"));
    try std.testing.expect(topicMatches("$SYS/info", "$SYS/info"));
    try std.testing.expect(topicMatches("$SYS/#", "$SYS/info"));
}

test "Trie basic insert and match" {
    var trie = try Trie([]const u8).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("device/001/state", "handler1");
    const result = trie.match("device/001/state");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqualStrings("handler1", result.?[0]);

    // No match
    try std.testing.expect(trie.match("device/002/state") == null);
}

test "Trie wildcard +" {
    var trie = try Trie([]const u8).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("device/+/state", "wild");
    try std.testing.expect(trie.match("device/001/state") != null);
    try std.testing.expect(trie.match("device/abc/state") != null);
    try std.testing.expect(trie.match("device/001/cmd") == null);
}

test "Trie wildcard #" {
    var trie = try Trie([]const u8).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("device/#", "multi");
    try std.testing.expect(trie.match("device/001") != null);
    try std.testing.expect(trie.match("device/001/state") != null);
    try std.testing.expect(trie.match("other/001") == null);
}

test "Trie # must be last" {
    var trie = try Trie([]const u8).init(std.testing.allocator);
    defer trie.deinit();

    try std.testing.expectError(Error.InvalidTopic, trie.insert("device/#/state", "bad"));
}

test "Trie matchAll overlapping patterns" {
    var trie = try Trie([]const u8).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("device/+/state", "handler-plus");
    try trie.insert("device/#", "handler-hash");

    // "device/001/state" should match BOTH patterns
    var result: [8][]const u8 = undefined;
    const count = trie.matchAll("device/001/state", &result);
    try std.testing.expectEqual(@as(usize, 2), count);

    // "device/001" should match only "device/#"
    const count2 = trie.matchAll("device/001", &result);
    try std.testing.expectEqual(@as(usize, 1), count2);
    try std.testing.expectEqualStrings("handler-hash", result[0]);

    // "other/001" should match nothing
    const count3 = trie.matchAll("other/001", &result);
    try std.testing.expectEqual(@as(usize, 0), count3);
}
