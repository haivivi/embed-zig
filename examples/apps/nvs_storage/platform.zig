//! NVS Storage Platform Configuration
//!
//! Defines the board-independent HAL spec for the NVS storage app.

const build_options = @import("build_options");
const hal = @import("hal");

// Select board implementation based on build option
const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for nvs_storage"),
};

/// Board specification for hal.Board
const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;

    // HAL peripherals
    pub const kvs = hal.kvs.from(hw.kvs_spec);
};

pub const Board = hal.Board(spec);
