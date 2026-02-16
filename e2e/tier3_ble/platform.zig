//! Platform Configuration — BLE E2E Test (Cross-platform)
//!
//! Exports: Runtime, HciDriver, heap, log, time, Board

const std = @import("std");
const hal = @import("hal");
const build_options = @import("build_options");

const board_name = @tagName(build_options.board);

const hw = if (std.mem.eql(u8, board_name, "esp32s3_devkit"))
    @import("esp/esp32s3_devkit.zig")
else if (std.mem.eql(u8, board_name, "bk7258"))
    @import("bk/bk7258.zig")
else
    @compileError("unsupported board for ble_e2e_test");

/// Async runtime (Mutex, spawn, etc.) for bluetooth.Host
pub const Runtime = hw.Runtime;
/// HCI transport driver for bluetooth.Host
pub const HciDriver = hw.HciDriver;
/// Heap allocator (PSRAM)
pub const heap = hw.heap;
/// Scoped logger
pub const log = hw.log;
/// Time utilities
pub const time = hw.time;
/// Board name for role selection
pub const board_name_str = hw.board_name_str;

pub fn isRunning() bool {
    return hw.isRunning();
}
