//! H106 UI App — Screen router
//!
//! Navigation flow:
//!   Desktop → (right) → Menu → (OK) → Settings / GameList / ...
//!   Any sub-screen → (back) → Menu → (back) → Desktop

const hal = @import("hal");
const ui = @import("ui");
const websim = @import("websim");

const platform = @import("platform.zig");
const Board = platform.Board;
const Display = platform.Display;
const ButtonId = platform.ButtonId;
const log = Board.log;

const theme = @import("theme.zig");
const desktop = @import("ui/desktop.zig");
const menu = @import("ui/menu.zig");
const settings = @import("ui/settings.zig");
const game_list = @import("ui/game_list.zig");

// ============================================================================
// State
// ============================================================================

const Screen = enum { desktop, menu, settings, game_list };

var board: Board = undefined;
var sim_dc: websim.SimDcPin = .{};
var sim_spi: websim.SimSpi = undefined;
var display: Display = undefined;
var ui_ctx: ui.Context(Display) = undefined;
var ready: bool = false;

var current_screen: Screen = .desktop;
var last_btn: ?ButtonId = null;

// ============================================================================
// Init
// ============================================================================

pub fn init() void {
    log.info("H106 UI Prototype", .{});

    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };

    // LED: ultraman blue
    for (0..9) |i| board.rgb_leds.setPixel(@intCast(i), hal.Color.rgb(0, 120, 255));
    board.rgb_leds.refresh();

    // Display — SPI LCD via simulated SPI bus
    sim_spi = websim.SimSpi.init(&sim_dc);
    display = Display.init(&sim_spi, &sim_dc);
    ui_ctx = ui.init(Display, &display) catch {
        log.err("UI init failed", .{});
        return;
    };
    ready = true;

    // Init theme (loads assets + fonts)
    theme.init();

    // Only create desktop at startup (lazy-create others on navigate)
    desktop.create();
    desktop.show();
    current_screen = .desktop;
    log.info("Ready. RIGHT=menu", .{});
}

// ============================================================================
// Step
// ============================================================================

pub fn step() void {
    if (!ready) return;

    // Poll input
    last_btn = null;
    board.buttons.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| {
                if (btn.action == .click) {
                    last_btn = btn.id;
                }
            },
            else => {},
        }
    }
    // Drain single button too
    const t = board.uptime();
    _ = board.button.poll(t);

    // Route input to current screen
    if (last_btn) |btn| {
        switch (current_screen) {
            .desktop => desktopInput(btn),
            .menu => menuInput(btn),
            .settings => settingsInput(btn),
            .game_list => gameListInput(btn),
        }
    }

    // LVGL tick
    ui_ctx.tick(16);
    _ = ui_ctx.handler();
}

// ============================================================================
// Input handlers
// ============================================================================

fn desktopInput(btn: ButtonId) void {
    if (btn == .right or btn == .confirm) {
        if (menu.screen == null) menu.create();
        current_screen = .menu;
        menu.showAnim(false);
    }
}

fn menuInput(btn: ButtonId) void {
    switch (btn) {
        .left => {
            if (menu.index > 0) {
                menu.scrollTo(menu.index - 1);
            } else {
                // At first item: go back to desktop
                current_screen = .desktop;
                desktop.show();
            }
        },
        .right => {
            if (menu.index < 4) {
                menu.scrollTo(menu.index + 1);
            }
        },
        .confirm => {
            switch (menu.index) {
                4 => {
                    if (settings.screen == null) settings.create();
                    current_screen = .settings;
                    settings.show();
                },
                1 => {
                    if (game_list.screen == null) game_list.create();
                    current_screen = .game_list;
                    game_list.show();
                },
                else => {},
            }
        },
        .back => {
            current_screen = .desktop;
            desktop.show();
        },
        else => {},
    }
}

fn settingsInput(btn: ButtonId) void {
    switch (btn) {
        .vol_up, .left => settings.scrollUp(),
        .vol_down, .right => settings.scrollDown(),
        .back => {
            current_screen = .menu;
            menu.show();
        },
        else => {},
    }
}

fn gameListInput(btn: ButtonId) void {
    switch (btn) {
        .vol_up, .left => game_list.scrollUp(),
        .vol_down, .right => game_list.scrollDown(),
        .confirm => game_list.showComingSoon(),
        .back => {
            current_screen = .menu;
            menu.show();
        },
        else => {},
    }
}
