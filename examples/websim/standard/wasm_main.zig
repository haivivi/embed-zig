//! WebSim standard board — LVGL hello + button handling
//!
//! Demonstrates:
//! - 240x240 LVGL display rendering to canvas
//! - 7 ADC button input
//! - Power button
//! - LED status indicator

const hal = @import("hal");
const websim = @import("websim");
const ui = @import("ui");
const platform = @import("platform.zig");

const Board = platform.Board;
const ButtonId = platform.ButtonId;
const HalDisplay = platform.Display;

var board: Board = undefined;
var initialized: bool = false;

// Display (managed separately — not yet in hal.Board)
var display_driver: HalDisplay.DriverType = undefined;
var hal_display: HalDisplay = undefined;
var ui_ctx: ui.Context(HalDisplay) = undefined;
var ui_initialized: bool = false;

// UI elements
var label_status: ?ui.Label = null;

pub fn init() void {
    websim.sal.log.info("Standard Board -- WebSim", .{});
    websim.sal.log.info("Arrows=nav Enter=OK Esc=back R=rec Space=power", .{});

    board.init() catch {
        websim.sal.log.err("Board init failed", .{});
        return;
    };
    initialized = true;

    // Set status LED to dim blue
    board.rgb_leds.setColor(hal.Color.rgb(0, 0, 40));
    board.rgb_leds.refresh();

    // Init display driver + LVGL
    display_driver = HalDisplay.DriverType.init() catch {
        websim.sal.log.err("Display driver init failed", .{});
        return;
    };
    hal_display = HalDisplay.init(&display_driver);
    ui_ctx = ui.init(HalDisplay, &hal_display, .{ .buf_lines = 20 }) catch {
        websim.sal.log.err("UI init failed", .{});
        return;
    };
    ui_initialized = true;

    // Create UI: centered label
    const label = ui.Label.create(ui_ctx.screen());
    label.setText("Hello WebSim!");
    label.center();
    label_status = label;

    websim.sal.log.info("LVGL display ready (240x240)", .{});
}

pub fn step() void {
    if (!initialized) return;

    // Poll ADC button group
    board.buttons.poll();
    while (board.buttons.nextEvent()) |evt| {
        if (evt.action == .press or evt.action == .click) {
            handleButton(evt.id);
        }
    }

    // Poll power button
    const current_time = board.uptime();
    if (board.button.poll(current_time)) |evt| {
        if (evt.action == .press) {
            websim.sal.log.info("Power button pressed", .{});
            board.rgb_leds.setColor(hal.Color.rgb(255, 255, 255));
            board.rgb_leds.refresh();
        }
        if (evt.action == .release) {
            board.rgb_leds.setColor(hal.Color.rgb(0, 0, 40));
            board.rgb_leds.refresh();
        }
    }

    // LVGL tick + render
    if (ui_initialized) {
        ui_ctx.tick(16); // ~60fps
        _ = ui_ctx.handler();
    }
}

fn handleButton(id: ButtonId) void {
    const name: [*:0]const u8 = switch (id) {
        .vol_up => "VOL+",
        .vol_down => "VOL-",
        .left => "LEFT",
        .right => "RIGHT",
        .back => "BACK",
        .confirm => "OK",
        .rec => "REC",
    };
    websim.sal.log.info("Key: {s}", .{name});

    // Update label text
    if (label_status) |label| {
        label.setText(switch (id) {
            .vol_up => "Volume Up",
            .vol_down => "Volume Down",
            .left => "< Left",
            .right => "Right >",
            .back => "Back",
            .confirm => "Confirm!",
            .rec => "Recording...",
        });
    }

    // LED color per button
    board.rgb_leds.setColor(switch (id) {
        .vol_up => hal.Color.rgb(0, 200, 0),
        .vol_down => hal.Color.rgb(0, 100, 0),
        .left => hal.Color.rgb(0, 0, 200),
        .right => hal.Color.rgb(0, 0, 100),
        .back => hal.Color.rgb(200, 100, 0),
        .confirm => hal.Color.rgb(0, 255, 0),
        .rec => hal.Color.rgb(255, 0, 0),
    });
    board.rgb_leds.refresh();
}

// Generate WASM exports
comptime {
    websim.wasm.exportAll(@This());
}
