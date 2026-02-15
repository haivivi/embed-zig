//! WebSim H106 Board wiring for Racer

const websim = @import("websim");
const hal = @import("hal");
const board = websim.boards.h106;

pub const name = "WebSim Racer";
pub const ButtonId = board.ButtonId;

pub const adc_button_spec = board.adc_button_spec;
pub const led_spec = board.led_spec;
pub const speaker_spec = board.speaker_spec;

pub const log = board.log;
pub const time = board.time;
pub const isRunning = board.isRunning;
