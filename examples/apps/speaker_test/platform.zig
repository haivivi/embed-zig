//! Platform Configuration - Speaker Test
//!
//! Supports:
//! - ESP: Korvo-2 V3, LiChuang SZP/GoCool (ES8311 mono DAC + PA control)
//! - BK:  BK7258 (onboard DAC)

const std = @import("std");
const hal = @import("hal");
const build_options = @import("build_options");

// ============================================================================
// Board Selection
// ============================================================================

const is_bk = build_options.board == .bk7258;

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
    .lichuang_szp => @import("esp/lichuang_szp.zig"),
    .lichuang_gocool => @import("esp/lichuang_gocool.zig"),
    .bk7258 => @import("bk/bk7258.zig"),
};

pub const Hardware = hw.Hardware;

// Re-export platform primitives
pub const log = hw.log;
pub const time = hw.time;

// ============================================================================
// Board Struct — platform-specific initialization
// ============================================================================

pub const Board = if (is_bk) BkBoard else EspBoard;

/// BK7258 Board — simple, no shared I2C/I2S buses
const BkBoard = struct {
    const Self = @This();

    pub const log = hw.log;
    pub const time = hw.time;

    // Drivers
    rtc: hw.RtcDriver = .{},
    speaker: hw.SpeakerDriver = .{},
    pa_switch: hw.PaSwitchDriver = .{},

    initialized: bool = false,

    pub fn init(self: *Self) !void {
        self.rtc = try hw.RtcDriver.init();
        self.speaker = try hw.SpeakerDriver.init();
        try self.speaker.initWithShared(null, null);
        self.pa_switch = try hw.PaSwitchDriver.init(null);
        self.initialized = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.pa_switch.deinit();
            self.speaker.deinit();
            self.rtc.deinit();
            self.initialized = false;
        }
    }
};

/// ESP Board — shared I2C/I2S buses for ES8311 DAC
const EspBoard = struct {
    const Self = @This();
    const esp = @import("esp");
    const idf = esp.idf;

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

    pub fn init(self: *Self) !void {
        self.i2c = try idf.I2c.init(.{
            .sda = Hardware.i2c_sda,
            .scl = Hardware.i2c_scl,
            .freq_hz = 400_000,
        });
        errdefer self.i2c.deinit();

        self.i2s = try idf.I2s.init(.{
            .port = Hardware.i2s_port,
            .sample_rate = Hardware.sample_rate,
            .rx_channels = 0,
            .bits_per_sample = 16,
            .bclk_pin = Hardware.i2s_bclk,
            .ws_pin = Hardware.i2s_ws,
            .din_pin = null,
            .dout_pin = Hardware.i2s_dout,
            .mclk_pin = Hardware.i2s_mclk,
        });
        errdefer self.i2s.deinit();

        self.rtc = try hw.RtcDriver.init();
        errdefer self.rtc.deinit();

        self.speaker = try hw.SpeakerDriver.init();
        try self.speaker.initWithShared(&self.i2c, &self.i2s);
        errdefer self.speaker.deinit();

        self.pa_switch = try hw.PaSwitchDriver.init(&self.i2c);
        errdefer self.pa_switch.deinit();

        self.initialized = true;
    }

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
