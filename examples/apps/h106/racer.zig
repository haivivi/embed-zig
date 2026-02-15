//! Racer sub-module — reusable game logic for embedding in H106 app.
//! Adapted from examples/apps/racer/ui.zig.

const state_lib = @import("ui_state");
pub const FB = state_lib.Framebuffer(240, 240, .rgb565);

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;
const ROAD_LEFT: u16 = 40;
const ROAD_RIGHT: u16 = 200;
const ROAD_W: u16 = ROAD_RIGHT - ROAD_LEFT;
const LANE_W: u16 = ROAD_W / 3;
const LANE_COUNT: u32 = 3;
const CAR_W: u16 = 22;
const CAR_H: u16 = 36;
const CAR_Y: u16 = SCREEN_H - CAR_H - 10;
const OBS_W: u16 = 22;
const OBS_H: u16 = 32;
const MAX_OBSTACLES = 8;
const MARK_H: u16 = 20;
const MARK_GAP: u16 = 20;
const MARK_W: u16 = 3;

const LANE_X = [3]u16{
    ROAD_LEFT + LANE_W / 2 - CAR_W / 2,
    ROAD_LEFT + LANE_W + LANE_W / 2 - CAR_W / 2,
    ROAD_LEFT + 2 * LANE_W + LANE_W / 2 - CAR_W / 2,
};

const BLACK: u16 = 0x0000;
const WHITE: u16 = 0xFFFF;
const ROAD_COLOR: u16 = 0x3186;
const GRASS_COLOR: u16 = 0x2C04;
const MARK_COLOR: u16 = 0xC618;
const PLAYER_COLOR: u16 = 0xF800;
const PLAYER_WIND: u16 = 0xFBE0;
const CRASH_COLOR: u16 = 0xF800;
const OBS_COLORS = [_]u16{ 0x001F, 0xFFE0, 0x07E0, 0xF81F, 0x07FF, 0xFD20 };

pub const GamePhase = enum { playing, crashed, game_over };

const Obstacle = struct { lane: u8, y: i16, active: bool, color_idx: u3 };

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
    prev_spawn_lane: u8 = 255,
};

pub const GameEvent = union(enum) { tick, move_left, move_right, restart };

pub fn reduce(state: *GameState, event: GameEvent) void {
    switch (event) {
        .tick => tickUpdate(state),
        .move_left => { if (state.phase == .playing and state.player_lane > 0) state.player_lane -= 1; },
        .move_right => { if (state.phase == .playing and state.player_lane < LANE_COUNT - 1) state.player_lane += 1; },
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
    if (state.player_x < target_x) state.player_x = @min(target_x, state.player_x + 6)
    else if (state.player_x > target_x) state.player_x = if (target_x + 6 > state.player_x) target_x else state.player_x - 6;

    state.scroll_offset = (state.scroll_offset + state.speed) % (MARK_H + MARK_GAP);
    for (&state.obstacles) |*obs| {
        if (!obs.active) continue;
        obs.y += @intCast(state.speed);
        if (obs.y > SCREEN_H + OBS_H) { obs.active = false; state.score += 10; }
    }
    state.distance += state.speed;
    const ts = 2 + @as(u16, @intCast(@min(state.distance / 800, 6)));
    if (state.speed < ts) state.speed = ts;

    if (state.spawn_cooldown > 0) { state.spawn_cooldown -= 1; } else {
        spawnObs(state);
        const gap: u32 = CAR_H * 3 + OBS_H;
        state.spawn_cooldown = @intCast(@min(120, @max(12, gap / state.speed)));
    }
    for (state.obstacles) |obs| {
        if (!obs.active) continue;
        const ox = LANE_X[obs.lane];
        if (obs.y + OBS_H > CAR_Y and obs.y < CAR_Y + CAR_H and
            ox + OBS_W > state.player_x and ox < state.player_x + CAR_W) {
            state.phase = .crashed; state.crash_timer = 0; return;
        }
    }
}

fn spawnObs(state: *GameState) void {
    for (&state.obstacles) |*obs| {
        if (obs.active) continue;
        var lane: u8 = @intCast(nextRng(state) % LANE_COUNT);
        if (lane == state.prev_spawn_lane) lane = @intCast((lane + 1) % LANE_COUNT);
        state.prev_spawn_lane = lane;
        obs.* = .{ .lane = lane, .y = -@as(i16, OBS_H), .active = true, .color_idx = @intCast(nextRng(state) % OBS_COLORS.len) };
        return;
    }
}

fn nextRng(s: *GameState) u32 {
    s.rng_state = s.rng_state *% 1103515245 +% 12345;
    return (s.rng_state >> 16) & 0x7FFF;
}

pub fn render(fb: *FB, state: *const GameState, prev: *const GameState) void {
    _ = prev;
    fb.fillRect(0, 0, ROAD_LEFT, SCREEN_H, GRASS_COLOR);
    fb.fillRect(ROAD_RIGHT, 0, SCREEN_W - ROAD_RIGHT, SCREEN_H, GRASS_COLOR);
    fb.fillRect(ROAD_LEFT, 0, ROAD_W, SCREEN_H, ROAD_COLOR);
    fb.fillRect(ROAD_LEFT, 0, 2, SCREEN_H, WHITE);
    fb.fillRect(ROAD_RIGHT - 2, 0, 2, SCREEN_H, WHITE);

    const dividers = [_]u16{ ROAD_LEFT + LANE_W - MARK_W / 2, ROAD_LEFT + 2 * LANE_W - MARK_W / 2 };
    for (dividers) |dx| {
        var y: i16 = -@as(i16, MARK_H) + @as(i16, @intCast(state.scroll_offset));
        while (y < SCREEN_H) : (y += @as(i16, MARK_H + MARK_GAP)) {
            if (y + MARK_H > 0) {
                const dy: u16 = if (y < 0) 0 else @intCast(y);
                const dh: u16 = if (y < 0) @intCast(@as(i16, MARK_H) + y) else @min(MARK_H, SCREEN_H - dy);
                if (dh > 0) fb.fillRect(dx, dy, MARK_W, dh, MARK_COLOR);
            }
        }
    }

    for (state.obstacles) |obs| {
        if (!obs.active) continue;
        if (obs.y + @as(i16, OBS_H) <= 0 or obs.y >= SCREEN_H) continue;
        const oy: u16 = if (obs.y < 0) 0 else @intCast(obs.y);
        const oh: u16 = if (obs.y < 0) @intCast(@as(i16, OBS_H) + obs.y) else @min(OBS_H, SCREEN_H - oy);
        if (oh > 0) fb.fillRect(LANE_X[obs.lane], oy, OBS_W, oh, OBS_COLORS[obs.color_idx]);
    }

    if (state.phase == .crashed) {
        const fl: u16 = if (state.crash_timer % 4 < 2) CRASH_COLOR else WHITE;
        drawCar(fb, state.player_x, CAR_Y, fl, fl);
    } else if (state.phase != .game_over) {
        drawCar(fb, state.player_x, CAR_Y, PLAYER_COLOR, PLAYER_WIND);
    }

    fb.fillRect(2, 2, 36, 9, BLACK);
    drawScore(fb, 2, 2, state.score);
}

fn drawCar(fb: *FB, x: u16, y: u16, body: u16, wind: u16) void {
    fb.fillRect(x, y, CAR_W, CAR_H, body);
    fb.fillRect(x + 3, y + 3, CAR_W - 6, 8, wind);
    fb.fillRect(x + 1, y + CAR_H - 4, 4, 3, 0xFFE0);
    fb.fillRect(x + CAR_W - 5, y + CAR_H - 4, 4, 3, 0xFFE0);
}

const DIGIT_BMP = [10][7]u8{
    .{0x70,0x88,0x98,0xA8,0xC8,0x88,0x70},.{0x20,0x60,0x20,0x20,0x20,0x20,0x70},
    .{0x70,0x88,0x08,0x10,0x20,0x40,0xF8},.{0x70,0x88,0x08,0x30,0x08,0x88,0x70},
    .{0x10,0x30,0x50,0x90,0xF8,0x10,0x10},.{0xF8,0x80,0xF0,0x08,0x08,0x88,0x70},
    .{0x30,0x40,0x80,0xF0,0x88,0x88,0x70},.{0xF8,0x08,0x10,0x20,0x40,0x40,0x40},
    .{0x70,0x88,0x88,0x70,0x88,0x88,0x70},.{0x70,0x88,0x88,0x78,0x08,0x10,0x60},
};

fn drawScore(fb: *FB, x: u16, y: u16, val: u32) void {
    var buf: [10]u8 = undefined;
    var v = val; var i: usize = 10;
    if (v == 0) { buf[9] = '0'; i = 9; } else while (v > 0) : (v /= 10) { i -= 1; buf[i] = @intCast('0' + v % 10); }
    var cx = x;
    for (buf[i..10]) |ch| {
        if (ch >= '0' and ch <= '9') {
            const bmp = &DIGIT_BMP[ch - '0'];
            for (0..7) |r| for (0..5) |c| {
                if (bmp[r] & (@as(u8, 0x80) >> @intCast(c)) != 0)
                    fb.setPixel(cx + @as(u16, @intCast(c)), y + @as(u16, @intCast(r)), WHITE);
            };
        }
        cx += 6;
    }
}
