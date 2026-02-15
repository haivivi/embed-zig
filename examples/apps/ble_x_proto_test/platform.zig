//! Platform Configuration — BLE X-Proto Test (Cross-platform)

const std = @import("std");
const build_options = @import("build_options");

const board_name = @tagName(build_options.board);

const hw = if (std.mem.eql(u8, board_name, "esp32s3_devkit"))
    @import("esp/esp32s3_devkit.zig")
else if (std.mem.eql(u8, board_name, "bk7258"))
    @import("bk/bk7258.zig")
else
    @compileError("unsupported board for ble_x_proto_test");

pub const Runtime = hw.Runtime;
pub const HciDriver = hw.HciDriver;
pub const heap = hw.heap;
pub const log = hw.log;
pub const time = hw.time;
pub const board_name_str = hw.board_name_str;

pub fn isRunning() bool {
    return hw.isRunning();
}
