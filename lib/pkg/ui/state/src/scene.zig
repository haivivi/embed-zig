//! Compositor — Component-Based Partial Rendering
//!
//! Each component is a self-contained Zig struct that declares:
//!   - bounds(state) → Rect    — where am I? (can depend on state for sprites)
//!   - changed(state, prev) → bool — did my data change?
//!   - draw(fb, state) → void  — render myself
//!
//! The Compositor iterates components, skips unchanged ones, and only
//! redraws what actually changed. Moving sprites are handled automatically:
//! the old position is cleared before drawing at the new position.
//!
//! ## Example
//!
//! ```zig
//! const ui = @import("ui_state");
//!
//! // Each component is a struct with required pub fns
//! const ScoreLabel = struct {
//!     const bg: u16 = 0x0000;
//!     pub fn bounds(_: *const GameState) ui.Rect {
//!         return .{ .x = 8, .y = 4, .w = 80, .h = 16 };
//!     }
//!     pub fn changed(s: *const GameState, p: *const GameState) bool {
//!         return s.score != p.score;
//!     }
//!     pub fn draw(fb: *FB, s: *const GameState) void {
//!         fb.fillRect(8, 4, 80, 16, 0x2104);
//!         // ... render score
//!     }
//! };
//!
//! const PlayerCar = struct {
//!     const bg: u16 = 0x0000;
//!     pub fn bounds(s: *const GameState) ui.Rect {
//!         return .{ .x = s.player_x, .y = 180, .w = 30, .h = 45 };
//!     }
//!     pub fn changed(s: *const GameState, p: *const GameState) bool {
//!         return s.player_x != p.player_x;
//!     }
//!     pub fn draw(fb: *FB, s: *const GameState) void {
//!         fb.fillRoundRect(s.player_x, 180, 30, 45, 5, 0xF800);
//!     }
//! };
//!
//! // Compositor renders only changed components
//! const Game = ui.Compositor(FB, GameState, .{ ScoreLabel, PlayerCar });
//! Game.render(&fb, state, prev, false);
//! ```

const Rect = @import("dirty.zig").Rect;

/// Compositor: renders a set of component types with partial redraw.
///
/// `Fb` — Framebuffer type (e.g., `Framebuffer(240, 240, .rgb565)`)
/// `State` — App state struct
/// `components` — tuple of component types, each providing:
///   - `pub fn bounds(*const State) Rect`
///   - `pub fn changed(*const State, *const State) bool`
///   - `pub fn draw(*Fb, *const State) void`
///   - `const bg: u16` (optional, default 0x0000)
pub fn Compositor(comptime Fb: type, comptime State: type, comptime components: anytype) type {
    return struct {
        /// Render the scene. Only components where state changed get redrawn.
        ///
        /// For moving components (bounds depends on state), the old position
        /// is automatically cleared before drawing at the new position.
        ///
        /// `first_frame`: if true, draw all components (initial render).
        /// Returns number of components redrawn.
        pub fn render(fb: *Fb, state: *const State, prev: *const State, first_frame: bool) u8 {
            var redrawn: u8 = 0;
            inline for (components) |C| {
                if (first_frame or C.changed(state, prev)) {
                    const bg = if (@hasDecl(C, "bg")) C.bg else 0x0000;
                    const old_rect = C.bounds(prev);
                    const new_rect = C.bounds(state);

                    // Clear old position
                    fb.fillRect(old_rect.x, old_rect.y, old_rect.w, old_rect.h, bg);

                    // If moved, also clear new position (in case another component was there)
                    if (!old_rect.eql(new_rect)) {
                        fb.fillRect(new_rect.x, new_rect.y, new_rect.w, new_rect.h, bg);
                    }

                    // Draw at current position
                    C.draw(fb, state);
                    redrawn += 1;
                }
            }
            return redrawn;
        }

        /// Number of components.
        pub fn count() usize {
            return components.len;
        }
    };
}

// Also export Region and SceneRenderer for backward compatibility
// (simpler API for static layouts)

pub fn Region(comptime State: type) type {
    return struct {
        rect: Rect,
        changed: *const fn (current: *const State, prev: *const State) bool,
        draw: *const fn (fb: *anyopaque, state: *const State, bounds: Rect) void,
        clear_color: ?u16 = 0x0000,
    };
}

pub fn SceneRenderer(comptime Fb: type, comptime State: type, comptime regions: []const Region(State)) type {
    return struct {
        pub fn render(fb: *Fb, state: *const State, prev: *const State, first_frame: bool) u8 {
            var redrawn: u8 = 0;
            inline for (regions) |region| {
                if (first_frame or region.changed(state, prev)) {
                    if (region.clear_color) |bg| {
                        fb.fillRect(region.rect.x, region.rect.y, region.rect.w, region.rect.h, bg);
                    }
                    region.draw(@ptrCast(fb), state, region.rect);
                    redrawn += 1;
                }
            }
            return redrawn;
        }

        pub fn regionCount() usize {
            return regions.len;
        }

        pub fn maxDirtyBytes(comptime bpp: u32) u32 {
            var total: u32 = 0;
            for (regions) |region| {
                total += region.rect.area() * bpp;
            }
            return total;
        }

        pub fn dirtyBytes(changed_mask: u32, comptime bpp: u32) u32 {
            var total: u32 = 0;
            inline for (regions, 0..) |region, i| {
                if (changed_mask & (@as(u32, 1) << @intCast(i)) != 0) {
                    total += region.rect.area() * bpp;
                }
            }
            return total;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");
const testing = std.testing;
const Framebuffer = @import("framebuffer.zig").Framebuffer;

const TestFB = Framebuffer(240, 240, .rgb565);

// ============================================================================
// Test game state
// ============================================================================

const GameState = struct {
    score: u32 = 0,
    player_x: u16 = 110,
    obstacle_y: u16 = 50,
    time_sec: u16 = 0,
};

// ============================================================================
// Components (each is a self-contained struct)
// ============================================================================

const HudScore = struct {
    const bg: u16 = 0x2104;

    pub fn bounds(_: *const GameState) Rect {
        return .{ .x = 0, .y = 0, .w = 240, .h = 20 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.score != p.score;
    }

    pub fn draw(fb: *TestFB, s: *const GameState) void {
        fb.fillRect(0, 0, 240, 20, bg);
        // Simulate drawing score number at fixed position
        const digit_x: u16 = 60 + @as(u16, @intCast(@min(s.score, 999) % 10)) * 0;
        _ = digit_x;
        fb.fillRect(60, 4, 40, 12, 0xFFFF);
    }
};

const HudTimer = struct {
    const bg: u16 = 0x2104;

    pub fn bounds(_: *const GameState) Rect {
        return .{ .x = 180, .y = 0, .w = 60, .h = 20 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.time_sec != p.time_sec;
    }

    pub fn draw(fb: *TestFB, _: *const GameState) void {
        fb.fillRect(180, 0, 60, 20, bg);
        fb.fillRect(190, 4, 40, 12, 0xFFFF);
    }
};

const PlayerCar = struct {
    const bg: u16 = 0x0000;

    pub fn bounds(s: *const GameState) Rect {
        return .{ .x = s.player_x, .y = 180, .w = 30, .h = 45 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.player_x != p.player_x;
    }

    pub fn draw(fb: *TestFB, s: *const GameState) void {
        fb.fillRoundRect(s.player_x, 180, 30, 45, 5, 0xF800);
    }
};

const Obstacles = struct {
    const bg: u16 = 0x0000;

    pub fn bounds(_: *const GameState) Rect {
        return .{ .x = 40, .y = 20, .w = 160, .h = 160 };
    }

    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.obstacle_y != p.obstacle_y;
    }

    pub fn draw(fb: *TestFB, s: *const GameState) void {
        // Road background
        fb.fillRect(40, 20, 160, 160, 0x4208);
        // Obstacles at current positions
        fb.fillRoundRect(80, s.obstacle_y, 25, 35, 4, 0x07E0);
        fb.fillRoundRect(140, s.obstacle_y + 50, 25, 35, 4, 0x07E0);
    }
};

const Game = Compositor(TestFB, GameState, .{ HudScore, HudTimer, PlayerCar, Obstacles });

// ============================================================================
// Compositor tests
// ============================================================================

test "Compositor: first frame draws all" {
    var fb = TestFB.init(0);
    const s = GameState{};
    const n = Game.render(&fb, &s, &s, true);
    try testing.expectEqual(@as(u8, 4), n);
}

test "Compositor: no change = no redraw" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const s = GameState{ .score = 50 };
    const n = Game.render(&fb, &s, &s, false);
    try testing.expectEqual(@as(u8, 0), n);
    try testing.expectEqual(@as(usize, 0), fb.getDirtyRects().len);
}

test "Compositor: score change → only HudScore redrawn" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 10 };
    const curr = GameState{ .score = 11 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);

    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    try testing.expect(dirty <= 240 * 20);
}

test "Compositor: timer change → only HudTimer redrawn" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .time_sec = 30 };
    const curr = GameState{ .time_sec = 31 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);

    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    try testing.expect(dirty <= 60 * 20);
}

test "Compositor: player move clears old + draws new" {
    var fb = TestFB.init(0);
    // Initial render
    const s0 = GameState{ .player_x = 100 };
    _ = Game.render(&fb, &s0, &s0, true);

    // Player at x=100 should be red
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(115, 200));

    fb.clearDirty();
    const s1 = GameState{ .player_x = 150 };
    const n = Game.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u8, 1), n);

    // Old position (x=100) should be cleared to bg (black)
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(115, 200));
    // New position (x=150) should be red
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(165, 200));
}

test "Compositor: score + player → 2 components redrawn" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 10, .player_x = 100 };
    const curr = GameState{ .score = 20, .player_x = 120 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 2), n);
}

test "Compositor: count" {
    try testing.expectEqual(@as(usize, 4), Game.count());
}

// ============================================================================
// Bandwidth measurement
// ============================================================================

test "bandwidth: Compositor per-component savings" {
    const BPP: u32 = 2;
    const FULL: u32 = 240 * 240 * BPP;

    std.debug.print("\n=== Compositor Bandwidth (240x240 RGB565) ===\n", .{});

    const scenarios = [_]struct {
        name: []const u8,
        curr: GameState,
        prev: GameState,
    }{
        .{ .name = "score only", .curr = .{ .score = 11 }, .prev = .{ .score = 10 } },
        .{ .name = "timer only", .curr = .{ .time_sec = 31 }, .prev = .{ .time_sec = 30 } },
        .{ .name = "player move", .curr = .{ .player_x = 140 }, .prev = .{ .player_x = 110 } },
        .{ .name = "obstacles scroll", .curr = .{ .obstacle_y = 55 }, .prev = .{ .obstacle_y = 50 } },
        .{ .name = "score + player", .curr = .{ .score = 11, .player_x = 140 }, .prev = .{ .score = 10, .player_x = 110 } },
        .{ .name = "all change", .curr = .{ .score = 11, .player_x = 140, .obstacle_y = 55, .time_sec = 31 }, .prev = .{} },
        .{ .name = "no change", .curr = .{}, .prev = .{} },
    };

    for (scenarios) |sc| {
        var fb = TestFB.init(0);
        fb.clearDirty();
        const n = Game.render(&fb, &sc.curr, &sc.prev, false);

        var dirty: u32 = 0;
        for (fb.getDirtyRects()) |r| dirty += r.area();
        const bytes = dirty * BPP;
        const saved = if (FULL > 0) (FULL - @min(bytes, FULL)) * 100 / FULL else 0;

        std.debug.print("  {s}: {d} bytes, {d} components, {d}% saved\n", .{
            sc.name, bytes, n, saved,
        });
    }
    std.debug.print("  full screen: {d} bytes\n", .{FULL});
}
