//! SceneRenderer — Component-Based Partial Redraw
//!
//! Splits the screen into regions, each tied to specific state fields.
//! On each frame, only regions whose state actually changed get redrawn.
//! This gives LVGL-like bandwidth efficiency without LVGL's binary size.
//!
//! Data flow:
//!   State changes → check each region's `changed()` → skip unchanged
//!   → clear dirty region → call `draw()` → DirtyTracker has minimal area
//!
//! Works for both UI scenes (menu, settings) and game scenes (HUD, sprites).
//!
//! ## Usage
//!
//! ```zig
//! const ui = @import("ui_state");
//!
//! const regions = [_]ui.Region(GameState){
//!     .{  // HUD: only redraws when score changes
//!         .rect = .{ .x = 0, .y = 0, .w = 240, .h = 20 },
//!         .changed = struct { fn f(s: *const GameState, p: *const GameState) bool {
//!             return s.score != p.score;
//!         }}.f,
//!         .draw = drawHud,
//!     },
//!     .{  // Player: only redraws when position changes
//!         .rect = .{ .x = 0, .y = 180, .w = 240, .h = 60 },
//!         .changed = struct { fn f(s: *const GameState, p: *const GameState) bool {
//!             return s.player_x != p.player_x;
//!         }}.f,
//!         .draw = drawPlayer,
//!     },
//! };
//!
//! const Renderer = ui.SceneRenderer(GameState, &regions);
//! Renderer.render(&fb, state, prev, false);
//! ```

const Rect = @import("dirty.zig").Rect;

/// A renderable region of the screen.
///
/// Each region has a fixed bounding box, a state-diff function that
/// determines when it needs redraw, and a draw function that renders
/// it into the framebuffer.
///
/// Regions should not overlap for optimal dirty tracking. If they do,
/// the lower region should be drawn first (painter's algorithm).
pub fn Region(comptime State: type) type {
    return struct {
        /// Bounding box of this region on screen.
        rect: Rect,

        /// Returns true if this region needs redraw.
        /// Compares current state vs previous frame's state.
        /// Should be cheap — just compare the fields this region depends on.
        changed: *const fn (current: *const State, prev: *const State) bool,

        /// Draw this region into the framebuffer.
        /// Called with: framebuffer pointer (as *anyopaque), current state, region bounds.
        /// The draw function should only draw within the given rect bounds.
        draw: *const fn (fb: *anyopaque, state: *const State, bounds: Rect) void,

        /// Background color for clearing before redraw.
        /// Set to null to skip clearing (e.g., the draw function handles its own background).
        clear_color: ?u16 = 0x0000,
    };
}

/// Manages component-based rendering for a scene.
///
/// On each frame, iterates all regions:
///   - Unchanged regions → skip (0 bytes transferred)
///   - Changed regions → clear bounding box + redraw → DirtyTracker marks minimal area
///
/// `Fb` is the Framebuffer type (e.g., `Framebuffer(240, 240, .rgb565)`).
/// `State` is the app state struct.
/// `regions` is a comptime slice of Region descriptors.
pub fn SceneRenderer(comptime Fb: type, comptime State: type, comptime regions: []const Region(State)) type {
    return struct {
        const Self = @This();

        /// Render the scene, only redrawing regions where state changed.
        ///
        /// `first_frame`: if true, draw all regions regardless of state diff
        ///                (used for initial render or after page switch).
        ///
        /// Returns the number of regions that were redrawn.
        pub fn render(fb: *Fb, state: *const State, prev: *const State, first_frame: bool) u8 {
            var redrawn: u8 = 0;
            inline for (regions) |region| {
                if (first_frame or region.changed(state, prev)) {
                    // Clear the region to background color
                    if (region.clear_color) |bg| {
                        fb.fillRect(region.rect.x, region.rect.y, region.rect.w, region.rect.h, bg);
                    }
                    // Draw the region content
                    region.draw(@ptrCast(fb), state, region.rect);
                    redrawn += 1;
                }
            }
            return redrawn;
        }

        /// Number of regions in this scene.
        pub fn regionCount() usize {
            return regions.len;
        }

        /// Calculate the total dirty bytes if all regions were redrawn.
        /// Useful for worst-case bandwidth estimation.
        pub fn maxDirtyBytes(comptime bpp: u32) u32 {
            var total: u32 = 0;
            for (regions) |region| {
                total += region.rect.area() * bpp;
            }
            return total;
        }

        /// Calculate dirty bytes for a specific set of changed regions.
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
const DirtyTracker = @import("dirty.zig").DirtyTracker;

const TestFB = Framebuffer(240, 240, .rgb565);

const GameState = struct {
    score: u32 = 0,
    player_x: u16 = 110,
    obstacle_y: u16 = 50,
    paused: bool = false,
};

// Draw functions for test
fn drawHud(fb_ptr: *anyopaque, state: *const GameState, bounds: Rect) void {
    const fb: *TestFB = @alignCast(@ptrCast(fb_ptr));
    _ = bounds;
    // Draw score text area
    fb.fillRect(8, 4, 80, 12, 0x2104);
    // Simulate score digits
    const digits: u16 = @intCast(@min(state.score, 999));
    _ = digits;
    fb.fillRect(50, 4, 30, 12, 0xFFFF);
}

fn drawPlayer(fb_ptr: *anyopaque, state: *const GameState, bounds: Rect) void {
    const fb: *TestFB = @alignCast(@ptrCast(fb_ptr));
    _ = bounds;
    fb.fillRoundRect(state.player_x, 180, 30, 45, 5, 0xF800);
}

fn drawObstacles(fb_ptr: *anyopaque, state: *const GameState, bounds: Rect) void {
    const fb: *TestFB = @alignCast(@ptrCast(fb_ptr));
    _ = bounds;
    fb.fillRoundRect(80, state.obstacle_y, 25, 35, 4, 0x07E0);
    fb.fillRoundRect(140, state.obstacle_y + 50, 25, 35, 4, 0x07E0);
}

fn drawPauseOverlay(fb_ptr: *anyopaque, _: *const GameState, bounds: Rect) void {
    const fb: *TestFB = @alignCast(@ptrCast(fb_ptr));
    _ = bounds;
    fb.fillRect(60, 100, 120, 40, 0x4208);
}

const game_regions = [_]Region(GameState){
    .{
        .rect = .{ .x = 0, .y = 0, .w = 240, .h = 20 },
        .changed = struct {
            fn f(s: *const GameState, p: *const GameState) bool {
                return s.score != p.score;
            }
        }.f,
        .draw = drawHud,
        .clear_color = 0x0000,
    },
    .{
        .rect = .{ .x = 0, .y = 180, .w = 240, .h = 60 },
        .changed = struct {
            fn f(s: *const GameState, p: *const GameState) bool {
                return s.player_x != p.player_x;
            }
        }.f,
        .draw = drawPlayer,
        .clear_color = 0x0000,
    },
    .{
        .rect = .{ .x = 0, .y = 20, .w = 240, .h = 160 },
        .changed = struct {
            fn f(s: *const GameState, p: *const GameState) bool {
                return s.obstacle_y != p.obstacle_y;
            }
        }.f,
        .draw = drawObstacles,
        .clear_color = 0x0000,
    },
    .{
        .rect = .{ .x = 60, .y = 100, .w = 120, .h = 40 },
        .changed = struct {
            fn f(s: *const GameState, p: *const GameState) bool {
                return s.paused != p.paused;
            }
        }.f,
        .draw = drawPauseOverlay,
        .clear_color = null, // overlay, don't clear
    },
};

const GameRenderer = SceneRenderer(TestFB, GameState, &game_regions);

test "SceneRenderer: first frame draws all regions" {
    var fb = TestFB.init(0);
    const state = GameState{};
    const redrawn = GameRenderer.render(&fb, &state, &state, true);
    try testing.expectEqual(@as(u8, 4), redrawn);
}

test "SceneRenderer: no change = no redraw" {
    var fb = TestFB.init(0);
    fb.clearDirty();

    const state = GameState{ .score = 50, .player_x = 120 };
    const redrawn = GameRenderer.render(&fb, &state, &state, false);

    try testing.expectEqual(@as(u8, 0), redrawn);
    // DirtyTracker should have nothing
    try testing.expectEqual(@as(usize, 0), fb.getDirtyRects().len);
}

test "SceneRenderer: score change only redraws HUD" {
    var fb = TestFB.init(0);
    const prev = GameState{ .score = 10 };
    const curr = GameState{ .score = 11 };

    fb.clearDirty();
    const redrawn = GameRenderer.render(&fb, &curr, &prev, false);

    try testing.expectEqual(@as(u8, 1), redrawn);

    // Only HUD region should be dirty (0,0,240,20)
    const rects = fb.getDirtyRects();
    var total_area: u32 = 0;
    for (rects) |r| total_area += r.area();
    // HUD area = 240 * 20 = 4800, plus draw calls within
    try testing.expect(total_area <= 240 * 20);
}

test "SceneRenderer: player move only redraws player region" {
    var fb = TestFB.init(0);
    const prev = GameState{ .player_x = 110 };
    const curr = GameState{ .player_x = 130 };

    fb.clearDirty();
    const redrawn = GameRenderer.render(&fb, &curr, &prev, false);

    try testing.expectEqual(@as(u8, 1), redrawn);

    // Only player region should be dirty (0,180,240,60)
    const rects = fb.getDirtyRects();
    var total_area: u32 = 0;
    for (rects) |r| total_area += r.area();
    try testing.expect(total_area <= 240 * 60);
}

test "SceneRenderer: obstacle scroll only redraws game field" {
    var fb = TestFB.init(0);
    const prev = GameState{ .obstacle_y = 50 };
    const curr = GameState{ .obstacle_y = 55 };

    fb.clearDirty();
    const redrawn = GameRenderer.render(&fb, &curr, &prev, false);

    try testing.expectEqual(@as(u8, 1), redrawn);
    // Game field region = 240 * 160
    const rects = fb.getDirtyRects();
    var total_area: u32 = 0;
    for (rects) |r| total_area += r.area();
    try testing.expect(total_area <= 240 * 160);
}

test "SceneRenderer: multiple changes redraw multiple regions" {
    var fb = TestFB.init(0);
    const prev = GameState{ .score = 10, .player_x = 110 };
    const curr = GameState{ .score = 11, .player_x = 130 };

    fb.clearDirty();
    const redrawn = GameRenderer.render(&fb, &curr, &prev, false);

    try testing.expectEqual(@as(u8, 2), redrawn);
}

test "SceneRenderer: pause toggle redraws overlay without clear" {
    var fb = TestFB.init(0);
    // Fill background with a known color
    fb.fillRect(60, 100, 120, 40, 0x1111);
    fb.clearDirty();

    const prev = GameState{ .paused = false };
    const curr = GameState{ .paused = true };

    const redrawn = GameRenderer.render(&fb, &curr, &prev, false);
    try testing.expectEqual(@as(u8, 1), redrawn);

    // The overlay drew on top (no clear), so some pixels should be 0x4208
    try testing.expectEqual(@as(u16, 0x4208), fb.getPixel(70, 110));
}

test "SceneRenderer: regionCount" {
    try testing.expectEqual(@as(usize, 4), GameRenderer.regionCount());
}

test "SceneRenderer: maxDirtyBytes" {
    // HUD=240*20 + Player=240*60 + Field=240*160 + Overlay=120*40
    // = 4800 + 14400 + 38400 + 4800 = 62400 pixels * 2 bpp = 124800
    const max = GameRenderer.maxDirtyBytes(2);
    try testing.expectEqual(@as(u32, 124800), max);
}

// ============================================================================
// Bandwidth comparison tests
// ============================================================================

test "bandwidth: SceneRenderer vs monolithic render" {
    const BPP: u32 = 2;
    const FULL_SCREEN: u32 = 240 * 240 * BPP; // 115,200

    std.debug.print("\n=== SceneRenderer Bandwidth Savings ===\n", .{});

    // Scenario 1: Score update only → HUD region
    {
        var fb = TestFB.init(0);
        fb.clearDirty();
        const prev = GameState{ .score = 99 };
        const curr = GameState{ .score = 100 };
        _ = GameRenderer.render(&fb, &curr, &prev, false);

        var dirty_pixels: u32 = 0;
        for (fb.getDirtyRects()) |r| dirty_pixels += r.area();
        const dirty_bytes = dirty_pixels * BPP;
        const saved_pct = (FULL_SCREEN - dirty_bytes) * 100 / FULL_SCREEN;

        std.debug.print("  score update: {d} bytes ({d}% saved vs full screen)\n", .{
            dirty_bytes, saved_pct,
        });
    }

    // Scenario 2: Player move only → player region
    {
        var fb = TestFB.init(0);
        fb.clearDirty();
        const prev = GameState{ .player_x = 110 };
        const curr = GameState{ .player_x = 130 };
        _ = GameRenderer.render(&fb, &curr, &prev, false);

        var dirty_pixels: u32 = 0;
        for (fb.getDirtyRects()) |r| dirty_pixels += r.area();
        const dirty_bytes = dirty_pixels * BPP;
        const saved_pct = (FULL_SCREEN - dirty_bytes) * 100 / FULL_SCREEN;

        std.debug.print("  player move: {d} bytes ({d}% saved vs full screen)\n", .{
            dirty_bytes, saved_pct,
        });
    }

    // Scenario 3: Obstacle scroll → game field region
    {
        var fb = TestFB.init(0);
        fb.clearDirty();
        const prev = GameState{ .obstacle_y = 50 };
        const curr = GameState{ .obstacle_y = 55 };
        _ = GameRenderer.render(&fb, &curr, &prev, false);

        var dirty_pixels: u32 = 0;
        for (fb.getDirtyRects()) |r| dirty_pixels += r.area();
        const dirty_bytes = dirty_pixels * BPP;
        const saved_pct = (FULL_SCREEN - dirty_bytes) * 100 / FULL_SCREEN;

        std.debug.print("  obstacle scroll: {d} bytes ({d}% saved vs full screen)\n", .{
            dirty_bytes, saved_pct,
        });
    }

    // Scenario 4: Score + player move → 2 regions
    {
        var fb = TestFB.init(0);
        fb.clearDirty();
        const prev = GameState{ .score = 99, .player_x = 110 };
        const curr = GameState{ .score = 100, .player_x = 130 };
        _ = GameRenderer.render(&fb, &curr, &prev, false);

        var dirty_pixels: u32 = 0;
        for (fb.getDirtyRects()) |r| dirty_pixels += r.area();
        const dirty_bytes = dirty_pixels * BPP;
        const saved_pct = (FULL_SCREEN - dirty_bytes) * 100 / FULL_SCREEN;

        std.debug.print("  score + player: {d} bytes ({d}% saved vs full screen)\n", .{
            dirty_bytes, saved_pct,
        });
    }

    // Scenario 5: Nothing changed → 0 bytes
    {
        var fb = TestFB.init(0);
        fb.clearDirty();
        const state = GameState{};
        _ = GameRenderer.render(&fb, &state, &state, false);

        var dirty_pixels: u32 = 0;
        for (fb.getDirtyRects()) |r| dirty_pixels += r.area();

        std.debug.print("  no change: {d} bytes (100% saved)\n", .{dirty_pixels * BPP});
    }

    std.debug.print("  full screen (reference): {d} bytes\n", .{FULL_SCREEN});
}
