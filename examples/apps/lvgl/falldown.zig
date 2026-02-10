//! Fall Down — "100 Floors" style game
//!
//! Player falls through gaps in rising platforms. Don't get pushed off top!
//! left/right = move, floors scroll up faster over time.

const c = @import("lvgl").c;
const ButtonId = @import("platform.zig").ButtonId;

const W = 240;
const H = 240;
const MAX_FLOORS = 8;
const FLOOR_H = 6;
const GAP_W = 40;
const PLAYER_W = 12;
const PLAYER_H = 12;

var screen: ?*c.lv_obj_t = null;
var canvas: ?*c.lv_obj_t = null;
var lbl: ?*c.lv_obj_t = null;
var buf: [W * H * 2]u8 align(4) = undefined;

var px: i32 = 114; // player x
var py: i32 = 20; // player y
var vy: i32 = 0; // vertical velocity
var floors: [MAX_FLOORS]Floor = undefined;
var floor_count: u8 = 0;
var scroll_speed: i32 = 1;
var score: u32 = 0;
var alive: bool = true;
var tick: u32 = 0;
var rng_state: u32 = 42;

const Floor = struct { y: i32, gap_x: i32 };

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
    px = 114;
    py = 20;
    vy = 0;
    score = 0;
    alive = true;
    scroll_speed = 1;
    floor_count = 0;
    // Initial floors
    var i: u8 = 0;
    while (i < MAX_FLOORS) : (i += 1) {
        floors[i] = .{
            .y = @as(i32, 60 + @as(i32, i) * 28),
            .gap_x = @intCast(rng() % (W - GAP_W)),
        };
        floor_count += 1;
    }
}

pub fn step(btn: ?ButtonId) void {
    tick += 1;
    if (btn) |b| switch (b) {
        .left => px -= 6,
        .right => px += 6,
        .confirm => if (!alive) reset(),
        else => {},
    };
    px = @max(0, @min(W - PLAYER_W, px));

    if (!alive) { draw(); return; }

    // Gravity
    vy += 1;
    if (vy > 6) vy = 6;
    py += vy;

    // Floor collision (only when falling)
    if (vy >= 0) {
        for (&floors) |*f| {
            if (py + PLAYER_H >= f.y and py + PLAYER_H <= f.y + FLOOR_H + 4) {
                // Check if player is in the gap
                if (px + PLAYER_W <= f.gap_x or px >= f.gap_x + GAP_W) {
                    // On solid floor — stop falling
                    py = f.y - PLAYER_H;
                    vy = 0;
                }
            }
        }
    }

    // Scroll floors up
    const spd = @max(3 - @divTrunc(scroll_speed, 2), 1);
    if (tick % @as(u32, @intCast(spd)) == 0) {
        for (&floors) |*f| {
            f.y -= scroll_speed;
            if (f.y < -FLOOR_H) {
                f.y = H + 10;
                f.gap_x = @intCast(rng() % (W - GAP_W));
                score += 1;
            }
        }
        // Player pushed up with floors
        py -= scroll_speed;

        // Speed up
        if (tick % 300 == 0 and scroll_speed < 4) scroll_speed += 1;
    }

    // Death: pushed off top
    if (py < -PLAYER_H) alive = false;
    // Death: fell off bottom
    if (py > H + 20) alive = false;

    draw();
}

fn draw() void {
    if (canvas == null) return;
    c.lv_canvas_fill_bg(canvas.?, c.lv_color_hex(0x0a0a1e), c.LV_OPA_COVER);

    // Floors
    for (&floors) |f| {
        if (f.y >= -FLOOR_H and f.y < H) {
            // Left part
            if (f.gap_x > 0)
                fillRect(0, f.y, f.gap_x, FLOOR_H, 0x334466);
            // Right part
            const right_x = f.gap_x + GAP_W;
            if (right_x < W)
                fillRect(right_x, f.y, W - right_x, FLOOR_H, 0x334466);
        }
    }

    // Player
    if (alive) {
        fillRect(px, py, PLAYER_W, PLAYER_H, 0x4ade80);
        fillRect(px + 2, py + 2, 3, 3, 0x0a0a1e); // eye
        fillRect(px + 7, py + 2, 3, 3, 0x0a0a1e); // eye
    }

    c.lv_obj_invalidate(canvas.?);
    if (lbl) |l| {
        if (!alive) {
            c.lv_label_set_text(l, "Dead! OK=retry");
        } else {
            c.lv_label_set_text(l, "< > Fall Down!");
        }
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
