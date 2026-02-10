//! LED Strip Animation Demo
//!
//! Cycles through colorful patterns on the 9 LED strip.
//! confirm = next pattern, back = return to menu

const c = @import("lvgl").c;
const hal = @import("hal");
const platform = @import("platform.zig");
const Board = platform.Board;
const ButtonId = platform.ButtonId;

const NUM_LEDS = 9;

// ============================================================================
// State
// ============================================================================

const Pattern = enum { rainbow, pulse, chase, breathe };

var pattern: Pattern = .rainbow;
var screen: ?*c.lv_obj_t = null;
var lbl_name: ?*c.lv_obj_t = null;
var tick: u32 = 0;

// ============================================================================
// Init / Deinit
// ============================================================================

pub fn init(board: *Board) void {
    _ = board;
    screen = c.lv_obj_create(null);
    if (screen == null) return;
    c.lv_obj_set_style_bg_color(screen.?, c.lv_color_hex(0x1a1a2e), 0);

    const title = c.lv_label_create(screen.?);
    c.lv_label_set_text(title, "LED Demo");
    c.lv_obj_set_style_text_color(title, c.lv_color_hex(0x6c8cff), 0);
    c.lv_obj_align(title, c.LV_ALIGN_TOP_MID, 0, 30);

    lbl_name = c.lv_label_create(screen.?);
    c.lv_label_set_text(lbl_name, "Rainbow");
    c.lv_obj_set_style_text_color(lbl_name, c.lv_color_hex(0xffffff), 0);
    c.lv_obj_set_style_text_font(lbl_name, &c.lv_font_montserrat_20, 0);
    c.lv_obj_align(lbl_name, c.LV_ALIGN_CENTER, 0, 0);

    const hint = c.lv_label_create(screen.?);
    c.lv_label_set_text(hint, "OK = next pattern");
    c.lv_obj_set_style_text_color(hint, c.lv_color_hex(0x666688), 0);
    c.lv_obj_align(hint, c.LV_ALIGN_BOTTOM_MID, 0, -30);

    tick = 0;
    pattern = .rainbow;
    c.lv_screen_load(screen.?);
}

pub fn deinit(board: *Board) void {
    board.rgb_leds.clear();
    board.rgb_leds.refresh();
    if (screen) |s| {
        c.lv_obj_delete(s);
        screen = null;
        lbl_name = null;
    }
}

// ============================================================================
// Step
// ============================================================================

pub fn step(board: *Board, btn: ?ButtonId) void {
    if (btn) |b| {
        if (b == .confirm) {
            pattern = switch (pattern) {
                .rainbow => .pulse,
                .pulse => .chase,
                .chase => .breathe,
                .breathe => .rainbow,
            };
            if (lbl_name) |lbl| {
                c.lv_label_set_text(lbl, switch (pattern) {
                    .rainbow => "Rainbow",
                    .pulse => "Pulse",
                    .chase => "Chase",
                    .breathe => "Breathe",
                });
            }
        }
    }

    tick += 1;

    switch (pattern) {
        .rainbow => rainbowPattern(board),
        .pulse => pulsePattern(board),
        .chase => chasePattern(board),
        .breathe => breathePattern(board),
    }
    board.rgb_leds.refresh();
}

// ============================================================================
// Patterns
// ============================================================================

fn rainbowPattern(board: *Board) void {
    const offset: u8 = @truncate(tick *% 3);
    for (0..NUM_LEDS) |i| {
        const hue: u8 = offset +% @as(u8, @intCast(i * 28));
        const color = hsvToRgb(hue, 255, 200);
        board.rgb_leds.setPixel(@intCast(i), color);
    }
}

fn pulsePattern(board: *Board) void {
    // All LEDs same color, brightness pulses
    const phase = tick % 120;
    const bright: u8 = if (phase < 60)
        @intCast(phase * 4)
    else
        @intCast((120 - phase) * 4);
    const color = hal.Color.rgb(bright, 0, bright / 2);
    for (0..NUM_LEDS) |i| {
        board.rgb_leds.setPixel(@intCast(i), color);
    }
}

fn chasePattern(board: *Board) void {
    // Single bright LED chasing around
    const pos = (tick / 4) % NUM_LEDS;
    for (0..NUM_LEDS) |i| {
        if (i == pos) {
            board.rgb_leds.setPixel(@intCast(i), hal.Color.rgb(0, 200, 255));
        } else {
            board.rgb_leds.setPixel(@intCast(i), hal.Color.rgb(0, 10, 20));
        }
    }
}

fn breathePattern(board: *Board) void {
    // Warm white breathe
    const phase: u16 = @intCast(tick % 180);
    const v: u16 = if (phase < 90)
        phase * 2
    else
        (180 - phase) * 2;
    const bright: u8 = @intCast(@min(v, 255));
    const color = hal.Color.rgb(bright, bright * 3 / 4, bright / 3);
    for (0..NUM_LEDS) |i| {
        board.rgb_leds.setPixel(@intCast(i), color);
    }
}

// ============================================================================
// Color Helpers
// ============================================================================

fn hsvToRgb(h: u8, s: u8, v: u8) hal.Color {
    if (s == 0) return hal.Color.rgb(v, v, v);

    const region = h / 43;
    const remainder = (h - (region * 43)) * 6;

    const p: u8 = @intCast((@as(u16, v) * (255 - s)) >> 8);
    const q: u8 = @intCast((@as(u16, v) * (255 - ((@as(u16, s) * remainder) >> 8))) >> 8);
    const t: u8 = @intCast((@as(u16, v) * (255 - ((@as(u16, s) * (255 - remainder)) >> 8))) >> 8);

    return switch (region) {
        0 => hal.Color.rgb(v, t, p),
        1 => hal.Color.rgb(q, v, p),
        2 => hal.Color.rgb(p, v, t),
        3 => hal.Color.rgb(p, q, v),
        4 => hal.Color.rgb(t, p, v),
        else => hal.Color.rgb(v, p, q),
    };
}
