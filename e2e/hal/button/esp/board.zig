//! ESP board for e2e hal/button (DevKit Boot button GPIO0)
const std = @import("std");
const esp = @import("esp");

pub const log = std.log.scoped(.e2e);
pub const ButtonDriver = esp.boards.esp32s3_devkit.BootButtonDriver;
