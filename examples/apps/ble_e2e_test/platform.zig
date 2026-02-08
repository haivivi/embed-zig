//! Platform Configuration - BLE Throughput Test

const hal = @import("hal");
const hw = @import("esp/esp32s3_devkit.zig");

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
};

pub const Board = hal.Board(spec);
