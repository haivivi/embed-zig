//! Motion Test Platform Configuration
//!
//! Defines the board-independent HAL spec for the motion test app.
//! Uses hal.motion for event-based motion detection.

const build_options = @import("build_options");
const hal = @import("hal");

// Select board implementation based on build option
const hw = switch (build_options.board) {
    .lichuang_szp => @import("esp/lichuang_szp.zig"),
    .lichuang_gocool => @import("esp/lichuang_gocool.zig"),
};

/// Board specification for hal.Board
const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;

    // HAL peripherals - motion detection (uses IMU internally)
    pub const motion = hal.motion.from(hw.motion_spec);

    // Button ID for boot button
    pub const ButtonId = enum(u8) { boot = 0 };
    pub const button = hal.button.from(hw.button_spec);
};

pub const Board = hal.Board(spec);
