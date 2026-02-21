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
//! ## Known Limitation: Overlapping Components
//!
//! The Compositor has no Z-ordering. When a component is redrawn, its old
//! position is cleared with `bg` color, which may overwrite pixels from
//! other components that overlap that area. To avoid artifacts:
//!   - Order components bottom-to-top (background first, foreground last)
//!   - Use the component's `bg` color matching the layer beneath it
//!   - Avoid large background fills inside draw(); let `bg` handle clearing
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
// Edge case: component at screen edge (clips to bounds)
// ============================================================================

const EdgeState = struct {
    x: u16 = 0,
    visible: bool = true,
};

const EdgeSprite = struct {
    const bg: u16 = 0x0000;
    pub fn bounds(s: *const EdgeState) Rect {
        return .{ .x = s.x, .y = 220, .w = 30, .h = 30 };
    }
    pub fn changed(s: *const EdgeState, p: *const EdgeState) bool {
        return s.x != p.x or s.visible != p.visible;
    }
    pub fn draw(fb: *TestFB, s: *const EdgeState) void {
        if (s.visible) {
            fb.fillRect(s.x, 220, 30, 30, 0xF800);
        }
    }
};

const EdgeScene = Compositor(TestFB, EdgeState, .{EdgeSprite});

test "edge: component partially off-screen right" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    // Sprite at x=225, extends to x=255 (15px off-screen)
    const prev = EdgeState{ .x = 100 };
    const curr = EdgeState{ .x = 225 };
    const n = EdgeScene.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);
    // Should draw without crash, framebuffer clips internally
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(225, 225));
    // x=239 is still within the clipped rect (225..240), so it IS drawn
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(239, 225));
    // But old position (x=100) should be cleared
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(110, 230));
}

test "edge: component moves from off-screen to on-screen" {
    var fb = TestFB.init(0x1111);
    // prev was at x=250 (fully off-screen), now at x=200
    const prev = EdgeState{ .x = 250 };
    const curr = EdgeState{ .x = 200 };
    const n = EdgeScene.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);
    // New position should be drawn
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(210, 230));
}

test "edge: component visibility toggle" {
    var fb = TestFB.init(0);
    // First render visible
    const s0 = EdgeState{ .x = 50, .visible = true };
    _ = EdgeScene.render(&fb, &s0, &s0, true);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(60, 230));

    // Toggle to invisible
    fb.clearDirty();
    const s1 = EdgeState{ .x = 50, .visible = false };
    _ = EdgeScene.render(&fb, &s1, &s0, false);
    // Old position should be cleared to bg
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(60, 230));
}

// ============================================================================
// Edge case: overlapping components
// ============================================================================

const OverlapState = struct {
    bg_color: u16 = 0x1111,
    fg_value: u16 = 0xF800,
};

const BackPanel = struct {
    const bg: u16 = 0x0000;
    pub fn bounds(_: *const OverlapState) Rect {
        return .{ .x = 50, .y = 50, .w = 100, .h = 100 };
    }
    pub fn changed(s: *const OverlapState, p: *const OverlapState) bool {
        return s.bg_color != p.bg_color;
    }
    pub fn draw(fb: *TestFB, s: *const OverlapState) void {
        fb.fillRect(50, 50, 100, 100, s.bg_color);
    }
};

const FrontBadge = struct {
    const bg: u16 = 0x1111; // same as BackPanel color to blend
    pub fn bounds(_: *const OverlapState) Rect {
        return .{ .x = 80, .y = 80, .w = 40, .h = 40 };
    }
    pub fn changed(s: *const OverlapState, p: *const OverlapState) bool {
        return s.fg_value != p.fg_value;
    }
    pub fn draw(fb: *TestFB, s: *const OverlapState) void {
        fb.fillRect(80, 80, 40, 40, s.fg_value);
    }
};

const OverlapScene = Compositor(TestFB, OverlapState, .{ BackPanel, FrontBadge });

test "edge: overlapping components both drawn on first frame" {
    var fb = TestFB.init(0);
    const s = OverlapState{};
    _ = OverlapScene.render(&fb, &s, &s, true);
    // FrontBadge drawn after BackPanel → front wins at overlap
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(90, 90));
    // BackPanel outside overlap area
    try testing.expectEqual(@as(u16, 0x1111), fb.getPixel(55, 55));
}

test "edge: only front changes → back untouched" {
    var fb = TestFB.init(0);
    const s0 = OverlapState{};
    _ = OverlapScene.render(&fb, &s0, &s0, true);

    fb.clearDirty();
    const s1 = OverlapState{ .fg_value = 0x07E0 };
    const n = OverlapScene.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u8, 1), n);
    // Front changed to green
    try testing.expectEqual(@as(u16, 0x07E0), fb.getPixel(90, 90));
    // Back panel area outside badge unchanged
    try testing.expectEqual(@as(u16, 0x1111), fb.getPixel(55, 55));
}

test "edge: only back changes → front gets overwritten by clear" {
    var fb = TestFB.init(0);
    const s0 = OverlapState{};
    _ = OverlapScene.render(&fb, &s0, &s0, true);

    fb.clearDirty();
    const s1 = OverlapState{ .bg_color = 0x2222 };
    const n = OverlapScene.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u8, 1), n);
    // Back changed, but front was NOT redrawn → overlap area has back's color
    // This is a known limitation: overlapping components should both be
    // redrawn if the back one changes. Currently the front gets clobbered.
    try testing.expectEqual(@as(u16, 0x2222), fb.getPixel(90, 90));
}

// ============================================================================
// Edge case: rapid position changes (ping-pong)
// ============================================================================

test "edge: rapid back-and-forth movement" {
    var fb = TestFB.init(0);
    const s0 = GameState{ .player_x = 100 };
    _ = Game.render(&fb, &s0, &s0, true);

    // Move right
    fb.clearDirty();
    const s1 = GameState{ .player_x = 120 };
    _ = Game.render(&fb, &s1, &s0, false);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(135, 200));
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(105, 200)); // old cleared

    // Move back to original
    fb.clearDirty();
    const s2 = GameState{ .player_x = 100 };
    _ = Game.render(&fb, &s2, &s1, false);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(115, 200));
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(135, 200)); // old cleared
}

test "edge: move by 1 pixel" {
    var fb = TestFB.init(0);
    const prev = GameState{ .player_x = 100 };
    const curr = GameState{ .player_x = 101 };
    fb.clearDirty();
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);

    // Dirty area should be small (old 30px + new 30px, with 29px overlap)
    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    // At most old_rect + new_rect area (might merge due to overlap)
    try testing.expect(dirty <= 30 * 45 * 2);
}

// ============================================================================
// Edge case: single component scene
// ============================================================================

const SingleScene = Compositor(TestFB, GameState, .{HudScore});

test "edge: single component scene" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 0 };
    const curr = GameState{ .score = 1 };
    const n = SingleScene.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), n);
    try testing.expectEqual(@as(usize, 1), SingleScene.count());
}

// ============================================================================
// Edge case: component with no bg declaration (defaults to 0x0000)
// ============================================================================

const NoBgComponent = struct {
    pub fn bounds(_: *const GameState) Rect {
        return .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    }
    pub fn changed(s: *const GameState, p: *const GameState) bool {
        return s.score != p.score;
    }
    pub fn draw(fb: *TestFB, _: *const GameState) void {
        fb.fillRect(10, 10, 20, 20, 0xAAAA);
    }
};

const NoBgScene = Compositor(TestFB, GameState, .{NoBgComponent});

test "edge: component without bg declaration uses black" {
    var fb = TestFB.init(0xFFFF); // white background
    fb.clearDirty();
    const prev = GameState{ .score = 0 };
    const curr = GameState{ .score = 1 };
    _ = NoBgScene.render(&fb, &curr, &prev, false);
    // Component area drawn with 0xAAAA
    try testing.expectEqual(@as(u16, 0xAAAA), fb.getPixel(15, 15));
    // Adjacent area untouched (still white)
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(5, 5));
}

// ============================================================================
// Edge case: all fields change simultaneously
// ============================================================================

test "edge: all 4 components change at once" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    const prev = GameState{ .score = 0, .time_sec = 0, .player_x = 100, .obstacle_y = 50 };
    const curr = GameState{ .score = 99, .time_sec = 60, .player_x = 200, .obstacle_y = 100 };
    const n = Game.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 4), n);

    // All components should have drawn
    // HudScore
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(70, 8));
    // HudTimer
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(200, 8));
    // Player at new position
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(215, 200));
    // Old player position cleared
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(115, 200));
}

// ============================================================================
// Edge case: changed() returns true but draw is a no-op
// ============================================================================

const PhantomComponent = struct {
    const bg: u16 = 0x0000;
    pub fn bounds(_: *const GameState) Rect {
        return .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    }
    pub fn changed(_: *const GameState, _: *const GameState) bool {
        return true; // always claims changed
    }
    pub fn draw(_: *TestFB, _: *const GameState) void {
        // draws nothing
    }
};

const PhantomScene = Compositor(TestFB, GameState, .{PhantomComponent});

test "edge: always-dirty component with no-op draw" {
    var fb = TestFB.init(0xBBBB);
    fb.clearDirty();
    const s = GameState{};
    const n = PhantomScene.render(&fb, &s, &s, false);
    try testing.expectEqual(@as(u8, 1), n);
    // Area was cleared to bg (black) even though draw was no-op
    try testing.expectEqual(@as(u16, 0x0000), fb.getPixel(5, 5));
    // Outside area untouched
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(15, 15));
}

// ============================================================================
// Edge case: consecutive renders without clearDirty
// ============================================================================

test "edge: consecutive renders accumulate dirty rects" {
    var fb = TestFB.init(0);
    // Render frame 1: score changes
    const s0 = GameState{ .score = 0 };
    const s1 = GameState{ .score = 1 };
    _ = Game.render(&fb, &s1, &s0, false);

    // Don't clear dirty! Render frame 2: player moves
    const s2 = GameState{ .score = 1, .player_x = 130 };
    _ = Game.render(&fb, &s2, &s1, false);

    // Dirty rects should include both HUD and player regions
    var dirty: u32 = 0;
    for (fb.getDirtyRects()) |r| dirty += r.area();
    try testing.expect(dirty > 240 * 20); // more than just HUD
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
