//! ESP32-S3 DevKit Board — Opus Test

const std = @import("std");
const esp = @import("esp");

const board = esp.boards.esp32s3_devkit;

pub const log = std.log.scoped(.app);
pub const time = board.time;
