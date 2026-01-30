//! Korvo-2 V3 Board Implementation for Microphone Test
//!
//! Hardware:
//! - ES7210 4-channel ADC (I2C address 0x40)
//! - ES8311 Codec for speaker (not used for mic input)
//! - I2S TDM for audio data transfer
//!
//! Channel Configuration:
//! - MIC1 (Channel 0): Main voice microphone
//! - MIC2 (Channel 1): Secondary microphone (optional)
//! - MIC3 (Channel 2): AEC reference (loopback from ES8311 DAC)
//! - MIC4 (Channel 3): Not used

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

// Hardware parameters from lib/esp/boards
const hw_params = esp.boards.korvo2_v3;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
    pub const sample_rate: u32 = 16000;

    // I2C pins (shared with TCA9554)
    pub const i2c_sda: u8 = 17;
    pub const i2c_scl: u8 = 18;

    // I2S pins (directly connected to ES7210)
    pub const i2s_port: u8 = hw_params.mic_i2s_port;
    pub const i2s_bclk: u8 = 9;
    pub const i2s_ws: u8 = 45;
    pub const i2s_din: u8 = 10;
    pub const i2s_mclk: u8 = 16;

    // ES7210 I2C address
    pub const es7210_addr: u7 = 0x40;
};

// ============================================================================
// RTC Driver (required by hal.Board)
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
// Microphone Driver (ES7210 + I2S TDM)
// ============================================================================

/// I2C bus type
const I2c = idf.I2c;

/// ES7210 ADC driver type
const Es7210 = drivers.Es7210(*I2c);

/// ESP Mic type with ES7210 ADC
const EspMic = idf.Mic(Es7210);

/// Microphone driver combining ES7210 ADC with I2S TDM
///
/// This driver manages both the ES7210 ADC (via I2C) and the I2S TDM
/// interface for audio data transfer. The ES7210 is configured via I2C
/// and outputs audio data via I2S in TDM mode.
pub const MicDriver = struct {
    const Self = @This();

    // ADC metadata (used by HAL and ESP Mic)
    pub const channel_count: u8 = 4;
    pub const max_gain_db: i8 = 37;

    // Instance fields
    i2c: I2c,
    adc: Es7210,
    mic: EspMic,
    initialized: bool = false,

    pub fn init() !Self {
        var self = Self{
            .i2c = undefined,
            .adc = undefined,
            .mic = undefined,
        };

        // Initialize I2C bus
        self.i2c = try I2c.init(.{
            .sda = Hardware.i2c_sda,
            .scl = Hardware.i2c_scl,
            .freq_hz = 100_000, // Use 100kHz like ESP-ADF
        });
        errdefer self.i2c.deinit();

        // Initialize ES7210 ADC via I2C
        self.adc = Es7210.init(&self.i2c, .{
            .address = Hardware.es7210_addr,
            .mic_select = .{
                .mic1 = true, // Voice microphone
                .mic2 = false, // Not used
                .mic3 = true, // AEC reference
                .mic4 = false, // Not used
            },
        });

        // Open and configure the ADC
        try self.adc.open();
        errdefer self.adc.close() catch {};

        // Initialize the integrated Mic driver (includes I2S TDM)
        self.mic = try EspMic.init(&self.adc, .{
            .sample_rate = Hardware.sample_rate,
            .bits_per_sample = 16,
            .channels = .{
                .voice, // MIC1: Main voice
                .disabled, // MIC2: Not used
                .aec_ref, // MIC3: AEC reference
                .disabled, // MIC4: Not used
            },
            .aec_enabled = true,
            .i2s = .{
                .port = Hardware.i2s_port,
                .bclk_pin = Hardware.i2s_bclk,
                .ws_pin = Hardware.i2s_ws,
                .din_pin = Hardware.i2s_din,
                .mclk_pin = Hardware.i2s_mclk,
                .mclk_multiple = 256,
            },
        });
        errdefer self.mic.deinit();

        // Set initial gains
        try self.mic.setChannelGain(0, 30); // MIC1: voice (30dB)
        try self.mic.setChannelGain(2, 10); // MIC3: AEC ref (10dB)

        std.log.info("MicDriver: ES7210 + I2S TDM initialized", .{});
        std.log.info("  I2C: SDA={}, SCL={}, addr=0x{x:0>2}", .{
            Hardware.i2c_sda,
            Hardware.i2c_scl,
            Hardware.es7210_addr,
        });
        std.log.info("  I2S: BCLK={}, WS={}, DIN={}, MCLK={}", .{
            Hardware.i2s_bclk,
            Hardware.i2s_ws,
            Hardware.i2s_din,
            Hardware.i2s_mclk,
        });

        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.mic.deinit();
            self.adc.close() catch {};
            self.i2c.deinit();
            self.initialized = false;
            std.log.info("MicDriver: Deinitialized", .{});
        }
    }

    // ================================================================
    // HAL Microphone.Driver interface
    // ================================================================

    /// Read audio samples (blocking)
    ///
    /// Returns mono audio from the voice channel(s).
    /// The I2S TDM driver captures all channels, and this function
    /// extracts only the voice channel data.
    pub fn read(self: *Self, buffer: []i16) !usize {
        if (!self.initialized) return error.NotInitialized;
        return self.mic.read(buffer);
    }

    /// Set gain for all voice channels
    pub fn setGain(self: *Self, gain_db: i8) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.mic.setGain(gain_db);
    }

    /// Set gain for a specific channel
    pub fn setChannelGain(self: *Self, channel: u8, gain_db: i8) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.mic.setChannelGain(channel, gain_db);
    }

    /// Enable or disable a channel (for factory testing)
    pub fn setChannelEnabled(self: *Self, channel: u8, enabled: bool) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.mic.setChannelEnabled(channel, enabled);
    }

    /// Start audio capture (optional - auto-starts on first read)
    pub fn start(self: *Self) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.mic.start();
    }

    /// Stop audio capture
    pub fn stop(self: *Self) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.mic.stop();
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const mic_spec = struct {
    pub const Driver = MicDriver;
    pub const meta = .{ .id = "mic.es7210" };
    pub const config = hal.MicConfig{
        .sample_rate = Hardware.sample_rate,
        .channels = 1, // Mono output (voice channel only)
    };
};
