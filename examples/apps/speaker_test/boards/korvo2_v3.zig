//! Korvo-2 V3 Board Implementation for Speaker Test
//!
//! Hardware:
//! - ES8311 Mono DAC (I2C address 0x18)
//! - I2S for audio data transfer
//! - PA enable via GPIO 48

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");
const drivers = @import("drivers");

const idf = esp.idf;

// Platform primitives
pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return idf.time.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
}

// Hardware parameters
const hw_params = esp.boards.korvo2_v3;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = "/dev/cu.usbserial-120";
    pub const sample_rate: u32 = 16000;

    // I2C pins
    pub const i2c_sda: u8 = 17;
    pub const i2c_scl: u8 = 18;

    // I2S pins for speaker
    pub const i2s_port: u8 = 0;
    pub const i2s_bclk: u8 = 9;
    pub const i2s_ws: u8 = 45;
    pub const i2s_dout: u8 = 8;
    pub const i2s_mclk: u8 = 16;

    // PA enable
    pub const pa_enable_gpio: u8 = 48;

    // ES8311 I2C address
    pub const es8311_addr: u7 = 0x18;
};

// ============================================================================
// Type aliases
// ============================================================================

const I2c = idf.I2c;
const I2s = idf.I2s;
const Es8311 = drivers.Es8311(*I2c);
const EspSpeaker = idf.Speaker(Es8311);

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.time.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// PA Switch Driver
// ============================================================================

pub const PaSwitchDriver = struct {
    const Self = @This();
    const gpio = idf.gpio;

    is_on: bool = false,

    pub fn init() !Self {
        try gpio.configOutput(Hardware.pa_enable_gpio);
        try gpio.setLevel(Hardware.pa_enable_gpio, 0);
        std.log.info("PaSwitchDriver: Initialized on GPIO {}", .{Hardware.pa_enable_gpio});
        return Self{ .is_on = false };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_on) {
            self.off() catch {};
        }
        gpio.reset(Hardware.pa_enable_gpio) catch {};
    }

    pub fn on(self: *Self) !void {
        try gpio.setLevel(Hardware.pa_enable_gpio, 1);
        self.is_on = true;
        std.log.info("PaSwitchDriver: PA enabled", .{});
    }

    pub fn off(self: *Self) !void {
        try gpio.setLevel(Hardware.pa_enable_gpio, 0);
        self.is_on = false;
        std.log.info("PaSwitchDriver: PA disabled", .{});
    }

    pub fn isOn(self: *Self) bool {
        return self.is_on;
    }
};

// ============================================================================
// Speaker Driver (ES8311 + shared I2S TX)
// ============================================================================

pub const SpeakerDriver = struct {
    const Self = @This();

    dac: Es8311,
    speaker: EspSpeaker,
    initialized: bool = false,

    pub fn init() !Self {
        return Self{
            .dac = undefined,
            .speaker = undefined,
            .initialized = false,
        };
    }

    /// Initialize speaker using shared I2S and I2C
    pub fn initWithShared(self: *Self, i2c: *I2c, i2s: *I2s) !void {
        if (self.initialized) return;

        // Initialize ES8311 DAC via shared I2C
        self.dac = Es8311.init(i2c, .{
            .address = Hardware.es8311_addr,
            .codec_mode = .dac_only,
        });

        try self.dac.open();
        errdefer self.dac.close() catch {};

        try self.dac.setSampleRate(Hardware.sample_rate);

        // Initialize speaker using shared I2S
        self.speaker = try EspSpeaker.init(&self.dac, i2s, .{
            .initial_volume = 180,
        });
        errdefer self.speaker.deinit();

        std.log.info("SpeakerDriver: ES8311 + shared I2S initialized", .{});
        self.initialized = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.speaker.deinit();
            self.dac.close() catch {};
            self.initialized = false;
        }
    }

    pub fn write(self: *Self, buffer: []const i16) !usize {
        if (!self.initialized) return error.NotInitialized;
        return self.speaker.write(buffer);
    }

    pub fn setVolume(self: *Self, volume: u8) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.speaker.setVolume(volume);
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const pa_switch_spec = struct {
    pub const Driver = PaSwitchDriver;
    pub const meta = .{ .id = "switch.pa" };
};

pub const speaker_spec = struct {
    pub const Driver = SpeakerDriver;
    pub const meta = .{ .id = "speaker.es8311" };
    pub const config = hal.MonoSpeakerConfig{
        .sample_rate = Hardware.sample_rate,
    };
};
