//! Snake Game — LVGL canvas-based
//!
//! 15x15 grid on 240x240 screen (16px per cell).
//! vol_up/vol_down/left/right = direction
//! confirm = start/restart
//! back = return to menu (handled by app.zig)

const c = @import("lvgl").c;
const platform = @import("platform.zig");
const ButtonId = platform.ButtonId;

// ============================================================================
// Constants
// ============================================================================

const GRID = 15;
const CELL = 16; // pixels per cell (GRID * CELL = 240)
const MAX_SNAKE = GRID * GRID;

const COLOR_BG = 0x0a0a1e;
const COLOR_GRID = 0x151530;
const COLOR_SNAKE = 0x4ade80;
const COLOR_HEAD = 0x86efac;
const COLOR_FOOD = 0xf87171;
const COLOR_TEXT = 0xccccee;
const COLOR_DIM = 0x666688;

// ============================================================================
// State
// ============================================================================

const Dir = enum { up, down, left, right };
const GameState = enum { waiting, playing, dead };

var game_state: GameState = .waiting;
var dir: Dir = .right;
var next_dir: Dir = .right;

// Snake body (ring buffer)
var snake_x: [MAX_SNAKE]u8 = undefined;
var snake_y: [MAX_SNAKE]u8 = undefined;
var snake_len: u16 = 3;
var snake_head: u16 = 2;

// Food
var food_x: u8 = 10;
var food_y: u8 = 7;

// Score & timing
var score: u16 = 0;
var tick_count: u32 = 0;
var speed: u32 = 8; // frames per move (lower = faster)

// PRNG (simple LCG)
var rng_state: u32 = 12345;

fn rng() u32 {
    rng_state = rng_state *% 1103515245 +% 12345;
    return (rng_state >> 16) & 0x7FFF;
}

fn rngRange(max: u8) u8 {
    return @intCast(rng() % @as(u32, max));
}

// ============================================================================
// LVGL Objects
// ============================================================================

var screen: ?*c.lv_obj_t = null;
var canvas: ?*c.lv_obj_t = null;
var lbl_score: ?*c.lv_obj_t = null;
var lbl_status: ?*c.lv_obj_t = null;

// Canvas buffer (240 * 240 * 2 bytes for RGB565)
var canvas_buf: [240 * 240 * 2]u8 align(4) = undefined;

// ============================================================================
// Init / Deinit
// ============================================================================

pub fn init() void {
    screen = c.lv_obj_create(null);
    if (screen == null) return;
    c.lv_obj_set_style_bg_color(screen.?, c.lv_color_hex(COLOR_BG), 0);

    // Canvas for game field
    canvas = c.lv_canvas_create(screen.?);
    c.lv_canvas_set_buffer(canvas.?, &canvas_buf, 240, 240, c.LV_COLOR_FORMAT_RGB565);
    c.lv_obj_align(canvas.?, c.LV_ALIGN_CENTER, 0, 0);

    // Score label (top-left, on top of canvas)
    lbl_score = c.lv_label_create(screen.?);
    c.lv_label_set_text(lbl_score, "Score: 0");
    c.lv_obj_set_style_text_color(lbl_score, c.lv_color_hex(COLOR_TEXT), 0);
    c.lv_obj_align(lbl_score, c.LV_ALIGN_TOP_LEFT, 4, 2);

    // Status label (center)
    lbl_status = c.lv_label_create(screen.?);
    c.lv_label_set_text(lbl_status, "Press OK to start");
    c.lv_obj_set_style_text_color(lbl_status, c.lv_color_hex(COLOR_DIM), 0);
    c.lv_obj_align(lbl_status, c.LV_ALIGN_CENTER, 0, 0);

    resetGame();
    drawField();
    c.lv_screen_load(screen.?);
}

pub fn deinit() void {
    // LVGL objects are cleaned up when screen is deleted
    if (screen) |s| {
        c.lv_obj_delete(s);
        screen = null;
        canvas = null;
        lbl_score = null;
        lbl_status = null;
    }
}

// ============================================================================
// Game Logic
// ============================================================================

fn resetGame() void {
    snake_len = 3;
    snake_head = 2;
    // Start in center, going right
    snake_x[0] = GRID / 2 - 2;
    snake_y[0] = GRID / 2;
    snake_x[1] = GRID / 2 - 1;
    snake_y[1] = GRID / 2;
    snake_x[2] = GRID / 2;
    snake_y[2] = GRID / 2;
    dir = .right;
    next_dir = .right;
    score = 0;
    speed = 8;
    tick_count = 0;
    spawnFood();
}

fn spawnFood() void {
    // Try random positions until we find one not on the snake
    var attempts: u16 = 0;
    while (attempts < 200) : (attempts += 1) {
        const fx = rngRange(GRID);
        const fy = rngRange(GRID);
        if (!isSnake(fx, fy)) {
            food_x = fx;
            food_y = fy;
            return;
        }
    }
}

fn isSnake(x: u8, y: u8) bool {
    var i: u16 = 0;
    while (i < snake_len) : (i += 1) {
        const idx = (snake_head + MAX_SNAKE - i) % MAX_SNAKE;
        if (snake_x[idx] == x and snake_y[idx] == y) return true;
    }
    return false;
}

fn moveSnake() void {
    const hx = snake_x[snake_head];
    const hy = snake_y[snake_head];

    var nx: i16 = @intCast(hx);
    var ny: i16 = @intCast(hy);

    dir = next_dir;
    switch (dir) {
        .up => ny -= 1,
        .down => ny += 1,
        .left => nx -= 1,
        .right => nx += 1,
    }

    // Wall collision
    if (nx < 0 or nx >= GRID or ny < 0 or ny >= GRID) {
        game_state = .dead;
        return;
    }

    const new_x: u8 = @intCast(nx);
    const new_y: u8 = @intCast(ny);

    // Self collision (check before adding new head)
    if (isSnake(new_x, new_y)) {
        game_state = .dead;
        return;
    }

    // Advance head
    snake_head = (snake_head + 1) % MAX_SNAKE;
    snake_x[snake_head] = new_x;
    snake_y[snake_head] = new_y;

    // Check food
    if (new_x == food_x and new_y == food_y) {
        snake_len += 1;
        score += 10;
        if (speed > 3) speed -= 1; // speed up
        spawnFood();
        updateScore();
    } else {
        // No growth — length stays the same (tail advances implicitly)
    }
}

fn updateScore() void {
    if (lbl_score == null) return;
    var buf: [32]u8 = undefined;
    const text = formatScore(&buf);
    c.lv_label_set_text(lbl_score, text.ptr);
}

fn formatScore(buf: []u8) [:0]const u8 {
    // "Score: NNN"
    const prefix = "Score: ";
    @memcpy(buf[0..prefix.len], prefix);
    var pos = prefix.len;
    var val = score;
    if (val == 0) {
        buf[pos] = '0';
        pos += 1;
    } else {
        var digits: [6]u8 = undefined;
        var dlen: usize = 0;
        while (val > 0) {
            digits[dlen] = @intCast('0' + val % 10);
            val /= 10;
            dlen += 1;
        }
        var d: usize = dlen;
        while (d > 0) {
            d -= 1;
            buf[pos] = digits[d];
            pos += 1;
        }
    }
    buf[pos] = 0;
    return buf[0..pos :0];
}

// ============================================================================
// Drawing
// ============================================================================

fn drawField() void {
    if (canvas == null) return;

    // Fill background
    c.lv_canvas_fill_bg(canvas.?, c.lv_color_hex(COLOR_BG), c.LV_OPA_COVER);

    // Draw grid lines
    var i: u16 = 0;
    while (i <= GRID) : (i += 1) {
        const pos: i32 = @intCast(i * CELL);
        // Vertical
        var y: i32 = 0;
        while (y < 240) : (y += 1) {
            c.lv_canvas_set_px(canvas.?, pos, y, c.lv_color_hex(COLOR_GRID), c.LV_OPA_COVER);
        }
        // Horizontal
        var x: i32 = 0;
        while (x < 240) : (x += 1) {
            c.lv_canvas_set_px(canvas.?, x, pos, c.lv_color_hex(COLOR_GRID), c.LV_OPA_COVER);
        }
    }

    // Draw food
    fillCell(food_x, food_y, COLOR_FOOD);

    // Draw snake
    var s: u16 = 0;
    while (s < snake_len) : (s += 1) {
        const idx = (snake_head + MAX_SNAKE - s) % MAX_SNAKE;
        const color: u32 = if (s == 0) COLOR_HEAD else COLOR_SNAKE;
        fillCell(snake_x[idx], snake_y[idx], color);
    }

    c.lv_obj_invalidate(canvas.?);
}

fn fillCell(gx: u8, gy: u8, color: u32) void {
    if (canvas == null) return;
    const x0: i32 = @as(i32, gx) * CELL + 1;
    const y0: i32 = @as(i32, gy) * CELL + 1;
    const col = c.lv_color_hex(color);
    var dy: i32 = 0;
    while (dy < CELL - 1) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < CELL - 1) : (dx += 1) {
            c.lv_canvas_set_px(canvas.?, x0 + dx, y0 + dy, col, c.LV_OPA_COVER);
        }
    }
}

// ============================================================================
// Step (called each frame)
// ============================================================================

pub fn step(btn: ?ButtonId) void {
    // Handle input
    if (btn) |b| {
        switch (game_state) {
            .waiting => {
                if (b == .confirm) {
                    game_state = .playing;
                    if (lbl_status) |s| c.lv_obj_add_flag(s, c.LV_OBJ_FLAG_HIDDEN);
                    rng_state +%= tick_count; // seed from timing
                }
            },
            .playing => {
                switch (b) {
                    .vol_up => if (dir != .down) {
                        next_dir = .up;
                    },
                    .vol_down => if (dir != .up) {
                        next_dir = .down;
                    },
                    .left => if (dir != .right) {
                        next_dir = .left;
                    },
                    .right => if (dir != .left) {
                        next_dir = .right;
                    },
                    else => {},
                }
            },
            .dead => {
                if (b == .confirm) {
                    resetGame();
                    game_state = .waiting;
                    if (lbl_status) |s| {
                        c.lv_label_set_text(s, "Press OK to start");
                        c.lv_obj_clear_flag(s, c.LV_OBJ_FLAG_HIDDEN);
                    }
                    updateScore();
                }
            },
        }
    }

    tick_count += 1;

    // Move snake at game speed
    if (game_state == .playing and tick_count % speed == 0) {
        moveSnake();

        if (game_state == .dead) {
            if (lbl_status) |s| {
                c.lv_label_set_text(s, "Game Over! Press OK");
                c.lv_obj_clear_flag(s, c.LV_OBJ_FLAG_HIDDEN);
                c.lv_obj_set_style_text_color(s, c.lv_color_hex(COLOR_FOOD), 0);
            }
        }
    }

    drawField();
}
