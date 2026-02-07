//! Platform Configuration - AEC Test
//!
//! Supports:
//! - Korvo-2 V3 (ES7210 ADC + ES8311 DAC + AEC)
//! - LiChuang SZP (ES7210 ADC + ES8311 DAC + AEC)
//!
//! Uses AudioSystem for unified mic+speaker with AEC.

const build_options = @import("build_options");
const hal = @import("hal");

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
    .lichuang_szp => @import("esp/lichuang_szp.zig"),
};

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
const I2c = hw.idf.I2c;

/// Board struct for AEC test (simplified, no HAL wrappers)
pub const Board = struct {
    const Self = @This();

    // Re-export for app.zig compatibility
    pub const log = hw.log;
    pub const time = hw.time;

    i2c: I2c,
    audio: AudioSystem,
    pa_switch: PaSwitchDriver,

    pub fn init(self: *Self) !void {
        // Initialize shared I2C bus
        self.i2c = try I2c.init(.{
            .sda = hw.i2c_sda,
            .scl = hw.i2c_scl,
            .freq_hz = hw.i2c_freq_hz,
        });
        errdefer self.i2c.deinit();

        // Initialize audio system (mic + speaker + AEC) with shared I2C
        self.audio = try AudioSystem.init(&self.i2c);
        errdefer self.audio.deinit();

        // Initialize PA switch with shared I2C
        self.pa_switch = try PaSwitchDriver.init(&self.i2c);
    }

    pub fn deinit(self: *Self) void {
        self.pa_switch.deinit();
        self.audio.deinit();
        self.i2c.deinit();
    }
};
