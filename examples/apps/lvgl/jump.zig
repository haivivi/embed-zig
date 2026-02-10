//! Jump — Doodle Jump style platformer
//!
//! Jump upward on platforms! Don't fall off the bottom!
//! left/right = move, auto-jump on platform contact.

const c = @import("lvgl").c;
const ButtonId = @import("platform.zig").ButtonId;

const W = 240;
const H = 240;
const MAX_PLATS = 12;
const PLAT_W = 40;
const PLAT_H = 6;
const PLAYER_W = 14;
const PLAYER_H = 16;

var screen: ?*c.lv_obj_t = null;
var canvas: ?*c.lv_obj_t = null;
var lbl: ?*c.lv_obj_t = null;
var buf: [W * H * 2]u8 align(4) = undefined;

var px: i32 = 113;
var py: i32 = 180;
var vy: i32 = -8; // upward velocity
var plats: [MAX_PLATS]Plat = undefined;
var score: u32 = 0;
var best: u32 = 0;
var camera_y: i32 = 0; // world scroll offset
var alive: bool = true;
var tick: u32 = 0;
var rng_state: u32 = 99;

const Plat = struct { x: i32, y: i32 };

fn rng() u32 {
    rng_state = rng_state *% 1103515245 +% 12345;
    return (rng_state >> 16) & 0x7FFF;
}

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
    px = 113;
    py = 180;
    vy = -8;
    camera_y = 0;
    score = 0;
    alive = true;
    // Generate platforms
    for (0..MAX_PLATS) |i| {
        plats[i] = .{
            .x = @intCast(rng() % (W - PLAT_W)),
            .y = @as(i32, @intCast(i)) * 22 + 40,
        };
    }
    // Starting platform under player
    plats[MAX_PLATS - 1] = .{ .x = 100, .y = 190 };
}

pub fn step(btn: ?ButtonId) void {
    tick += 1;
    if (btn) |b| switch (b) {
        .left => px -= 6,
        .right => px += 6,
        .confirm => if (!alive) { reset(); },
        else => {},
    };

    // Wrap horizontally
    if (px < -PLAYER_W) px = W;
    if (px > W) px = -PLAYER_W;

    if (!alive) { draw(); return; }

    if (tick % 2 == 0) {
        // Gravity
        vy += 1;
        py += vy;

        // Platform collision (only when falling)
        if (vy >= 0) {
            for (&plats) |p| {
                const screen_py = py - camera_y;
                const screen_plat_y = p.y - camera_y;
                _ = screen_py;
                if (py + PLAYER_H >= p.y and py + PLAYER_H <= p.y + PLAT_H + vy + 2) {
                    if (px + PLAYER_W > p.x and px < p.x + PLAT_W) {
                        py = p.y - PLAYER_H;
                        vy = -10; // bounce!
                    }
                }
                _ = screen_plat_y;
            }
        }

        // Camera follows player upward
        const screen_py = py - camera_y;
        if (screen_py < H / 3) {
            camera_y = py - H / 3;
        }

        // Recycle platforms that scrolled off bottom
        for (&plats) |*p| {
            if (p.y - camera_y > H + 20) {
                p.y = camera_y - 20;
                p.x = @intCast(rng() % (W - PLAT_W));
                score += 1;
                if (score > best) best = score;
            }
        }

        // Death: fell off bottom
        if (py - camera_y > H + 40) {
            alive = false;
        }
    }

    draw();
}

fn draw() void {
    if (canvas == null) return;
    c.lv_canvas_fill_bg(canvas.?, c.lv_color_hex(0x0a0a1e), c.LV_OPA_COVER);

    // Platforms
    for (plats) |p| {
        const sy = p.y - camera_y;
        if (sy >= -PLAT_H and sy < H) {
            fillRect(p.x, sy, PLAT_W, PLAT_H, 0x4ade80);
        }
    }

    // Player
    const spy = py - camera_y;
    if (alive) {
        fillRect(px, spy, PLAYER_W, PLAYER_H, 0xfbbf24);
        // Face
        fillRect(px + 3, spy + 3, 3, 3, 0x0a0a1e);
        fillRect(px + 8, spy + 3, 3, 3, 0x0a0a1e);
        if (vy < 0) {
            // Jumping face - happy
            fillRect(px + 4, spy + 9, 6, 2, 0x0a0a1e);
        } else {
            // Falling face - worried
            fillRect(px + 5, spy + 10, 4, 2, 0x0a0a1e);
        }
    }

    c.lv_obj_invalidate(canvas.?);
    if (lbl) |l| {
        if (!alive)
            c.lv_label_set_text(l, "Fell! OK=retry")
        else
            c.lv_label_set_text(l, "< >  Jump!");
    }
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    const col = c.lv_color_hex(color);
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const px2 = x + dx;
            const py2 = y + dy;
            if (px2 >= 0 and px2 < W and py2 >= 0 and py2 < H)
                c.lv_canvas_set_px(canvas.?, px2, py2, col, c.LV_OPA_COVER);
        }
    }
}
