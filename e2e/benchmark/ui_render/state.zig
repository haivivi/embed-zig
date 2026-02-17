//! Shared state for UI render benchmark
//!
//! Both Compositor and LVGL implementations use this exact state,
//! events, and reducer — the only difference is the rendering backend.

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;

// ============================================================================
// State
// ============================================================================

pub const Page = enum(u8) { menu, settings, game };

pub const State = struct {
    page: Page = .menu,
    tick: u32 = 0,

    // Status bar
    time_hour: u8 = 12,
    time_min: u8 = 30,
    battery: u8 = 80,
    wifi: bool = true,

    // Menu page
    selected: u8 = 0,

    // Settings page
    brightness: u8 = 128,
    volume: u8 = 200,

    // Game page
    score: u32 = 0,
    player_x: u16 = 110,
    obs_y: [3]u16 = .{ 50, 100, 150 },
};

// ============================================================================
// Events
// ============================================================================

pub const Event = union(enum) {
    tick,
    left,
    right,
    up,
    down,
    confirm,
    back,
};

// ============================================================================
// Reducer
// ============================================================================

pub fn reduce(state: *State, event: Event) void {
    state.tick += 1;

    switch (state.page) {
        .menu => switch (event) {
            .up => if (state.selected > 0) { state.selected -= 1; },
            .down => if (state.selected < 4) { state.selected += 1; },
            .right => state.page = .settings,
            .confirm => state.page = .game,
            else => {},
        },
        .settings => switch (event) {
            .left, .back => state.page = .menu,
            .up => state.brightness = @min(255, state.brightness + 10),
            .down => state.brightness = @max(0, state.brightness -| 10),
            .right => state.volume = @min(255, state.volume + 10),
            else => {},
        },
        .game => switch (event) {
            .back => state.page = .menu,
            .left => state.player_x = @max(40, state.player_x -| 10),
            .right => state.player_x = @min(170, state.player_x + 10),
            .tick => {
                state.score += 1;
                for (&state.obs_y) |*y| {
                    y.* += 2;
                    if (y.* > SCREEN_H) y.* = 0;
                }
            },
            else => {},
        },
    }

    // Time ticks every 1800 ticks (~1 min at 30fps)
    if (state.tick % 1800 == 0) {
        state.time_min += 1;
        if (state.time_min >= 60) {
            state.time_min = 0;
            state.time_hour = (state.time_hour + 1) % 24;
        }
    }

    // Battery drain every 3600 ticks
    if (state.tick % 3600 == 0 and state.battery > 0) {
        state.battery -= 1;
    }
}

// ============================================================================
// Test scenarios — identical event sequences for fair comparison
// ============================================================================

pub const Scenario = struct {
    name: []const u8,
    initial: State,
    events: []const Event,
};

pub const scenarios = [_]Scenario{
    // Menu page scenarios
    .{ .name = "menu: idle 10 frames", .initial = .{}, .events = &([_]Event{.tick} ** 10) },
    .{ .name = "menu: nav down 5", .initial = .{}, .events = &.{ .down, .down, .down, .down, .down } },
    .{ .name = "menu: → settings", .initial = .{}, .events = &.{.right} },
    .{ .name = "menu: → game", .initial = .{}, .events = &.{.confirm} },

    // Settings page scenarios
    .{ .name = "settings: idle 10", .initial = .{ .page = .settings }, .events = &([_]Event{.tick} ** 10) },
    .{ .name = "settings: bright+5", .initial = .{ .page = .settings }, .events = &.{ .up, .up, .up, .up, .up } },
    .{ .name = "settings: → menu", .initial = .{ .page = .settings }, .events = &.{.back} },

    // Game page scenarios
    .{ .name = "game: idle 10 ticks", .initial = .{ .page = .game, .score = 100 }, .events = &([_]Event{.tick} ** 10) },
    .{ .name = "game: dodge left 3", .initial = .{ .page = .game, .player_x = 110 }, .events = &.{ .left, .left, .left } },
    .{ .name = "game: dodge right 3", .initial = .{ .page = .game, .player_x = 110 }, .events = &.{ .right, .right, .right } },
    .{ .name = "game: play 20 frames", .initial = .{ .page = .game, .score = 50 }, .events = &([_]Event{.tick} ** 20) },
};
