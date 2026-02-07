//! Platform Configuration - Speaker Test
//!
//! Supports: Korvo-2 V3, LiChuang SZP (ES8311 mono DAC + PA control)

const std = @import("std");
const hal = @import("hal");
const esp = @import("esp");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
    .lichuang_szp => @import("esp/lichuang_szp.zig"),
    .lichuang_gocool => @import("esp/lichuang_gocool.zig"),
};

const idf = esp.idf;

pub const Hardware = hw.Hardware;

// Re-export platform primitives
pub const log = hw.log;
pub const time = hw.time;

/// Custom Board struct with shared I2S and I2C
pub const Board = struct {
    const Self = @This();

    // Re-export platform primitives as struct members
    pub const log = hw.log;
    pub const time = hw.time;

    // Shared buses
    i2c: idf.I2c,
    i2s: idf.I2s,

    // Drivers
    rtc: hw.RtcDriver,
    speaker: hw.SpeakerDriver,
    pa_switch: hw.PaSwitchDriver,

    initialized: bool = false,

    /// Initialize all board components
    pub fn init(self: *Self) !void {
        // Initialize shared I2C bus
        self.i2c = try idf.I2c.init(.{
            .sda = Hardware.i2c_sda,
            .scl = Hardware.i2c_scl,
            .freq_hz = 400_000,
        });
        errdefer self.i2c.deinit();

        // Initialize shared I2S bus (TX only for speaker)
        self.i2s = try idf.I2s.init(.{
            .port = Hardware.i2s_port,
            .sample_rate = Hardware.sample_rate,
            .rx_channels = 0, // No RX needed for speaker-only test
            .bits_per_sample = 16,
            .bclk_pin = Hardware.i2s_bclk,
            .ws_pin = Hardware.i2s_ws,
            .din_pin = null, // No mic input
            .dout_pin = Hardware.i2s_dout,
            .mclk_pin = Hardware.i2s_mclk,
        });
        errdefer self.i2s.deinit();

        // Initialize RTC
        self.rtc = try hw.RtcDriver.init();
        errdefer self.rtc.deinit();

        // Initialize speaker using shared I2C and I2S
        self.speaker = try hw.SpeakerDriver.init();
        try self.speaker.initWithShared(&self.i2c, &self.i2s);
        errdefer self.speaker.deinit();

        // Initialize PA switch using shared I2C bus
        self.pa_switch = try hw.PaSwitchDriver.init(&self.i2c);
        errdefer self.pa_switch.deinit();

        self.initialized = true;
    }

    /// Deinitialize all board components
    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.pa_switch.deinit();
            self.speaker.deinit();
            self.rtc.deinit();
            self.i2s.deinit();
            self.i2c.deinit();
            self.initialized = false;
        }
    }
};
