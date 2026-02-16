//! Platform Configuration — BLE Adv/Scan Interop Test
//!
//! BK7258 = advertiser, ESP32-S3 = scanner

const std = @import("std");
const build_options = @import("build_options");

const board_name = @tagName(build_options.board);

const hw = if (std.mem.eql(u8, board_name, "esp32s3_devkit"))
    @import("esp/esp32s3_devkit.zig")
else if (std.mem.eql(u8, board_name, "bk7258"))
    @import("bk/bk7258.zig")
else
    @compileError("unsupported board for ble_adv_scan_test");

pub const Role = enum { advertiser, scanner };

pub const log = hw.log;
pub const time = hw.time;
pub const ble = hw.ble;
pub const role: Role = hw.role;

pub fn isRunning() bool {
    return hw.isRunning();
}
