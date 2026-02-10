//! Breakout — Brick-breaking arcade game
//!
//! Paddle at bottom, ball bounces, break all bricks!
//! left/right = move paddle, confirm = launch/restart

const c = @import("lvgl").c;
const ButtonId = @import("platform.zig").ButtonId;

const W = 240;
const H = 240;
const BRICK_COLS = 10;
const BRICK_ROWS = 5;
const BRICK_W = 22;
const BRICK_H = 8;
const BRICK_GAP = 2;
const PADDLE_W = 40;
const PADDLE_H = 6;

var screen: ?*c.lv_obj_t = null;
var canvas: ?*c.lv_obj_t = null;
var lbl: ?*c.lv_obj_t = null;
var buf: [W * H * 2]u8 align(4) = undefined;

var bricks: [BRICK_ROWS * BRICK_COLS]bool = undefined;
var paddle_x: i32 = 100;
var bx: i32 = 120; // ball x (fixed point *16)
var by: i32 = 200;
var bdx: i32 = 3;
var bdy: i32 = -3;
var playing: bool = false;
var score: u16 = 0;
var lives: u8 = 3;
var tick: u32 = 0;

pub fn init() void {
    screen = c.lv_obj_create(null);
    c.lv_obj_set_style_bg_color(screen.?, c.lv_color_hex(0x0a0a1e), 0);
    canvas = c.lv_canvas_create(screen.?);
    c.lv_canvas_set_buffer(canvas.?, &buf, W, H, c.LV_COLOR_FORMAT_RGB565);
    lbl = c.lv_label_create(screen.?);
    c.lv_obj_set_style_text_color(lbl, c.lv_color_hex(0x888899), 0);
    c.lv_obj_align(lbl, c.LV_ALIGN_TOP_LEFT, 4, 2);
    reset();
    c.lv_screen_load(screen.?);
}

pub fn deinit() void {
    if (screen) |s| { c.lv_obj_delete(s); screen = null; canvas = null; }
}

fn reset() void {
    for (&bricks) |*b| b.* = true;
    paddle_x = 100;
    bx = 120;
    by = 200;
    bdx = 3;
    bdy = -3;
    playing = false;
    score = 0;
    lives = 3;
}

pub fn step(btn: ?ButtonId) void {
    tick += 1;
    if (btn) |b| switch (b) {
        .left => paddle_x -= 12,
        .right => paddle_x += 12,
        .confirm => {
            if (!playing) {
                if (lives == 0) reset();
                playing = true;
            }
        },
        else => {},
    };
    paddle_x = @max(0, @min(W - PADDLE_W, paddle_x));

    if (playing and tick % 2 == 0) {
        bx += bdx;
        by += bdy;

        // Wall bounce
        if (bx <= 2 or bx >= W - 4) bdx = -bdx;
        if (by <= 2) bdy = -bdy;

        // Paddle bounce
        if (by >= H - PADDLE_H - 8 and by <= H - PADDLE_H - 2 and bdy > 0) {
            if (bx >= paddle_x - 2 and bx <= paddle_x + PADDLE_W + 2) {
                bdy = -bdy;
                // Angle based on hit position
                const rel = bx - paddle_x - PADDLE_W / 2;
                bdx = @divTrunc(rel, 4);
                if (bdx == 0) bdx = if (bx < paddle_x + PADDLE_W / 2) @as(i32, -1) else 1;
            }
        }

        // Brick collision
        if (by >= 20 and by < 20 + BRICK_ROWS * (BRICK_H + BRICK_GAP)) {
            const row: usize = @intCast(@divTrunc(by - 20, BRICK_H + BRICK_GAP));
            const col: usize = @intCast(@divTrunc(bx, BRICK_W + BRICK_GAP));
            if (row < BRICK_ROWS and col < BRICK_COLS) {
                const idx = row * BRICK_COLS + col;
                if (bricks[idx]) {
                    bricks[idx] = false;
                    bdy = -bdy;
                    score += 10;
                }
            }
        }

        // Ball lost
        if (by >= H) {
            playing = false;
            lives -= 1;
            bx = paddle_x + PADDLE_W / 2;
            by = H - PADDLE_H - 12;
            bdx = 3;
            bdy = -3;
        }
    }

    draw();
}

fn draw() void {
    if (canvas == null) return;
    c.lv_canvas_fill_bg(canvas.?, c.lv_color_hex(0x0a0a1e), c.LV_OPA_COVER);

    // Bricks
    const colors = [_]u32{ 0xf87171, 0xfbbf24, 0x4ade80, 0x6c8cff, 0xc084fc };
    for (0..BRICK_ROWS) |row| {
        for (0..BRICK_COLS) |col| {
            if (bricks[row * BRICK_COLS + col]) {
                const x: i32 = @intCast(col * (BRICK_W + BRICK_GAP));
                const y: i32 = @intCast(20 + row * (BRICK_H + BRICK_GAP));
                fillRect(x, y, BRICK_W, BRICK_H, colors[row]);
            }
        }
    }

    // Paddle
    fillRect(paddle_x, H - PADDLE_H - 4, PADDLE_W, PADDLE_H, 0xffffff);

    // Ball
    fillRect(bx - 2, by - 2, 5, 5, 0xffffff);

    if (!playing and lives > 0) {
        // "Press OK" text area
        fillRect(60, 110, 120, 20, 0x222244);
    }

    c.lv_obj_invalidate(canvas.?);
    if (lbl) |l| {
        if (lives == 0) {
            c.lv_label_set_text(l, "Game Over! OK=retry");
        } else if (!playing) {
            c.lv_label_set_text(l, "Press OK to launch");
        } else {
            c.lv_label_set_text(l, "< >  Breakout");
        }
    }
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    const col = c.lv_color_hex(color);
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const px = x + dx;
            const py = y + dy;
            if (px >= 0 and px < W and py >= 0 and py < H)
                c.lv_canvas_set_px(canvas.?, px, py, col, c.LV_OPA_COVER);
        }
    }
}
