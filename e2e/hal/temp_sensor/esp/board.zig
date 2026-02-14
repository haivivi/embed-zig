//! ESP board for e2e hal/temp_sensor
const std = @import("std");
const esp = @import("esp");

pub const log = std.log.scoped(.e2e);
pub const TempDriver = esp.boards.esp32s3_devkit.TempSensorDriver;
