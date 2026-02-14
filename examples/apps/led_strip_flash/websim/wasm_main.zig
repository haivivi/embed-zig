//! WebSim WASM entry point for led_strip_flash
//!
//! Cooperative version: toggle LED every 1 second.

const hal = @import("hal");
const websim = @import("websim");
const platform = @import("platform.zig");

const Board = platform.Board;
const log = websim.sal.log;

var board: Board = undefined;
var initialized: bool = false;
var led_state: bool = false;
var last_toggle_ms: u64 = 0;
const FLASH_INTERVAL_MS: u64 = 1000;
const BRIGHTNESS: u8 = 32;

pub fn init() void {
    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };
    initialized = true;
    log.info("LED Strip Flash - WebSim", .{});
    log.info("Board: {s}", .{Board.meta.id});
    log.info("Starting flash loop (1 second interval)", .{});
}

pub fn step() void {
    if (!initialized) return;

    const now = board.uptime();
    if (now - last_toggle_ms >= FLASH_INTERVAL_MS) {
        last_toggle_ms = now;
        led_state = !led_state;

        if (led_state) {
            board.rgb_leds.setColor(hal.Color.rgb(BRIGHTNESS, BRIGHTNESS, BRIGHTNESS));
        } else {
            board.rgb_leds.clear();
        }
        board.rgb_leds.refresh();

        log.info("LED {s} (uptime: {}ms)", .{
            if (led_state) "ON" else "OFF",
            now,
        });
    }
}

// Board config JSON for dynamic UI rendering in JS
pub const board_config_json = websim.boards.esp32_devkit.board_config_json;

comptime {
    websim.wasm.exportAll(@This());
}
