//! Dirty Rectangle Tracker
//!
//! Tracks rectangular regions that need to be flushed to the display.
//! Each drawing operation marks a dirty rect. At flush time, the
//! accumulated rects are used for partial display updates.
//!
//! When the tracker is full, existing rects are merged into a
//! bounding box to make room. This degrades gracefully — worst
//! case is a full-screen flush.

/// Axis-aligned rectangle.
pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    /// Check if two rectangles overlap.
    pub fn intersects(self: Rect, other: Rect) bool {
        if (self.w == 0 or self.h == 0 or other.w == 0 or other.h == 0) return false;
        const a_right = self.x + self.w;
        const a_bottom = self.y + self.h;
        const b_right = other.x + other.w;
        const b_bottom = other.y + other.h;
        return self.x < b_right and other.x < a_right and
            self.y < b_bottom and other.y < a_bottom;
    }

    /// Return the bounding box that contains both rectangles.
    pub fn merge(self: Rect, other: Rect) Rect {
        if (self.w == 0 or self.h == 0) return other;
        if (other.w == 0 or other.h == 0) return self;

        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const max_x = @max(self.x + self.w, other.x + other.w);
        const max_y = @max(self.y + self.h, other.y + other.h);
        return .{
            .x = min_x,
            .y = min_y,
            .w = max_x - min_x,
            .h = max_y - min_y,
        };
    }

    /// Area in pixels.
    pub fn area(self: Rect) u32 {
        return @as(u32, self.w) * @as(u32, self.h);
    }

    pub fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and
            self.w == other.w and self.h == other.h;
    }
};

/// Tracks up to `MAX` dirty rectangles.
///
/// When full, merges all existing rects into one bounding box
/// to make room. This ensures mark() never fails.
pub fn DirtyTracker(comptime MAX: u8) type {
    return struct {
        const Self = @This();

        rects: [MAX]Rect = undefined,
        count: u8 = 0,

        pub fn init() Self {
            return .{};
        }

        /// Mark a rectangular region as dirty.
        ///
        /// If the tracker is full, all existing rects are merged
        /// into a single bounding box first.
        pub fn mark(self: *Self, rect: Rect) void {
            if (rect.w == 0 or rect.h == 0) return;

            // Try to merge with an existing overlapping rect
            for (self.rects[0..self.count]) |*existing| {
                if (existing.intersects(rect)) {
                    existing.* = existing.merge(rect);
                    return;
                }
            }

            // Full? Collapse all into one bounding box, then add
            if (self.count >= MAX) {
                self.collapse();
            }

            self.rects[self.count] = rect;
            self.count += 1;
        }

        /// Mark the entire screen as dirty.
        pub fn markAll(self: *Self, w: u16, h: u16) void {
            self.count = 1;
            self.rects[0] = .{ .x = 0, .y = 0, .w = w, .h = h };
        }

        /// Get the current dirty regions.
        pub fn get(self: *const Self) []const Rect {
            return self.rects[0..self.count];
        }

        /// Clear all dirty regions (call after display flush).
        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        /// Check if any region is dirty.
        pub fn isDirty(self: *const Self) bool {
            return self.count > 0;
        }

        /// Collapse all rects into a single bounding box.
        fn collapse(self: *Self) void {
            if (self.count <= 1) return;
            var merged = self.rects[0];
            for (self.rects[1..self.count]) |r| {
                merged = merged.merge(r);
            }
            self.rects[0] = merged;
            self.count = 1;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "Rect.intersects: overlapping" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try testing.expect(a.intersects(b));
    try testing.expect(b.intersects(a));
}

test "Rect.intersects: adjacent (no overlap)" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 10, .y = 0, .w = 10, .h = 10 };
    try testing.expect(!a.intersects(b));
}

test "Rect.intersects: zero-size" {
    const a = Rect{ .x = 5, .y = 5, .w = 0, .h = 10 };
    const b = Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };
    try testing.expect(!a.intersects(b));
}

test "Rect.merge: bounding box" {
    const a = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    const b = Rect{ .x = 5, .y = 50, .w = 10, .h = 20 };
    const m = a.merge(b);
    try testing.expectEqual(@as(u16, 5), m.x);
    try testing.expectEqual(@as(u16, 20), m.y);
    try testing.expectEqual(@as(u16, 35), m.w); // max_x=40, min_x=5 → 35
    try testing.expectEqual(@as(u16, 50), m.h); // max_y=70, min_y=20 → 50
}

test "Rect.merge: with zero-size returns other" {
    const zero = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const real = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try testing.expect(zero.merge(real).eql(real));
    try testing.expect(real.merge(zero).eql(real));
}

test "DirtyTracker: mark and get" {
    var dt = DirtyTracker(4).init();
    try testing.expect(!dt.isDirty());

    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try testing.expect(dt.isDirty());
    try testing.expectEqual(@as(u8, 1), dt.count);

    dt.mark(.{ .x = 100, .y = 100, .w = 20, .h = 20 });
    try testing.expectEqual(@as(u8, 2), dt.count);
}

test "DirtyTracker: overlapping rects merge automatically" {
    var dt = DirtyTracker(4).init();
    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    dt.mark(.{ .x = 5, .y = 5, .w = 10, .h = 10 }); // overlaps → merge
    try testing.expectEqual(@as(u8, 1), dt.count);

    const r = dt.get()[0];
    try testing.expectEqual(@as(u16, 0), r.x);
    try testing.expectEqual(@as(u16, 0), r.y);
    try testing.expectEqual(@as(u16, 15), r.w);
    try testing.expectEqual(@as(u16, 15), r.h);
}

test "DirtyTracker: collapse when full" {
    var dt = DirtyTracker(2).init();
    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    dt.mark(.{ .x = 50, .y = 50, .w = 10, .h = 10 });
    // Now full (2/2). Next mark triggers collapse.
    dt.mark(.{ .x = 200, .y = 200, .w = 5, .h = 5 });

    // After collapse: old 2 merged into 1 bounding box, then new one added
    try testing.expectEqual(@as(u8, 2), dt.count);
}

test "DirtyTracker: markAll resets to single full-screen rect" {
    var dt = DirtyTracker(4).init();
    dt.mark(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    dt.mark(.{ .x = 100, .y = 100, .w = 5, .h = 5 });
    dt.markAll(240, 240);

    try testing.expectEqual(@as(u8, 1), dt.count);
    const r = dt.get()[0];
    try testing.expectEqual(@as(u16, 0), r.x);
    try testing.expectEqual(@as(u16, 0), r.y);
    try testing.expectEqual(@as(u16, 240), r.w);
    try testing.expectEqual(@as(u16, 240), r.h);
}

test "DirtyTracker: clear" {
    var dt = DirtyTracker(4).init();
    dt.mark(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    dt.clear();
    try testing.expect(!dt.isDirty());
    try testing.expectEqual(@as(usize, 0), dt.get().len);
}

test "DirtyTracker: zero-size rect ignored" {
    var dt = DirtyTracker(4).init();
    dt.mark(.{ .x = 10, .y = 10, .w = 0, .h = 5 });
    try testing.expect(!dt.isDirty());
}
