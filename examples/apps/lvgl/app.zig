//! LVGL Demo App — Multi-app menu system
//!
//! Platform-independent. Features:
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

var board: Board = undefined;
var display_driver: HalDisplay.DriverType = undefined;
var hal_display: HalDisplay = undefined;
var ui_ctx: ui.Context(HalDisplay) = undefined;
var ready: bool = false;

var current_app: AppId = .menu;
var menu_selection: u8 = 0;

// Menu LVGL objects
var scr_menu: ?*c.lv_obj_t = null;
var menu_labels: [3]?*c.lv_obj_t = .{ null, null, null };

// About screen
var scr_about: ?*c.lv_obj_t = null;

const menu_items = [_][]const u8{ "Snake", "LED Demo", "About" };

// ============================================================================
// Input
// ============================================================================

var last_btn: ?ButtonId = null;
var last_power: bool = false;

fn pollInput() void {
    last_btn = null;
    last_power = false;

    board.buttons.poll();
    while (board.buttons.nextEvent()) |evt| {
        if (evt.action == .press or evt.action == .click) {
            last_btn = evt.id;
        }
    }

    const t = board.uptime();
    if (board.button.poll(t)) |evt| {
        if (evt.action == .press) last_power = true;
    }
}

// ============================================================================
// Init
// ============================================================================

pub fn init() void {
    log.info("LVGL Demo App", .{});

    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };

    // Status LED off
    board.rgb_leds.clear();
    board.rgb_leds.refresh();

    // Display
    display_driver = HalDisplay.DriverType.init() catch {
        log.err("Display init failed", .{});
        return;
    };
    hal_display = HalDisplay.init(&display_driver);
    ui_ctx = ui.init(HalDisplay, &hal_display, .{ .buf_lines = 20 }) catch {
        log.err("UI init failed", .{});
        return;
    };
    ready = true;

    menuInit();
    log.info("Ready", .{});
}

// ============================================================================
// Step (called each frame ~60fps)
// ============================================================================

pub fn step() void {
    if (!ready) return;

    pollInput();

    switch (current_app) {
        .menu => menuStep(),
        .snake => snake.step(last_btn),
        .led_demo => led_demo.step(&board, last_btn),
        .about => aboutStep(),
    }

    // Back to menu from any app
    if (current_app != .menu and last_btn != null and last_btn.? == .back) {
        switchTo(.menu);
    }

    ui_ctx.tick(16);
    _ = ui_ctx.handler();
}

// ============================================================================
// App switching
// ============================================================================

fn switchTo(app: AppId) void {
    // Deinit current
    switch (current_app) {
        .snake => snake.deinit(),
        .led_demo => led_demo.deinit(&board),
        else => {},
    }

    current_app = app;

    switch (app) {
        .menu => {
            if (scr_menu) |scr| c.lv_screen_load(scr);
            updateMenuHighlight();
        },
        .snake => {
            snake.init();
        },
        .led_demo => {
            led_demo.init(&board);
        },
        .about => {
            aboutInit();
        },
    }
}

// ============================================================================
// Menu
// ============================================================================

fn menuInit() void {
    scr_menu = c.lv_obj_create(null);
    if (scr_menu == null) return;
    c.lv_obj_set_style_bg_color(scr_menu.?, c.lv_color_hex(0x1a1a2e), 0);

    // Title
    const title = c.lv_label_create(scr_menu.?);
    c.lv_label_set_text(title, "embed-zig");
    c.lv_obj_set_style_text_color(title, c.lv_color_hex(0x6c8cff), 0);
    c.lv_obj_align(title, c.LV_ALIGN_TOP_MID, 0, 20);

    // Menu items
    for (0..menu_items.len) |i| {
        const lbl = c.lv_label_create(scr_menu.?);
        c.lv_label_set_text(lbl, menu_items[i].ptr);
        c.lv_obj_align(lbl, c.LV_ALIGN_TOP_MID, 0, @as(i32, @intCast(80 + i * 50)));
        menu_labels[i] = lbl;
    }

    updateMenuHighlight();
    c.lv_screen_load(scr_menu.?);
}

fn updateMenuHighlight() void {
    for (0..menu_items.len) |i| {
        if (menu_labels[i]) |lbl| {
            if (i == menu_selection) {
                c.lv_obj_set_style_text_color(lbl, c.lv_color_hex(0xffffff), 0);
                c.lv_obj_set_style_text_font(lbl, &c.lv_font_montserrat_20, 0);
            } else {
                c.lv_obj_set_style_text_color(lbl, c.lv_color_hex(0x666688), 0);
                c.lv_obj_set_style_text_font(lbl, &c.lv_font_montserrat_16, 0);
            }
        }
    }
}

fn menuStep() void {
    if (last_btn) |btn| {
        switch (btn) {
            .vol_down, .right => {
                if (menu_selection < menu_items.len - 1) menu_selection += 1;
                updateMenuHighlight();
            },
            .vol_up, .left => {
                if (menu_selection > 0) menu_selection -= 1;
                updateMenuHighlight();
            },
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

fn aboutStep() void {
    // Nothing to update, back handled in main step
}
