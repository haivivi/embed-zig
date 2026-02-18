//! Racer — Game State + Reducer
//!
//! Pure game logic, no rendering dependencies.

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;
pub const ROAD_LEFT: u16 = 40;
pub const ROAD_RIGHT: u16 = 200;
pub const ROAD_W: u16 = ROAD_RIGHT - ROAD_LEFT;
pub const LANE_W: u16 = ROAD_W / 3;
pub const LANE_COUNT: u32 = 3;
pub const CAR_W: u16 = 22;
pub const CAR_H: u16 = 36;
pub const CAR_Y: u16 = SCREEN_H - CAR_H - 10;
pub const OBS_W: u16 = 22;
pub const OBS_H: u16 = 32;
pub const MAX_OBSTACLES = 8;
pub const LANE_X = [3]u16{
    ROAD_LEFT + LANE_W / 2 - CAR_W / 2,
    ROAD_LEFT + LANE_W + LANE_W / 2 - CAR_W / 2,
    ROAD_LEFT + 2 * LANE_W + LANE_W / 2 - CAR_W / 2,
};
pub const MARK_H: u16 = 20;
pub const MARK_GAP: u16 = 20;
pub const MARK_W: u16 = 3;

pub const OBS_COLORS = [_]u16{ 0x001F, 0xFFE0, 0x07E0, 0xF81F, 0x07FF, 0xFD20 };

pub const GamePhase = enum { playing, crashed, game_over };
pub const SoundEvent = enum { none, lane_switch, crash, milestone };

pub const Obstacle = struct {
    lane: u8,
    y: i16,
    active: bool,
    color_idx: u3,
};

pub const GameState = struct {
    player_lane: u8 = 1,
    player_x: u16 = LANE_X[1],
    obstacles: [MAX_OBSTACLES]Obstacle = [_]Obstacle{.{ .lane = 0, .y = -100, .active = false, .color_idx = 0 }} ** MAX_OBSTACLES,
    scroll_offset: u16 = 0,
    speed: u16 = 2,
    score: u32 = 0,
    distance: u32 = 0,
    phase: GamePhase = .playing,
    tick_count: u32 = 0,
    rng_state: u32 = 54321,
    spawn_cooldown: u8 = 0,
    crash_timer: u8 = 0,
    sound: SoundEvent = .none,
    last_milestone: u32 = 0,
    prev_spawn_lane: u8 = 255,
};

pub const GameEvent = union(enum) { tick, move_left, move_right, restart };

pub fn reduce(state: *GameState, event: GameEvent) void {
    state.sound = .none;
    switch (event) {
        .tick => tickUpdate(state),
        .move_left => {
            if (state.phase != .playing) return;
            if (state.player_lane > 0) { state.player_lane -= 1; state.sound = .lane_switch; }
        },
        .move_right => {
            if (state.phase != .playing) return;
            if (state.player_lane < LANE_COUNT - 1) { state.player_lane += 1; state.sound = .lane_switch; }
        },
        .restart => { const seed = state.rng_state +% 1; state.* = .{}; state.rng_state = seed; },
    }
}

fn tickUpdate(state: *GameState) void {
    if (state.phase == .game_over) return;
    if (state.phase == .crashed) {
        state.crash_timer += 1;
        if (state.crash_timer >= 30) state.phase = .game_over;
        return;
    }
    state.tick_count += 1;
    const target_x = LANE_X[state.player_lane];
    if (state.player_x < target_x) {
        state.player_x = @min(target_x, state.player_x + 6);
    } else if (state.player_x > target_x) {
        state.player_x = if (target_x + 6 > state.player_x) target_x else state.player_x - 6;
    }
    state.scroll_offset = (state.scroll_offset + state.speed) % (MARK_H + MARK_GAP);
    for (&state.obstacles) |*obs| {
        if (!obs.active) continue;
        obs.y += @intCast(state.speed);
        if (obs.y > SCREEN_H + OBS_H) { obs.active = false; state.score += 10; }
    }
    state.distance += state.speed;
    const target_speed = 2 + @as(u16, @intCast(@min(state.distance / 800, 6)));
    if (state.speed < target_speed) state.speed = target_speed;
    const milestone = state.score / 100;
    if (milestone > state.last_milestone) { state.last_milestone = milestone; state.sound = .milestone; }
    if (state.spawn_cooldown > 0) { state.spawn_cooldown -= 1; } else {
        spawnObstacle(state);
        const min_gap_pixels: u32 = CAR_H * 3 + OBS_H;
        state.spawn_cooldown = @intCast(@min(120, @max(12, min_gap_pixels / state.speed)));
    }
    for (state.obstacles) |obs| {
        if (!obs.active) continue;
        const obs_x = LANE_X[obs.lane];
        if (obs.y + OBS_H > CAR_Y and obs.y < CAR_Y + CAR_H and
            obs_x + OBS_W > state.player_x and obs_x < state.player_x + CAR_W)
        { state.phase = .crashed; state.crash_timer = 0; state.sound = .crash; return; }
    }
}

fn spawnObstacle(state: *GameState) void {
    for (&state.obstacles) |*obs| {
        if (obs.active) continue;
        var lane: u8 = @intCast(nextRng(state) % LANE_COUNT);
        if (lane == state.prev_spawn_lane) lane = @intCast((lane + 1) % LANE_COUNT);
        state.prev_spawn_lane = lane;
        obs.* = .{ .lane = lane, .y = -@as(i16, OBS_H), .active = true, .color_idx = @intCast(nextRng(state) % OBS_COLORS.len) };
        return;
    }
}

pub fn nextRng(state: *GameState) u32 {
    state.rng_state = state.rng_state *% 1103515245 +% 12345;
    return (state.rng_state >> 16) & 0x7FFF;
}
