//! Platform Configuration - Opus AEC Loopback Test
//!
//! Supports: LiChuang GoCool (ES7210 ADC + ES8311 DAC + AEC)
//! Uses AudioSystem for unified mic+speaker with AEC.

const hal = @import("hal");

// Board selection — single board, no build_options needed
const hw = @import("esp/lichuang_gocool.zig");

pub const Hardware = hw.Hardware;

// Re-export platform primitives
pub const log = hw.log;
pub const time = hw.time;
pub fn isRunning() bool {
    return hw.isRunning();
}

// Re-export AudioSystem and PaSwitchDriver
pub const AudioSystem = hw.AudioSystem;
pub const PaSwitchDriver = hw.PaSwitchDriver;
const I2c = hw.I2c;

/// Board struct for Opus AEC test
pub const Board = struct {
    const Self = @This();

    pub const log = hw.log;
    pub const time = hw.time;

    i2c: I2c,
    audio: AudioSystem,
    pa_switch: PaSwitchDriver,

    pub fn init(self: *Self) !void {
        self.i2c = try I2c.init(.{
            .sda = hw.i2c_sda,
            .scl = hw.i2c_scl,
            .freq_hz = hw.i2c_freq_hz,
        });
        errdefer self.i2c.deinit();

        self.audio = try AudioSystem.init(&self.i2c);
        errdefer self.audio.deinit();

        self.pa_switch = try PaSwitchDriver.init(&self.i2c);
    }

    pub fn deinit(self: *Self) void {
        self.pa_switch.deinit();
        self.audio.deinit();
        self.i2c.deinit();
    }
};
