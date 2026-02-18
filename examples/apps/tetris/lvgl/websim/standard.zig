//! WebSim H106 Board wiring for Tetris
//!
//! Reuses H106 board button config from shared websim board definition.

const websim = @import("websim");
const hal = @import("hal");
const board = websim.boards.h106;

pub const name = "WebSim Tetris";
pub const ButtonId = board.ButtonId;

// HAL specs (from shared board config)
pub const adc_button_spec = board.adc_button_spec;
pub const power_button_spec = board.power_button_spec;
pub const led_spec = board.led_spec;

// Platform primitives
pub const log = board.log;
pub const time = board.time;
pub const isRunning = board.isRunning;
