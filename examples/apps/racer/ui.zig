//! Racer UI — Road Fighter-style Vertical Scrolling Racer
//!
//! Classic FC-style top-down racing game:
//! - 3-lane road scrolling vertically
//! - Player car at bottom, left/right to switch lanes
//! - Obstacles spawn from top, scroll down
//! - Speed increases over time
//! - Collision = game over
//!
//! Pure logic + rendering, no platform dependencies.

const state_lib = @import("ui_state");

// ============================================================================
// Constants
// ============================================================================

pub const SCREEN_W: u16 = 240;
pub const SCREEN_H: u16 = 240;
pub const FB = state_lib.Framebuffer(SCREEN_W, SCREEN_H, .rgb565);

// Road geometry
pub const ROAD_LEFT: u16 = 40;
pub const ROAD_RIGHT: u16 = 200;
pub const ROAD_W: u16 = ROAD_RIGHT - ROAD_LEFT;
pub const LANE_W: u16 = ROAD_W / 3; // ~53px per lane
pub const LANE_COUNT = 3;

// Car dimensions
pub const CAR_W: u16 = 22;
pub const CAR_H: u16 = 36;
pub const CAR_Y: u16 = SCREEN_H - CAR_H - 10; // near bottom

// Obstacle dimensions
pub const OBS_W: u16 = 22;
pub const OBS_H: u16 = 32;
pub const MAX_OBSTACLES = 8;

// Lane center X positions
pub const LANE_X = [LANE_COUNT]u16{
    ROAD_LEFT + LANE_W / 2 - CAR_W / 2,
    ROAD_LEFT + LANE_W + LANE_W / 2 - CAR_W / 2,
    ROAD_LEFT + 2 * LANE_W + LANE_W / 2 - CAR_W / 2,
};

// Road marking
pub const MARK_H: u16 = 20;
pub const MARK_GAP: u16 = 20;
pub const MARK_W: u16 = 3;

// RGB565 colors
pub const BLACK: u16 = 0x0000;
pub const WHITE: u16 = 0xFFFF;
pub const ROAD_COLOR: u16 = 0x3186; // dark gray road
pub const GRASS_COLOR: u16 = 0x2C04; // dark green
pub const MARK_COLOR: u16 = 0xC618; // light gray dashes
pub const PLAYER_COLOR: u16 = 0xF800; // red car
pub const PLAYER_WIND: u16 = 0xFBE0; // orange windshield
pub const OBS_COLORS = [_]u16{
    0x001F, // blue
    0xFFE0, // yellow
    0x07E0, // green
    0xF81F, // magenta
    0x07FF, // cyan
    0xFD20, // orange
};
pub const SCORE_COLOR: u16 = 0xFFFF;
pub const CRASH_COLOR: u16 = 0xF800; // red flash

// ============================================================================
// State
// ============================================================================

pub const GamePhase = enum { playing, crashed, game_over };

pub const SoundEvent = enum { none, lane_switch, crash, milestone };

pub const Obstacle = struct {
    lane: u8, // 0-2
    y: i16, // screen Y (negative = off top)
    active: bool,
    color_idx: u3,
};

pub const GameState = struct {
    player_lane: u8 = 1, // 0=left, 1=center, 2=right
    player_x: u16 = LANE_X[1], // actual pixel X — slides toward target lane
    obstacles: [MAX_OBSTACLES]Obstacle = [_]Obstacle{.{ .lane = 0, .y = -100, .active = false, .color_idx = 0 }} ** MAX_OBSTACLES,
    scroll_offset: u16 = 0, // road marking scroll
    speed: u16 = 2, // pixels per tick
    score: u32 = 0,
    distance: u32 = 0,
    phase: GamePhase = .playing,
    tick_count: u32 = 0,
    rng_state: u32 = 54321,
    spawn_cooldown: u8 = 0,
    crash_timer: u8 = 0, // frames of crash animation
    sound: SoundEvent = .none,
    last_milestone: u32 = 0,
    prev_spawn_lane: u8 = 255, // last spawned lane (avoid same lane twice in a row)
};

pub const GameEvent = union(enum) {
    tick,
    move_left,
    move_right,
    restart,
};

pub const Store = state_lib.Store(GameState, GameEvent);

// ============================================================================
// Reducer
// ============================================================================

pub fn reduce(state: *GameState, event: GameEvent) void {
    // Clear sound event each frame (one-shot)
    state.sound = .none;

    switch (event) {
        .tick => tickUpdate(state),
        .move_left => {
            if (state.phase != .playing) return;
            if (state.player_lane > 0) {
                state.player_lane -= 1;
                state.sound = .lane_switch;
            }
        },
        .move_right => {
            if (state.phase != .playing) return;
            if (state.player_lane < LANE_COUNT - 1) {
                state.player_lane += 1;
                state.sound = .lane_switch;
            }
        },
        .restart => {
            const seed = state.rng_state +% 1;
            state.* = .{};
            state.rng_state = seed;
        },
    }
}

fn tickUpdate(state: *GameState) void {
    if (state.phase == .game_over) return;

    if (state.phase == .crashed) {
        state.crash_timer += 1;
        if (state.crash_timer >= 30) {
            state.phase = .game_over;
        }
        return;
    }

    state.tick_count += 1;

    // ---- Smooth lane slide animation ----
    // player_x slides toward target lane at 6px/tick (~4 frames to cross)
    const target_x = LANE_X[state.player_lane];
    if (state.player_x < target_x) {
        state.player_x = @min(target_x, state.player_x + 6);
    } else if (state.player_x > target_x) {
        state.player_x = if (target_x + 6 > state.player_x) target_x else state.player_x - 6;
    }

    // Scroll road markings
    state.scroll_offset = (state.scroll_offset + state.speed) % (MARK_H + MARK_GAP);

    // Move obstacles down
    for (&state.obstacles) |*obs| {
        if (!obs.active) continue;
        obs.y += @intCast(state.speed);
        if (obs.y > SCREEN_H + OBS_H) {
            obs.active = false;
            state.score += 10;
        }
    }

    // Score and distance
    state.distance += state.speed;

    // Speed increases every 800 distance (slower ramp)
    const target_speed = 2 + @as(u16, @intCast(@min(state.distance / 800, 6)));
    if (state.speed < target_speed) {
        state.speed = target_speed;
    }

    // Milestone sound every 1000 points
    const milestone = state.score / 100;
    if (milestone > state.last_milestone) {
        state.last_milestone = milestone;
        state.sound = .milestone;
    }

    // Spawn obstacles — generous spacing
    if (state.spawn_cooldown > 0) {
        state.spawn_cooldown -= 1;
    } else {
        spawnObstacle(state);
        // Cooldown: at least ~3 car-lengths between obstacles
        // min_gap = (CAR_H * 3) / speed ≈ 108/speed ticks
        // At speed 2: cooldown=54, at speed 8: cooldown=14
        const min_gap_pixels: u32 = CAR_H * 3 + OBS_H; // ~140px
        const cooldown_ticks = @as(u8, @intCast(@min(120, @max(12, min_gap_pixels / state.speed))));
        state.spawn_cooldown = cooldown_ticks;
    }

    // Collision check — use actual player_x (animated position)
    for (state.obstacles) |obs| {
        if (!obs.active) continue;
        const obs_x = LANE_X[obs.lane];
        if (obs.y + OBS_H > CAR_Y and obs.y < CAR_Y + CAR_H and
            obs_x + OBS_W > state.player_x and obs_x < state.player_x + CAR_W)
        {
            state.phase = .crashed;
            state.crash_timer = 0;
            state.sound = .crash;
            return;
        }
    }
}

fn spawnObstacle(state: *GameState) void {
    // Find inactive slot
    for (&state.obstacles) |*obs| {
        if (obs.active) continue;

        // Pick a lane, avoiding same lane as previous spawn
        var lane: u8 = @intCast(nextRng(state) % LANE_COUNT);
        if (lane == state.prev_spawn_lane) {
            lane = @intCast((lane + 1) % LANE_COUNT);
        }
        state.prev_spawn_lane = lane;

        obs.* = .{
            .lane = lane,
            .y = -@as(i16, OBS_H),
            .active = true,
            .color_idx = @intCast(nextRng(state) % OBS_COLORS.len),
        };
        return;
    }
}

pub fn nextRng(state: *GameState) u32 {
    state.rng_state = state.rng_state *% 1103515245 +% 12345;
    return (state.rng_state >> 16) & 0x7FFF;
}

// ============================================================================
// Render
// ============================================================================

/// Full render — draws everything.
pub fn render(fb: *FB, state: *const GameState, prev: *const GameState) void {
    _ = prev;

    // Background: grass
    fb.fillRect(0, 0, ROAD_LEFT, SCREEN_H, GRASS_COLOR);
    fb.fillRect(ROAD_RIGHT, 0, SCREEN_W - ROAD_RIGHT, SCREEN_H, GRASS_COLOR);

    // Road surface
    fb.fillRect(ROAD_LEFT, 0, ROAD_W, SCREEN_H, ROAD_COLOR);

    // Road edge lines
    fb.fillRect(ROAD_LEFT, 0, 2, SCREEN_H, WHITE);
    fb.fillRect(ROAD_RIGHT - 2, 0, 2, SCREEN_H, WHITE);

    // Lane markings (scrolling dashes)
    drawLaneMarkings(fb, state.scroll_offset);

    // Obstacles
    for (state.obstacles) |obs| {
        if (!obs.active) continue;
        if (obs.y + OBS_H <= 0) continue;
        drawObstacle(fb, LANE_X[obs.lane], obs.y, OBS_COLORS[obs.color_idx]);
    }

    // Player car — uses animated player_x for smooth lane slide
    if (state.phase == .crashed) {
        const flash = if (state.crash_timer % 4 < 2) CRASH_COLOR else WHITE;
        drawCar(fb, state.player_x, CAR_Y, flash, flash);
    } else if (state.phase != .game_over) {
        drawCar(fb, state.player_x, CAR_Y, PLAYER_COLOR, PLAYER_WIND);
    }

    // HUD: score at top
    fb.fillRect(2, 2, 36, 9, BLACK);
    drawNumber(fb, 2, 2, state.score);

    // HUD: speed indicator (right side)
    fb.fillRect(SCREEN_W - 30, 2, 28, 9, BLACK);
    drawNumber(fb, SCREEN_W - 30, 2, state.speed);

    // Game over text overlay
    if (state.phase == .game_over) {
        fb.fillRect(50, 100, 140, 40, BLACK);
        fb.drawRect(50, 100, 140, 40, WHITE, 1);
        // "GAME OVER" — simple block text
        fb.fillRect(70, 110, 4, 4, WHITE); // G approximation
        fb.fillRect(76, 110, 4, 4, WHITE);
        fb.fillRect(82, 110, 4, 4, WHITE);
        fb.fillRect(88, 110, 4, 4, WHITE);
        // Score below
        drawNumber(fb, 90, 125, state.score);
    }
}

fn drawLaneMarkings(fb: *FB, offset: u16) void {
    // Two lane dividers between 3 lanes
    const dividers = [_]u16{
        ROAD_LEFT + LANE_W - MARK_W / 2,
        ROAD_LEFT + 2 * LANE_W - MARK_W / 2,
    };
    for (dividers) |dx| {
        var y: i16 = -@as(i16, MARK_H) + @as(i16, @intCast(offset));
        while (y < SCREEN_H) {
            if (y + MARK_H > 0) {
                const draw_y: u16 = if (y < 0) 0 else @intCast(y);
                const draw_h: u16 = if (y < 0)
                    @intCast(MARK_H - @as(u16, @intCast(-y)))
                else
                    @min(MARK_H, SCREEN_H - draw_y);
                if (draw_h > 0) {
                    fb.fillRect(dx, draw_y, MARK_W, draw_h, MARK_COLOR);
                }
            }
            y += @as(i16, MARK_H + MARK_GAP);
        }
    }
}

fn drawCar(fb: *FB, x: u16, y: u16, body: u16, windshield: u16) void {
    // Car body
    fb.fillRect(x, y, CAR_W, CAR_H, body);
    // Windshield (top portion)
    fb.fillRect(x + 3, y + 3, CAR_W - 6, 8, windshield);
    // Rear lights
    fb.fillRect(x + 1, y + CAR_H - 4, 4, 3, 0xFFE0); // yellow left
    fb.fillRect(x + CAR_W - 5, y + CAR_H - 4, 4, 3, 0xFFE0); // yellow right
    // Center stripe
    fb.fillRect(x + CAR_W / 2 - 1, y + 12, 2, CAR_H - 16, windshield);
}

fn drawObstacle(fb: *FB, x: u16, y_raw: i16, color: u16) void {
    // Off-screen checks
    if (y_raw + @as(i16, OBS_H) <= 0) return; // above screen
    if (y_raw >= SCREEN_H) return; // below screen

    const y: u16 = if (y_raw < 0) 0 else @intCast(y_raw);
    const h: u16 = if (y_raw < 0)
        @intCast(@as(i16, OBS_H) + y_raw) // OBS_H + negative y_raw = visible portion
    else
        @min(OBS_H, SCREEN_H - y);
    if (h == 0) return;

    // Obstacle body
    fb.fillRect(x, y, OBS_W, h, color);
    // Dark outline
    if (h > 2) {
        fb.fillRect(x, y, OBS_W, 1, BLACK);
        if (y + h < SCREEN_H) fb.fillRect(x, y + h - 1, OBS_W, 1, BLACK);
        fb.fillRect(x, y, 1, h, BLACK);
        if (x + OBS_W > 0) fb.fillRect(x + OBS_W - 1, y, 1, h, BLACK);
    }
}

// ============================================================================
// Number rendering (same as Tetris — 5x7 digit bitmaps)
// ============================================================================

const DIGIT_BITMAPS = [10][7]u8{
    .{ 0x70, 0x88, 0x98, 0xA8, 0xC8, 0x88, 0x70 }, // 0
    .{ 0x20, 0x60, 0x20, 0x20, 0x20, 0x20, 0x70 }, // 1
    .{ 0x70, 0x88, 0x08, 0x10, 0x20, 0x40, 0xF8 }, // 2
    .{ 0x70, 0x88, 0x08, 0x30, 0x08, 0x88, 0x70 }, // 3
    .{ 0x10, 0x30, 0x50, 0x90, 0xF8, 0x10, 0x10 }, // 4
    .{ 0xF8, 0x80, 0xF0, 0x08, 0x08, 0x88, 0x70 }, // 5
    .{ 0x30, 0x40, 0x80, 0xF0, 0x88, 0x88, 0x70 }, // 6
    .{ 0xF8, 0x08, 0x10, 0x20, 0x40, 0x40, 0x40 }, // 7
    .{ 0x70, 0x88, 0x88, 0x70, 0x88, 0x88, 0x70 }, // 8
    .{ 0x70, 0x88, 0x88, 0x78, 0x08, 0x10, 0x60 }, // 9
};

pub fn drawNumber(fb: *FB, x: u16, y: u16, value: u32) void {
    var buf: [10]u8 = undefined;
    const digits = formatDecimal(value, &buf);
    var cx = x;
    for (digits) |d| {
        drawDigit(fb, cx, y, d);
        cx += 6;
    }
}

pub fn formatDecimal(value: u32, buf: *[10]u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = value;
    var i: usize = 10;
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
    }
    return buf[i..10];
}

fn drawDigit(fb: *FB, x: u16, y: u16, char: u8) void {
    if (char < '0' or char > '9') return;
    const bitmap = &DIGIT_BITMAPS[char - '0'];
    for (0..7) |row| {
        for (0..5) |col| {
            const bit = @as(u8, 0x80) >> @intCast(col);
            if (bitmap[row] & bit != 0) {
                fb.setPixel(x + @as(u16, @intCast(col)), y + @as(u16, @intCast(row)), SCORE_COLOR);
            }
        }
    }
}
