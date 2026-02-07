//! Topic Trie — MQTT topic pattern matching with wildcard support
//!
//! A static-pool trie for O(L) topic matching where L = topic depth.
//! Supports MQTT wildcards:
//!   - `+` matches exactly one topic level
//!   - `#` matches zero or more remaining topic levels (must be last)
//!
//! MQTT spec compliance:
//!   - $ topics only match explicit $ patterns, not + or # at root level
//!
//! ## Usage
//!
//! ```zig
//! const MyTrie = Trie(u16, 256, 16);  // value=u16, 256 nodes, 16 values/node
//! var trie = MyTrie.init();
//!
//! try trie.insert("sensor/+/data", 1);
//! try trie.insert("sensor/#", 2);
//!
//! var result_buf: [16]u16 = undefined;
//! const matches = trie.get("sensor/1/data", &result_buf);
//! // matches = [1, 2]
//! ```

// ============================================================================
// Topic Matching (standalone, no trie needed)
// ============================================================================

/// Check if a subscription pattern matches a topic.
/// Supports MQTT wildcards: + (single level) and # (multi level).
/// MQTT spec: wildcards should not match $ topics unless pattern also starts with $.
pub fn topicMatches(pattern: []const u8, topic: []const u8) bool {
    var p_iter = TopicIterator.init(pattern);
    var t_iter = TopicIterator.init(topic);
    var at_root = true;

    while (true) {
        const p_seg = p_iter.next();
        const t_seg = t_iter.next();

        // Pattern segment is #
        if (p_seg != null and eql(p_seg.?, "#")) {
            // # at root level should not match $ topics
            if (at_root) {
                if (t_seg) |ts| {
                    if (ts.len > 0 and ts[0] == '$') return false;
                }
            }
            return true; // # matches everything remaining
        }

        // Both exhausted → match
        if (p_seg == null and t_seg == null) return true;

        // One exhausted but not the other → no match
        if (p_seg == null or t_seg == null) return false;

        const ps = p_seg.?;
        const ts = t_seg.?;

        // + wildcard
        if (eql(ps, "+")) {
            // + at root level should not match $ topics
            if (at_root and ts.len > 0 and ts[0] == '$') return false;
            at_root = false;
            continue;
        }

        // Exact match
        if (!eql(ps, ts)) return false;
        at_root = false;
    }
}

// ============================================================================
// Trie
// ============================================================================

/// Static-pool topic pattern trie.
///
/// - `T`: value type stored at leaf nodes
/// - `max_nodes`: maximum number of trie nodes
/// - `max_values_per_node`: maximum values stored per node
pub fn Trie(comptime T: type, comptime max_nodes: usize, comptime max_values_per_node: usize) type {
    return struct {
        const Self = @This();

        pub const NodeIndex = enum(u16) {
            none = 0xFFFF,
            _,

            fn val(self: NodeIndex) ?u16 {
                if (self == .none) return null;
                return @intFromEnum(self);
            }
        };

        const Node = struct {
            // Segment stored inline
            segment_buf: [max_segment_len]u8 = undefined,
            segment_len: u8 = 0,

            // Tree links (sibling list for children)
            first_child: NodeIndex = .none,
            next_sibling: NodeIndex = .none,

            // Wildcard children (special)
            match_any: NodeIndex = .none, // + wildcard child
            match_all: NodeIndex = .none, // # wildcard child

            // Values at this node (leaf)
            values: [max_values_per_node]T = undefined,
            value_count: u8 = 0,

            active: bool = false,

            fn segment(self: *const Node) []const u8 {
                return self.segment_buf[0..self.segment_len];
            }

            fn setSegment(self: *Node, seg: []const u8) void {
                const len = @min(seg.len, max_segment_len);
                for (seg[0..len], 0..) |b, i| {
                    self.segment_buf[i] = b;
                }
                self.segment_len = @intCast(len);
            }
        };

        const max_segment_len = 64;

        nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
        node_count: u16 = 0,

        // Root node is always index 0
        pub fn init() Self {
            var self = Self{};
            // Allocate root node
            self.nodes[0].active = true;
            self.node_count = 1;
            return self;
        }

        /// Insert a value at the given pattern.
        /// Pattern is split by '/' into segments.
        pub fn insert(self: *Self, pattern: []const u8, value: T) !void {
            var node_idx: u16 = 0; // Start at root
            var iter = TopicIterator.init(pattern);

            while (iter.next()) |seg| {
                node_idx = try self.getOrCreateChild(node_idx, seg);
            }

            // Add value to the final node
            const node = &self.nodes[node_idx];
            if (node.value_count >= max_values_per_node) return error.TooManyValues;
            node.values[node.value_count] = value;
            node.value_count += 1;
        }

        /// Get all values matching the given topic.
        /// Returns a slice of result_buf filled with matching values.
        pub fn get(self: *Self, topic: []const u8, result_buf: []T) []T {
            var count: usize = 0;
            self.matchNode(0, topic, true, result_buf, &count);
            return result_buf[0..count];
        }

        /// Remove values matching a predicate from the given pattern.
        /// Returns true if any value was removed.
        pub fn remove(self: *Self, pattern: []const u8, predicate: *const fn (T) bool) bool {
            var node_idx: u16 = 0;
            var iter = TopicIterator.init(pattern);

            while (iter.next()) |seg| {
                const child = self.findChild(node_idx, seg);
                if (child == null) return false;
                node_idx = child.?;
            }

            // Remove matching values
            const node = &self.nodes[node_idx];
            var removed = false;
            var write: u8 = 0;
            var read: u8 = 0;
            while (read < node.value_count) : (read += 1) {
                if (predicate(node.values[read])) {
                    removed = true;
                } else {
                    node.values[write] = node.values[read];
                    write += 1;
                }
            }
            node.value_count = write;
            return removed;
        }

        // ================================================================
        // Internal
        // ================================================================

        fn getOrCreateChild(self: *Self, parent_idx: u16, seg: []const u8) !u16 {
            const parent = &self.nodes[parent_idx];

            // Check for wildcard segments
            if (eql(seg, "+")) {
                if (parent.match_any.val()) |idx| return idx;
                const new_idx = try self.allocNode(seg);
                parent.match_any = @enumFromInt(new_idx);
                return new_idx;
            }
            if (eql(seg, "#")) {
                if (parent.match_all.val()) |idx| return idx;
                const new_idx = try self.allocNode(seg);
                parent.match_all = @enumFromInt(new_idx);
                return new_idx;
            }

            // Look for existing child with this segment
            var child_idx = parent.first_child;
            while (child_idx.val()) |idx| {
                const child = &self.nodes[idx];
                if (eql(child.segment(), seg)) return idx;
                child_idx = child.next_sibling;
            }

            // Create new child
            const new_idx = try self.allocNode(seg);
            // Prepend to sibling list
            self.nodes[new_idx].next_sibling = parent.first_child;
            // Re-read parent since allocNode may have invalidated pointer
            self.nodes[parent_idx].first_child = @enumFromInt(new_idx);
            return new_idx;
        }

        fn findChild(self: *Self, parent_idx: u16, seg: []const u8) ?u16 {
            const parent = &self.nodes[parent_idx];

            if (eql(seg, "+")) return parent.match_any.val();
            if (eql(seg, "#")) return parent.match_all.val();

            var child_idx = parent.first_child;
            while (child_idx.val()) |idx| {
                const child = &self.nodes[idx];
                if (eql(child.segment(), seg)) return idx;
                child_idx = child.next_sibling;
            }
            return null;
        }

        fn allocNode(self: *Self, seg: []const u8) !u16 {
            if (self.node_count >= max_nodes) return error.OutOfNodes;
            const idx = self.node_count;
            self.nodes[idx] = .{};
            self.nodes[idx].active = true;
            self.nodes[idx].setSegment(seg);
            self.node_count += 1;
            return idx;
        }

        fn matchNode(self: *Self, node_idx: u16, remaining_topic: []const u8, at_root: bool, result_buf: []T, count: *usize) void {
            const node = &self.nodes[node_idx];

            // Split first segment from remaining topic
            var iter = TopicIterator.init(remaining_topic);
            const first_seg = iter.next();
            const rest = iter.rest();

            // If no more segments, collect values at this node
            if (first_seg == null) {
                self.collectValues(node_idx, result_buf, count);

                // Also check # wildcard child (matches zero remaining levels)
                if (node.match_all.val()) |all_idx| {
                    self.collectValues(all_idx, result_buf, count);
                }
                return;
            }

            const seg = first_seg.?;
            const is_dollar = seg.len > 0 and seg[0] == '$';

            // Try exact match children
            var child_idx = node.first_child;
            while (child_idx.val()) |idx| {
                const child = &self.nodes[idx];
                if (eql(child.segment(), seg)) {
                    self.matchNode(idx, rest, false, result_buf, count);
                }
                child_idx = child.next_sibling;
            }

            // Try + wildcard (skip for $ topics at root level per MQTT spec)
            if (node.match_any.val()) |any_idx| {
                if (!(is_dollar and at_root)) {
                    self.matchNode(any_idx, rest, false, result_buf, count);
                }
            }

            // Try # wildcard (matches this and all remaining levels)
            if (node.match_all.val()) |all_idx| {
                if (!(is_dollar and at_root)) {
                    self.collectValues(all_idx, result_buf, count);
                }
            }
        }

        fn collectValues(self: *Self, node_idx: u16, result_buf: []T, count: *usize) void {
            const node = &self.nodes[node_idx];
            var i: u8 = 0;
            while (i < node.value_count) : (i += 1) {
                if (count.* < result_buf.len) {
                    result_buf[count.*] = node.values[i];
                    count.* += 1;
                }
            }
        }
    };
}

// ============================================================================
// Topic Iterator
// ============================================================================

pub const TopicIterator = struct {
    data: []const u8,
    pos: usize,
    done: bool,

    pub fn init(topic: []const u8) TopicIterator {
        return .{ .data = topic, .pos = 0, .done = topic.len == 0 };
    }

    pub fn next(self: *TopicIterator) ?[]const u8 {
        if (self.done) return null;

        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '/') {
            self.pos += 1;
        }

        const seg = self.data[start..self.pos];

        if (self.pos < self.data.len) {
            self.pos += 1; // skip '/'
        } else {
            self.done = true;
        }

        return seg;
    }

    /// Return the remaining unparsed portion of the topic
    pub fn rest(self: *const TopicIterator) []const u8 {
        if (self.done) return "";
        return self.data[self.pos..];
    }
};

// ============================================================================
// Utility
// ============================================================================

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = struct {
    fn expectTrue(actual: bool) !void {
        if (!actual) return error.TestExpectedEqual;
    }

    fn expectUsize(expected: usize, actual: usize) !void {
        if (expected != actual) return error.TestExpectedEqual;
    }

    fn expectU16(expected: u16, actual: u16) !void {
        if (expected != actual) return error.TestExpectedEqual;
    }

    fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
        if (expected.len != actual.len) return error.TestExpectedEqual;
        for (expected, actual) |e, a| {
            if (e != a) return error.TestExpectedEqual;
        }
    }

    fn containsValue(comptime T: type, haystack: []const T, needle: T) bool {
        for (haystack) |v| {
            if (v == needle) return true;
        }
        return false;
    }
};

// -- topicMatches tests --

test "topicMatches: exact match" {
    try testing.expectTrue(topicMatches("sensor/data", "sensor/data"));
    try testing.expectTrue(!topicMatches("sensor/data", "sensor/other"));
    try testing.expectTrue(!topicMatches("sensor", "sensor/data"));
    try testing.expectTrue(!topicMatches("sensor/data", "sensor"));
}

test "topicMatches: + wildcard" {
    try testing.expectTrue(topicMatches("sensor/+/data", "sensor/1/data"));
    try testing.expectTrue(topicMatches("sensor/+/data", "sensor/abc/data"));
    try testing.expectTrue(!topicMatches("sensor/+/data", "sensor/1/2/data"));
    try testing.expectTrue(topicMatches("+/+/+", "a/b/c"));
    try testing.expectTrue(!topicMatches("+/+", "a/b/c"));
}

test "topicMatches: # wildcard" {
    try testing.expectTrue(topicMatches("sensor/#", "sensor/1/data"));
    try testing.expectTrue(topicMatches("sensor/#", "sensor"));
    try testing.expectTrue(topicMatches("#", "anything/at/all"));
    try testing.expectTrue(topicMatches("#", "single"));
}

test "topicMatches: $ topics not matched by wildcards at root" {
    try testing.expectTrue(!topicMatches("#", "$SYS/broker/clients"));
    try testing.expectTrue(!topicMatches("+/info", "$SYS/info"));
    try testing.expectTrue(topicMatches("$SYS/#", "$SYS/broker/clients"));
    try testing.expectTrue(topicMatches("$SYS/+/clients", "$SYS/broker/clients"));
}

// -- TopicIterator tests --

test "TopicIterator basic" {
    var iter = TopicIterator.init("a/b/c");
    try testing.expectEqualSlices(u8, "a", iter.next().?);
    try testing.expectEqualSlices(u8, "b", iter.next().?);
    try testing.expectEqualSlices(u8, "c", iter.next().?);
    try testing.expectTrue(iter.next() == null);
}

test "TopicIterator single segment" {
    var iter = TopicIterator.init("hello");
    try testing.expectEqualSlices(u8, "hello", iter.next().?);
    try testing.expectTrue(iter.next() == null);
}

test "TopicIterator empty" {
    var iter = TopicIterator.init("");
    try testing.expectTrue(iter.next() == null);
}

// -- Trie tests --

test "Trie: basic insert and get" {
    const MyTrie = Trie(u16, 64, 8);
    var trie = MyTrie.init();

    try trie.insert("sensor/temp", 1);
    try trie.insert("sensor/humidity", 2);

    var buf: [8]u16 = undefined;

    const r1 = trie.get("sensor/temp", &buf);
    try testing.expectUsize(1, r1.len);
    try testing.expectU16(1, r1[0]);

    const r2 = trie.get("sensor/humidity", &buf);
    try testing.expectUsize(1, r2.len);
    try testing.expectU16(2, r2[0]);

    // No match
    const r3 = trie.get("sensor/other", &buf);
    try testing.expectUsize(0, r3.len);
}

test "Trie: + wildcard" {
    const MyTrie = Trie(u16, 64, 8);
    var trie = MyTrie.init();

    try trie.insert("sensor/+/data", 10);
    try trie.insert("sensor/temp", 20);

    var buf: [8]u16 = undefined;

    const r1 = trie.get("sensor/1/data", &buf);
    try testing.expectUsize(1, r1.len);
    try testing.expectU16(10, r1[0]);

    const r2 = trie.get("sensor/abc/data", &buf);
    try testing.expectUsize(1, r2.len);
    try testing.expectU16(10, r2[0]);

    // + should NOT match multiple levels
    const r3 = trie.get("sensor/1/2/data", &buf);
    try testing.expectUsize(0, r3.len);
}

test "Trie: # wildcard" {
    const MyTrie = Trie(u16, 64, 8);
    var trie = MyTrie.init();

    try trie.insert("sensor/#", 100);

    var buf: [8]u16 = undefined;

    const r1 = trie.get("sensor/temp", &buf);
    try testing.expectUsize(1, r1.len);
    try testing.expectU16(100, r1[0]);

    const r2 = trie.get("sensor/1/2/3", &buf);
    try testing.expectUsize(1, r2.len);
    try testing.expectU16(100, r2[0]);

    // # also matches parent level itself
    const r3 = trie.get("sensor", &buf);
    try testing.expectUsize(1, r3.len);
}

test "Trie: multiple matches" {
    const MyTrie = Trie(u16, 64, 8);
    var trie = MyTrie.init();

    try trie.insert("sensor/+/data", 1);
    try trie.insert("sensor/#", 2);
    try trie.insert("sensor/temp/data", 3);

    var buf: [8]u16 = undefined;

    const r = trie.get("sensor/temp/data", &buf);
    try testing.expectUsize(3, r.len);
    try testing.expectTrue(testing.containsValue(u16, r, 1));
    try testing.expectTrue(testing.containsValue(u16, r, 2));
    try testing.expectTrue(testing.containsValue(u16, r, 3));
}

test "Trie: $ topic protection" {
    const MyTrie = Trie(u16, 64, 8);
    var trie = MyTrie.init();

    try trie.insert("#", 1);
    try trie.insert("+/info", 2);
    try trie.insert("$SYS/#", 3);

    var buf: [8]u16 = undefined;

    // # and + at root should NOT match $ topics
    const r1 = trie.get("$SYS/broker", &buf);
    try testing.expectUsize(1, r1.len);
    try testing.expectU16(3, r1[0]);

    // Normal topics SHOULD match # and +
    const r2 = trie.get("normal/info", &buf);
    try testing.expectTrue(r2.len >= 1);
}

test "Trie: remove" {
    const MyTrie = Trie(u16, 64, 8);
    var trie = MyTrie.init();

    try trie.insert("sensor/data", 1);
    try trie.insert("sensor/data", 2);
    try trie.insert("sensor/data", 3);

    // Remove value 2
    const removed = trie.remove("sensor/data", struct {
        fn pred(v: u16) bool {
            return v == 2;
        }
    }.pred);
    try testing.expectTrue(removed);

    var buf: [8]u16 = undefined;
    const r = trie.get("sensor/data", &buf);
    try testing.expectUsize(2, r.len);
    try testing.expectTrue(testing.containsValue(u16, r, 1));
    try testing.expectTrue(testing.containsValue(u16, r, 3));
    try testing.expectTrue(!testing.containsValue(u16, r, 2));
}

test "Trie: multiple subscribers same pattern" {
    const MyTrie = Trie(u16, 64, 8);
    var trie = MyTrie.init();

    try trie.insert("room/+/temp", 100);
    try trie.insert("room/+/temp", 200);

    var buf: [8]u16 = undefined;
    const r = trie.get("room/living/temp", &buf);
    try testing.expectUsize(2, r.len);
}
