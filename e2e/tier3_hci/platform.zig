//! Platform Configuration - HCI Test (Cross-platform)
//!
//! Provides: log, time, ble (init/send/recv/waitForData), isRunning

const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for hci_test"),
};

pub const log = hw.log;
pub const time = hw.time;
pub const ble = hw.ble;

pub fn isRunning() bool {
    return hw.isRunning();
}
