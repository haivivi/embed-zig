//! WebSim H106 Board wiring for LVGL app
//!
//! Imports shared board config from lib/platform/websim/boards/h106/
//! and re-exports specs for platform.zig.

const websim = @import("websim");
const board = websim.boards.h106;

pub const name = "WebSim H106";
pub const ButtonId = board.ButtonId;

// HAL specs (from shared board config)
pub const rtc_spec = board.rtc_spec;
pub const power_button_spec = board.power_button_spec;
pub const adc_button_spec = board.adc_button_spec;
pub const led_spec = board.led_spec;
pub const display_spec = board.display_spec;

// Platform primitives
pub const log = board.log;
pub const time = board.time;
pub const isRunning = board.isRunning;
