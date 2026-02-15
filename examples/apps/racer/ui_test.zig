//! Racer UI Tests
//!
//! Layer 1 — State Machine: dispatch events → assert state
//! Layer 2 — Render Verification: given state → assert pixels
//!
//! Run: bazel test //examples/apps/racer:ui_test

const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const sound = @import("sound.zig");

// ============================================================================
// Helpers
// ============================================================================

fn newStore() ui.Store {
    return ui.Store.init(.{}, ui.reduce);
}

fn newStoreWith(initial: ui.GameState) ui.Store {
    return ui.Store.init(initial, ui.reduce);
}

// ============================================================================
// Layer 1: State Machine Tests
// ============================================================================

test "initial state: center lane, playing, speed 2" {
    const store = newStore();
    const s = store.getState();

    try testing.expectEqual(@as(u8, 1), s.player_lane); // center
    try testing.expectEqual(ui.GamePhase.playing, s.phase);
    try testing.expectEqual(@as(u16, 2), s.speed);
    try testing.expectEqual(@as(u32, 0), s.score);
    try testing.expectEqual(@as(u32, 0), s.distance);
}

test "move_left: switches from center to left lane" {
    var store = newStore();
    store.dispatch(.move_left);
    try testing.expectEqual(@as(u8, 0), store.getState().player_lane);
}

test "move_right: switches from center to right lane" {
    var store = newStore();
    store.dispatch(.move_right);
    try testing.expectEqual(@as(u8, 2), store.getState().player_lane);
}

test "move_left: blocked at leftmost lane" {
    var state = ui.GameState{};
    state.player_lane = 0;
    var store = newStoreWith(state);
    store.dispatch(.move_left);
    try testing.expectEqual(@as(u8, 0), store.getState().player_lane);
}

test "move_right: blocked at rightmost lane" {
    var state = ui.GameState{};
    state.player_lane = 2;
    var store = newStoreWith(state);
    store.dispatch(.move_right);
    try testing.expectEqual(@as(u8, 2), store.getState().player_lane);
}

test "move_left: produces lane_switch sound" {
    var store = newStore();
    store.dispatch(.move_left);
    try testing.expectEqual(ui.SoundEvent.lane_switch, store.getState().sound);
}

test "move_left at wall: no sound" {
    var state = ui.GameState{};
    state.player_lane = 0;
    var store = newStoreWith(state);
    store.dispatch(.move_left);
    // tick clears sound, but since we only dispatched move_left which didn't
    // succeed, sound stays .none from the reduce entry
    try testing.expectEqual(ui.SoundEvent.none, store.getState().sound);
}

test "tick: increases distance" {
    var store = newStore();
    const dist_before = store.getState().distance;
    store.dispatch(.tick);
    try testing.expect(store.getState().distance > dist_before);
}

test "tick: scrolls road markings" {
    var store = newStore();
    const offset_before = store.getState().scroll_offset;
    store.dispatch(.tick);
    try testing.expect(store.getState().scroll_offset != offset_before);
}

test "tick: speed increases over distance" {
    var state = ui.GameState{};
    state.distance = 5000; // far enough for speed boost
    var store = newStoreWith(state);
    store.dispatch(.tick);
    try testing.expect(store.getState().speed > 2);
}

test "collision: obstacle in same lane at car Y → crashed" {
    var state = ui.GameState{};
    state.player_lane = 1;
    state.obstacles[0] = .{
        .lane = 1,
        .y = @intCast(ui.CAR_Y), // exact overlap
        .active = true,
        .color_idx = 0,
    };
    var store = newStoreWith(state);
    store.dispatch(.tick);

    try testing.expectEqual(ui.GamePhase.crashed, store.getState().phase);
    try testing.expectEqual(ui.SoundEvent.crash, store.getState().sound);
}

test "no collision: obstacle in different lane" {
    var state = ui.GameState{};
    state.player_lane = 0; // left
    state.obstacles[0] = .{
        .lane = 2, // right
        .y = @intCast(ui.CAR_Y),
        .active = true,
        .color_idx = 0,
    };
    var store = newStoreWith(state);
    store.dispatch(.tick);

    try testing.expectEqual(ui.GamePhase.playing, store.getState().phase);
}

test "crashed → game_over after 30 ticks" {
    var state = ui.GameState{};
    state.phase = .crashed;
    state.crash_timer = 29;
    var store = newStoreWith(state);
    store.dispatch(.tick);

    try testing.expectEqual(ui.GamePhase.game_over, store.getState().phase);
}

test "game_over: tick does nothing" {
    var state = ui.GameState{};
    state.phase = .game_over;
    state.score = 500;
    var store = newStoreWith(state);
    store.dispatch(.tick);
    try testing.expectEqual(@as(u32, 500), store.getState().score);
}

test "game_over: move events ignored" {
    var state = ui.GameState{};
    state.phase = .game_over;
    state.player_lane = 1;
    var store = newStoreWith(state);
    store.dispatch(.move_left);
    try testing.expectEqual(@as(u8, 1), store.getState().player_lane);
}

test "restart: resets everything" {
    var state = ui.GameState{};
    state.score = 9999;
    state.phase = .game_over;
    state.speed = 10;
    state.player_lane = 2;
    var store = newStoreWith(state);
    store.dispatch(.restart);

    const s = store.getState();
    try testing.expectEqual(ui.GamePhase.playing, s.phase);
    try testing.expectEqual(@as(u32, 0), s.score);
    try testing.expectEqual(@as(u16, 2), s.speed);
    try testing.expectEqual(@as(u8, 1), s.player_lane);
}

test "obstacle passes bottom: score +10" {
    var state = ui.GameState{};
    state.obstacles[0] = .{
        .lane = 0,
        .y = @intCast(ui.SCREEN_H + ui.OBS_H - 1), // about to pass
        .active = true,
        .color_idx = 0,
    };
    state.score = 0;
    state.spawn_cooldown = 100; // prevent new spawns
    var store = newStoreWith(state);
    store.dispatch(.tick);

    try testing.expect(store.getState().score >= 10);
    try testing.expect(!store.getState().obstacles[0].active);
}

// ============================================================================
// Layer 2: Render Verification Tests
// ============================================================================

test "render: road surface is gray" {
    var fb = ui.FB.init(ui.BLACK);
    const state = ui.GameState{};
    const prev = state;
    ui.render(&fb, &state, &prev);

    // Center of road should be ROAD_COLOR
    const mid_x = (ui.ROAD_LEFT + ui.ROAD_RIGHT) / 2;
    try testing.expectEqual(ui.ROAD_COLOR, fb.getPixel(mid_x, 120));
}

test "render: grass on sides" {
    var fb = ui.FB.init(ui.BLACK);
    const state = ui.GameState{};
    const prev = state;
    ui.render(&fb, &state, &prev);

    // Left margin should be grass
    try testing.expectEqual(ui.GRASS_COLOR, fb.getPixel(10, 120));
    // Right margin should be grass
    try testing.expectEqual(ui.GRASS_COLOR, fb.getPixel(220, 120));
}

test "render: player car in center lane" {
    var fb = ui.FB.init(ui.BLACK);
    var state = ui.GameState{};
    state.player_lane = 1; // center
    const prev = state;
    ui.render(&fb, &state, &prev);

    // Car body pixel (left edge, below windshield area)
    const car_x = ui.LANE_X[1];
    try testing.expectEqual(ui.PLAYER_COLOR, fb.getPixel(car_x + 1, ui.CAR_Y + ui.CAR_H - 8));
}

test "render: player car moves with lane" {
    var fb = ui.FB.init(ui.BLACK);
    var state = ui.GameState{};
    state.player_lane = 0; // left lane
    const prev = state;
    ui.render(&fb, &state, &prev);

    const left_car_x = ui.LANE_X[0];
    try testing.expectEqual(ui.PLAYER_COLOR, fb.getPixel(left_car_x + 1, ui.CAR_Y + ui.CAR_H - 8));
}

test "render: obstacle visible on screen" {
    var fb = ui.FB.init(ui.BLACK);
    var state = ui.GameState{};
    state.obstacles[0] = .{
        .lane = 1,
        .y = 100, // visible
        .active = true,
        .color_idx = 0, // blue
    };
    const prev = state;
    ui.render(&fb, &state, &prev);

    // Obstacle center pixel should be obstacle color
    const obs_x = ui.LANE_X[1] + ui.OBS_W / 2;
    try testing.expectEqual(ui.OBS_COLORS[0], fb.getPixel(obs_x, 100 + ui.OBS_H / 2));
}

test "render: score displayed at top" {
    var fb = ui.FB.init(ui.BLACK);
    var state = ui.GameState{};
    state.score = 42;
    const prev = state;
    ui.render(&fb, &state, &prev);

    // Digit '4' bitmap row 0 = 0x10 → bit at col 3
    // Score rendered at (2, 2), digit '4' at x=2
    // '4' row 0: 0x10 = ...#.... → pixel at (2+3, 2) should be white
    try testing.expectEqual(ui.SCORE_COLOR, fb.getPixel(2 + 3, 2));
}

// ============================================================================
// Sound Tests
// ============================================================================

test "sound: lane_switch generates samples" {
    const buf = sound.generate(.lane_switch);
    try testing.expect(buf.len > 0);
    try testing.expect(buf.len <= sound.MAX_SAMPLES);
    // Should have non-zero samples (audible)
    var has_signal = false;
    for (buf.samples[0..buf.len]) |s| {
        if (s != 0) has_signal = true;
    }
    try testing.expect(has_signal);
}

test "sound: crash generates samples" {
    const buf = sound.generate(.crash);
    try testing.expect(buf.len > 0);
}

test "sound: milestone generates samples" {
    const buf = sound.generate(.milestone);
    try testing.expect(buf.len > 0);
}

test "sound: none generates nothing" {
    const buf = sound.generate(.none);
    try testing.expectEqual(@as(u32, 0), buf.len);
}
