//! Board Configuration - HAL v5

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
    .lichuang_szp => @import("esp/lichuang_szp.zig"),
    .lichuang_gocool => @import("esp/lichuang_gocool.zig"),
    .sim_raylib => @import("esp/sim_raylib.zig"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Button ID type
    pub const ButtonId = enum(u8) { boot = 0 };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log; // trait - validated by Board
    pub const time = hw.time; // trait - validated by Board

    // HAL peripherals
    pub const button = hal.button.from(hw.button_spec);
    pub const rgb_leds = hal.led_strip.from(hw.led_spec);
};

pub const Board = hal.Board(spec);
