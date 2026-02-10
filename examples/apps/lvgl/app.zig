//! LVGL Demo App — Multi-app menu system
//!
//! Platform-independent. Features:
//! - Long press power button 3s to boot / shutdown
//! - Main menu with app selection
//! - Snake game (playable with ADC buttons)
//! - LED strip animation demo
//! - About screen
//!
//! Navigation: vol_up/vol_down = scroll, confirm = enter, back = return

const hal = @import("hal");
const ui = @import("ui");
const lvgl = @import("lvgl");
const c = lvgl.c;

const platform = @import("platform.zig");
const Board = platform.Board;
const HalDisplay = platform.Display;
const ButtonId = platform.ButtonId;
const log = Board.log;

const snake = @import("snake.zig");
const led_demo = @import("led_demo.zig");

// ============================================================================
// State
// ============================================================================

const AppId = enum { menu, snake, led_demo, about };
const PowerState = enum { off, booting, on, shutting_down };

var board: Board = undefined;
var display_driver: HalDisplay.DriverType = undefined;
var hal_display: HalDisplay = undefined;
var ui_ctx: ui.Context(HalDisplay) = undefined;
var hw_ready: bool = false;

var power_state: PowerState = .off;
var current_app: AppId = .menu;
var menu_selection: u8 = 0;

// Power button tracking
var power_held: bool = false;
var power_hold_start: u64 = 0;
const POWER_HOLD_MS = 3000; // 3 seconds

// LVGL screens
var scr_cards: [3]?*c.lv_obj_t = .{ null, null, null };
var scr_about: ?*c.lv_obj_t = null;
var scr_power: ?*c.lv_obj_t = null;
var lbl_power: ?*c.lv_obj_t = null;
var power_bar: ?*c.lv_obj_t = null;

// Ultraman chest light blue
const LED_IDLE = hal.Color.rgb(0, 120, 255);

// LVGL symbols (Font Awesome glyphs in Montserrat)
const SYM_PLAY = "\xEF\x80\x9B"; // game/snake
const SYM_EYE = "\xEF\x81\xAE"; // LED/visual
const SYM_SETTINGS = "\xEF\x80\x93"; // about/info

const MenuEntry = struct {
    icon: [*:0]const u8,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
};

const menu_entries = [_]MenuEntry{
    .{ .icon = SYM_PLAY, .title = "Snake", .subtitle = "Classic arcade game" },
    .{ .icon = SYM_EYE, .title = "LED Demo", .subtitle = "Light animations" },
    .{ .icon = SYM_SETTINGS, .title = "About", .subtitle = "Device info" },
};

// ============================================================================
// Input
// ============================================================================

var last_btn: ?ButtonId = null;

fn pollInput() void {
    last_btn = null;

    board.buttons.poll();
    while (board.buttons.nextEvent()) |evt| {
        if (evt.action == .press or evt.action == .click) {
            last_btn = evt.id;
        }
    }

    // Power button: track held state for long-press
    const t = board.uptime();
    if (board.button.poll(t)) |evt| {
        if (evt.action == .press) {
            power_held = true;
            power_hold_start = t;
        }
        if (evt.action == .release) {
            power_held = false;
        }
    }
}

fn powerHeldMs() u64 {
    if (!power_held) return 0;
    const t = board.uptime();
    if (t < power_hold_start) return 0;
    return t - power_hold_start;
}

// ============================================================================
// Init (hardware only — UI starts after power-on)
// ============================================================================

pub fn init() void {
    log.info("LVGL Demo App", .{});

    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };

    board.rgb_leds.clear();
    board.rgb_leds.refresh();

    display_driver = HalDisplay.DriverType.init() catch {
        log.err("Display init failed", .{});
        return;
    };
    hal_display = HalDisplay.init(&display_driver);
    ui_ctx = ui.init(HalDisplay, &hal_display, .{ .buf_lines = 20 }) catch {
        log.err("UI init failed", .{});
        return;
    };
    hw_ready = true;

    // Show power-off screen
    powerScreenInit();
    power_state = .off;
    log.info("Hold POWER 3s to boot", .{});
}

// ============================================================================
// Step (called each frame ~60fps)
// ============================================================================

pub fn step() void {
    if (!hw_ready) return;
    pollInput();
    tick_counter += 1;

    // Unlock menu animation after duration
    if (menu_animating and tick_counter >= anim_unlock_at) {
        menu_animating = false;
    }

    switch (power_state) {
        .off => stepOff(),
        .booting => stepBooting(),
        .on => stepOn(),
        .shutting_down => stepShuttingDown(),
    }

    ui_ctx.tick(16);
    _ = ui_ctx.handler();
}

// ============================================================================
// Power States
// ============================================================================

fn stepOff() void {
    // Wait for power button hold
    if (power_held) {
        power_state = .booting;
        showPowerScreen("Booting...");
    }
}

fn stepBooting() void {
    const held = powerHeldMs();
    updatePowerBar(held);

    // LED progress: fill LEDs proportionally
    const progress = @min(held, POWER_HOLD_MS);
    const lit: u32 = @intCast(progress * 9 / POWER_HOLD_MS);
    for (0..9) |i| {
        if (i < lit) {
            board.rgb_leds.setPixel(@intCast(i), hal.Color.rgb(0, 100, 255));
        } else {
            board.rgb_leds.setPixel(@intCast(i), hal.Color.rgb(0, 0, 0));
        }
    }
    board.rgb_leds.refresh();

    if (!power_held) {
        // Released too early — back to off
        power_state = .off;
        board.rgb_leds.clear();
        board.rgb_leds.refresh();
        showPowerScreen("Hold POWER 3s");
        return;
    }

    if (held >= POWER_HOLD_MS) {
        // Boot complete
        power_state = .on;
        power_held = false;
        log.info("Power ON", .{});
        // Ultraman chest light
        for (0..9) |i| {
            board.rgb_leds.setPixel(@intCast(i), LED_IDLE);
        }
        board.rgb_leds.refresh();
        menuInit();
    }
}

fn stepOn() void {
    // Normal operation
    switch (current_app) {
        .menu => menuStep(),
        .snake => snake.step(last_btn),
        .led_demo => led_demo.step(&board, last_btn),
        .about => aboutStep(),
    }

    // Back to menu from any sub-app
    if (current_app != .menu and last_btn != null and last_btn.? == .back) {
        switchTo(.menu);
    }

    // Power button held → start shutdown
    if (power_held and powerHeldMs() > 200) {
        power_state = .shutting_down;
        showPowerScreen("Shutting down...");
    }
}

fn stepShuttingDown() void {
    const held = powerHeldMs();
    updatePowerBar(held);

    // LED drain: LEDs turn off proportionally
    const progress = @min(held, POWER_HOLD_MS);
    const off_count: u32 = @intCast(progress * 9 / POWER_HOLD_MS);
    for (0..9) |i| {
        if (i < 9 - off_count) {
            board.rgb_leds.setPixel(@intCast(i), hal.Color.rgb(255, 50, 0));
        } else {
            board.rgb_leds.setPixel(@intCast(i), hal.Color.rgb(0, 0, 0));
        }
    }
    board.rgb_leds.refresh();

    if (!power_held) {
        // Released too early — back to on
        power_state = .on;
        // Restore Ultraman LEDs
        for (0..9) |i| {
            board.rgb_leds.setPixel(@intCast(i), LED_IDLE);
        }
        board.rgb_leds.refresh();
        // Reload current screen
        if (scr_cards[menu_selection]) |scr| c.lv_screen_load(scr);
        return;
    }

    if (held >= POWER_HOLD_MS) {
        // Shutdown complete
        power_state = .off;
        power_held = false;
        log.info("Power OFF", .{});

        // Deinit current app
        switch (current_app) {
            .snake => snake.deinit(),
            .led_demo => led_demo.deinit(&board),
            else => {},
        }
        current_app = .menu;
        menu_selection = 0;

        board.rgb_leds.clear();
        board.rgb_leds.refresh();
        showPowerScreen("Hold POWER 3s");
    }
}

// ============================================================================
// Power Screen (shown when off / booting / shutting down)
// ============================================================================

fn powerScreenInit() void {
    scr_power = c.lv_obj_create(null);
    if (scr_power == null) return;
    c.lv_obj_set_style_bg_color(scr_power.?, c.lv_color_hex(0x000000), 0);

    lbl_power = c.lv_label_create(scr_power.?);
    c.lv_label_set_text(lbl_power, "Hold POWER 3s");
    c.lv_obj_set_style_text_color(lbl_power, c.lv_color_hex(0x444466), 0);
    c.lv_obj_align(lbl_power, c.LV_ALIGN_CENTER, 0, -20);

    // Progress bar
    power_bar = c.lv_bar_create(scr_power.?);
    c.lv_obj_set_size(power_bar, 160, 8);
    c.lv_bar_set_range(power_bar, 0, 100);
    c.lv_bar_set_value(power_bar, 0, c.LV_ANIM_OFF);
    c.lv_obj_align(power_bar, c.LV_ALIGN_CENTER, 0, 20);
    c.lv_obj_set_style_bg_color(power_bar, c.lv_color_hex(0x111122), 0);
    c.lv_obj_set_style_bg_color(power_bar, c.lv_color_hex(0x6c8cff), @intCast(c.LV_PART_INDICATOR));

    c.lv_screen_load(scr_power.?);
}

fn showPowerScreen(text: [*:0]const u8) void {
    if (lbl_power) |lbl| c.lv_label_set_text(lbl, text);
    if (power_bar) |bar| c.lv_bar_set_value(bar, 0, c.LV_ANIM_OFF);
    if (scr_power) |scr| c.lv_screen_load(scr);
}

fn updatePowerBar(held_ms: u64) void {
    if (power_bar == null) return;
    const pct: i32 = @intCast(@min(held_ms * 100 / POWER_HOLD_MS, 100));
    c.lv_bar_set_value(power_bar, pct, c.LV_ANIM_OFF);
}

// ============================================================================
// App switching
// ============================================================================

fn switchTo(app: AppId) void {
    switch (current_app) {
        .snake => snake.deinit(),
        .led_demo => led_demo.deinit(&board),
        else => {},
    }

    current_app = app;

    switch (app) {
        .menu => {
            // Restore Ultraman LEDs
            for (0..9) |i| {
                board.rgb_leds.setPixel(@intCast(i), LED_IDLE);
            }
            board.rgb_leds.refresh();
            // Show current card
            if (scr_cards[menu_selection]) |scr| c.lv_screen_load(scr);
        },
        .snake => snake.init(),
        .led_demo => led_demo.init(&board),
        .about => aboutInit(),
    }
}

// ============================================================================
// Menu — Horizontal card carousel with slide animation
// ============================================================================

fn menuInit() void {
    // Create a card screen for each menu entry
    for (0..menu_entries.len) |i| {
        scr_cards[i] = createCard(&menu_entries[i], i);
    }
    menu_selection = 0;
    if (scr_cards[0]) |scr| c.lv_screen_load(scr);
}

fn createCard(entry: *const MenuEntry, idx: usize) ?*c.lv_obj_t {
    const scr = c.lv_obj_create(null) orelse return null;
    c.lv_obj_set_style_bg_color(scr, c.lv_color_hex(0x0f1020), 0);

    // Icon (large, centered top)
    const icon = c.lv_label_create(scr);
    c.lv_label_set_text(icon, entry.icon);
    c.lv_obj_set_style_text_font(icon, &c.lv_font_montserrat_20, 0);
    c.lv_obj_set_style_text_color(icon, c.lv_color_hex(0x6c8cff), 0);
    c.lv_obj_align(icon, c.LV_ALIGN_CENTER, 0, -50);

    // Title
    const title = c.lv_label_create(scr);
    c.lv_label_set_text(title, entry.title);
    c.lv_obj_set_style_text_font(title, &c.lv_font_montserrat_20, 0);
    c.lv_obj_set_style_text_color(title, c.lv_color_hex(0xffffff), 0);
    c.lv_obj_align(title, c.LV_ALIGN_CENTER, 0, -10);

    // Subtitle
    const sub = c.lv_label_create(scr);
    c.lv_label_set_text(sub, entry.subtitle);
    c.lv_obj_set_style_text_color(sub, c.lv_color_hex(0x666688), 0);
    c.lv_obj_align(sub, c.LV_ALIGN_CENTER, 0, 20);

    // Page indicator dots at bottom
    const dots_y: i32 = -20;
    const dot_spacing: i32 = 16;
    const total_w: i32 = @as(i32, @intCast(menu_entries.len - 1)) * dot_spacing;
    const start_x: i32 = -total_w / 2;

    for (0..menu_entries.len) |d| {
        const dot = c.lv_obj_create(scr);
        c.lv_obj_set_size(dot, 8, 8);
        c.lv_obj_set_style_radius(dot, 4, 0);
        c.lv_obj_set_style_border_width(dot, 0, 0);
        c.lv_obj_set_scrollbar_mode(dot, c.LV_SCROLLBAR_MODE_OFF);

        if (d == idx) {
            c.lv_obj_set_style_bg_color(dot, c.lv_color_hex(0x6c8cff), 0);
        } else {
            c.lv_obj_set_style_bg_color(dot, c.lv_color_hex(0x333355), 0);
        }

        c.lv_obj_align(dot, c.LV_ALIGN_BOTTOM_MID, start_x + @as(i32, @intCast(d)) * dot_spacing, dots_y);
    }

    // "OK to enter" hint
    const hint = c.lv_label_create(scr);
    c.lv_label_set_text(hint, "< OK >");
    c.lv_obj_set_style_text_color(hint, c.lv_color_hex(0x444466), 0);
    c.lv_obj_align(hint, c.LV_ALIGN_BOTTOM_MID, 0, -40);

    return scr;
}

var menu_animating: bool = false;

fn menuStep() void {
    if (menu_animating) return; // ignore input during slide

    if (last_btn) |btn| {
        switch (btn) {
            .right, .vol_down => slideMenu(1),
            .left, .vol_up => slideMenu(-1),
            .confirm => {
                switch (menu_selection) {
                    0 => switchTo(.snake),
                    1 => switchTo(.led_demo),
                    2 => switchTo(.about),
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn slideMenu(delta: i32) void {
    const new_sel: i32 = @as(i32, menu_selection) + delta;
    if (new_sel < 0 or new_sel >= @as(i32, @intCast(menu_entries.len))) return;

    const old_sel = menu_selection;
    menu_selection = @intCast(new_sel);

    const next_scr = scr_cards[menu_selection] orelse return;
    _ = old_sel;

    // Slide animation
    const anim_type: c.lv_screen_load_anim_t = if (delta > 0)
        c.LV_SCR_LOAD_ANIM_MOVE_LEFT
    else
        c.LV_SCR_LOAD_ANIM_MOVE_RIGHT;

    menu_animating = true;
    c.lv_screen_load_anim(next_scr, anim_type, 250, 0, false);

    // Reset animation lock after duration (approximate with tick counter)
    anim_unlock_at = tick_counter + 16; // ~256ms at 60fps
}

var tick_counter: u32 = 0;
var anim_unlock_at: u32 = 0;

// ============================================================================
// About
// ============================================================================

fn aboutInit() void {
    scr_about = c.lv_obj_create(null);
    if (scr_about == null) return;
    c.lv_obj_set_style_bg_color(scr_about.?, c.lv_color_hex(0x1a1a2e), 0);

    const title = c.lv_label_create(scr_about.?);
    c.lv_label_set_text(title, "About");
    c.lv_obj_set_style_text_color(title, c.lv_color_hex(0x6c8cff), 0);
    c.lv_obj_align(title, c.LV_ALIGN_TOP_MID, 0, 30);

    const info = c.lv_label_create(scr_about.?);
    c.lv_label_set_text(info,
        \\embed-zig WebSim
        \\
        \\LVGL 9.2 + Zig
        \\-> WASM (wasi-musl)
        \\
        \\240x240 RGB565
        \\7 ADC buttons
        \\9 LED strip
        \\
        \\Press BACK to return
    );
    c.lv_obj_set_style_text_color(info, c.lv_color_hex(0xaaaacc), 0);
    c.lv_obj_set_style_text_line_space(info, 4, 0);
    c.lv_obj_align(info, c.LV_ALIGN_CENTER, 0, 10);

    c.lv_screen_load(scr_about.?);
}

fn aboutStep() void {}
