//! LVGL Demo App — Platform Independent
//!
//! Shows a 240x240 UI with centered label that updates on button press.
//! Platform wiring is done in platform.zig.

const hal = @import("hal");
const ui = @import("ui");

const platform = @import("platform.zig");
const Board = platform.Board;
const HalDisplay = platform.Display;
const ButtonId = platform.ButtonId;
const log = Board.log;

var board: Board = undefined;
var display_driver: HalDisplay.DriverType = undefined;
var hal_display: HalDisplay = undefined;
var ui_ctx: ui.Context(HalDisplay) = undefined;

var label_status: ?ui.Label = null;
var ui_ready: bool = false;

pub fn init() void {
    log.info("LVGL Demo App", .{});

    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };

    // Status LED: dim blue
    board.rgb_leds.setColor(hal.Color.rgb(0, 0, 40));
    board.rgb_leds.refresh();

    // Init display
    display_driver = HalDisplay.DriverType.init() catch {
        log.err("Display init failed", .{});
        return;
    };
    hal_display = HalDisplay.init(&display_driver);
    ui_ctx = ui.init(HalDisplay, &hal_display, .{ .buf_lines = 20 }) catch {
        log.err("UI init failed", .{});
        return;
    };
    ui_ready = true;

    // Create UI
    const lbl = ui.Label.create(ui_ctx.screen());
    lbl.setText("Hello LVGL!");
    lbl.center();
    label_status = lbl;

    log.info("Ready! Use buttons to interact", .{});
}

pub fn step() void {
    // Poll ADC buttons
    board.buttons.poll();
    while (board.buttons.nextEvent()) |evt| {
        if (evt.action == .press or evt.action == .click) {
            onButton(evt.id);
        }
    }

    // Poll power button
    const t = board.uptime();
    if (board.button.poll(t)) |evt| {
        if (evt.action == .press) {
            log.info("Power", .{});
            board.rgb_leds.setColor(hal.Color.white);
            board.rgb_leds.refresh();
        }
        if (evt.action == .release) {
            board.rgb_leds.setColor(hal.Color.rgb(0, 0, 40));
            board.rgb_leds.refresh();
        }
    }

    // LVGL tick + render
    if (ui_ready) {
        ui_ctx.tick(16);
        _ = ui_ctx.handler();
    }
}

fn onButton(id: ButtonId) void {
    const name: [*:0]const u8 = switch (id) {
        .vol_up => "VOL+",
        .vol_down => "VOL-",
        .left => "LEFT",
        .right => "RIGHT",
        .back => "BACK",
        .confirm => "OK",
        .rec => "REC",
    };
    log.info("Key: {s}", .{name});

    if (label_status) |lbl| {
        lbl.setText(switch (id) {
            .vol_up => "Volume Up",
            .vol_down => "Volume Down",
            .left => "< Left",
            .right => "Right >",
            .back => "Back",
            .confirm => "Confirm!",
            .rec => "Recording...",
        });
    }

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
