//! Virtual Pet — Tamagotchi-style pixel pet
//!
//! Feed, play, and keep your pet happy!
//! left = feed, right = play, confirm = sleep, vol_up/down = pet

const c = @import("lvgl").c;
const ButtonId = @import("platform.zig").ButtonId;

var screen: ?*c.lv_obj_t = null;
var canvas: ?*c.lv_obj_t = null;
var lbl_status: ?*c.lv_obj_t = null;
var lbl_stats: ?*c.lv_obj_t = null;
var canvas_buf: [240 * 240 * 2]u8 align(4) = undefined;

var hunger: i16 = 50;
var happiness: i16 = 50;
var energy: i16 = 50;
var tick: u32 = 0;
var pet_y: i16 = 120; // bounce offset
var pet_dir: i16 = -1;
var frame_anim: u8 = 0;
var action_msg: [*:0]const u8 = "Press keys!";

pub fn init() void {
    screen = c.lv_obj_create(null);
    c.lv_obj_set_style_bg_color(screen.?, c.lv_color_hex(0x0a0a1e), 0);

    canvas = c.lv_canvas_create(screen.?);
    c.lv_canvas_set_buffer(canvas.?, &canvas_buf, 240, 240, c.LV_COLOR_FORMAT_RGB565);
    c.lv_obj_align(canvas.?, c.LV_ALIGN_TOP_LEFT, 0, 0);

    lbl_stats = c.lv_label_create(screen.?);
    c.lv_obj_set_style_text_color(lbl_stats, c.lv_color_hex(0x888899), 0);
    c.lv_obj_align(lbl_stats, c.LV_ALIGN_TOP_LEFT, 8, 4);

    lbl_status = c.lv_label_create(screen.?);
    c.lv_obj_set_style_text_color(lbl_status, c.lv_color_hex(0x6c8cff), 0);
    c.lv_obj_align(lbl_status, c.LV_ALIGN_BOTTOM_MID, 0, -8);

    hunger = 50;
    happiness = 50;
    energy = 50;
    c.lv_screen_load(screen.?);
}

pub fn deinit() void {
    if (screen) |s| { c.lv_obj_delete(s); screen = null; canvas = null; }
}

pub fn step(btn: ?ButtonId) void {
    tick += 1;
    if (btn) |b| switch (b) {
        .left => { hunger = clamp(hunger + 15); action_msg = "Yum!"; },
        .right => { happiness = clamp(happiness + 15); action_msg = "Fun!"; },
        .confirm => { energy = clamp(energy + 20); action_msg = "Zzz..."; },
        .vol_up, .vol_down => { happiness = clamp(happiness + 5); action_msg = "Purr~"; },
        else => {},
    };

    // Decay over time
    if (tick % 60 == 0) {
        hunger = clamp(hunger - 2);
        happiness = clamp(happiness - 1);
        energy = clamp(energy - 1);
    }

    // Bounce animation
    if (tick % 4 == 0) {
        pet_y += pet_dir;
        if (pet_y <= 115 or pet_y >= 125) pet_dir = -pet_dir;
        frame_anim +%= 1;
    }

    draw();
    updateLabels();
}

fn clamp(v: i16) i16 {
    return if (v < 0) 0 else if (v > 100) 100 else v;
}

fn draw() void {
    if (canvas == null) return;
    c.lv_canvas_fill_bg(canvas.?, c.lv_color_hex(0x0a0a1e), c.LV_OPA_COVER);

    // Ground
    fillRect(0, 180, 240, 60, 0x151530);

    // Pet body (simple pixel art - round blob)
    const mood_color: u32 = if (happiness > 60) 0x4ade80 else if (happiness > 30) 0xfbbf24 else 0xf87171;
    const cx: i32 = 120;
    const cy: i32 = pet_y;

    // Body
    fillRect(cx - 16, cy - 12, 32, 28, mood_color);
    fillRect(cx - 20, cy - 8, 40, 20, mood_color);

    // Eyes
    const eye_y = cy - 4;
    const blink = frame_anim % 16 == 0;
    if (blink) {
        fillRect(cx - 8, eye_y, 4, 2, 0x0a0a1e);
        fillRect(cx + 4, eye_y, 4, 2, 0x0a0a1e);
    } else {
        fillRect(cx - 8, eye_y - 2, 4, 5, 0x0a0a1e);
        fillRect(cx + 4, eye_y - 2, 4, 5, 0x0a0a1e);
        fillRect(cx - 7, eye_y - 1, 2, 3, 0xffffff);
        fillRect(cx + 5, eye_y - 1, 2, 3, 0xffffff);
    }

    // Mouth
    if (happiness > 60) {
        fillRect(cx - 4, cy + 6, 8, 2, 0x0a0a1e); // smile
    } else if (happiness < 30) {
        fillRect(cx - 4, cy + 8, 8, 2, 0x0a0a1e); // frown
    }

    // Feet
    fillRect(cx - 14, cy + 16, 8, 4, mood_color);
    fillRect(cx + 6, cy + 16, 8, 4, mood_color);

    // Stat bars background
    fillRect(20, 200, 200, 8, 0x222244);
    fillRect(20, 212, 200, 8, 0x222244);
    fillRect(20, 224, 200, 8, 0x222244);

    // Stat bars fill
    const hw: i32 = @divTrunc(@as(i32, hunger) * 200, 100);
    const hpw: i32 = @divTrunc(@as(i32, happiness) * 200, 100);
    const ew: i32 = @divTrunc(@as(i32, energy) * 200, 100);
    fillRect(20, 200, hw, 8, 0xf87171);
    fillRect(20, 212, hpw, 8, 0x4ade80);
    fillRect(20, 224, ew, 8, 0x6c8cff);

    c.lv_obj_invalidate(canvas.?);
}

fn updateLabels() void {
    if (lbl_stats) |l| c.lv_label_set_text(l, "< Feed  Play >  OK=Sleep");
    if (lbl_status) |l| c.lv_label_set_text(l, action_msg);
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    const col = c.lv_color_hex(color);
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const px = x + dx;
            const py = y + dy;
            if (px >= 0 and px < 240 and py >= 0 and py < 240) {
                c.lv_canvas_set_px(canvas.?, px, py, col, c.LV_OPA_COVER);
            }
        }
    }
}
