//! Korvo-2 V3 Board Implementation for Microphone Test
//!
//! Hardware:
//! - ES7210 4-channel ADC (I2C address 0x40)
//! - ES8311 Codec for speaker (not used for mic input)
//! - I2S for audio data transfer
//!
//! Channel Configuration:
//! - MIC1 (Channel 0): Main voice microphone
//! - MIC2 (Channel 1): Secondary microphone (optional)
//! - MIC3 (Channel 2): AEC reference (loopback from ES8311 DAC)
//! - MIC4 (Channel 3): Not used

const std = @import("std");
const idf = @import("esp");
const hal = @import("hal");
const drivers = @import("drivers");

// Platform primitives
pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.sal.time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return idf.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
}

// Hardware parameters from lib/esp/boards
const hw_params = idf.boards.korvo2_v3;

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

    // I2S pins
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
        return idf.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// Microphone Driver (ES7210 + I2S)
// ============================================================================

/// I2C bus type
const I2c = idf.sal.I2c;

/// ES7210 ADC driver type
const Es7210 = drivers.Es7210(*I2c);

/// Microphone driver combining ES7210 ADC with I2S
pub const MicDriver = struct {
    const Self = @This();

    // ADC metadata (used by HAL and ESP Mic)
    pub const channel_count: u8 = 4;
    pub const max_gain_db: i8 = 37;

    // Instance fields
    i2c: I2c,
    adc: Es7210,
    initialized: bool = false,

    // Channel state (runtime configurable)
    channel_enabled: [4]bool = .{ true, false, true, false }, // MIC1 + MIC3
    channel_gain: [4]i8 = .{ 30, 30, 10, 0 }, // Voice=30dB, Ref=10dB

    pub fn init() !Self {
        var self = Self{
            .i2c = undefined,
            .adc = undefined,
        };

        // Initialize I2C
        self.i2c = try I2c.init(.{
            .sda = Hardware.i2c_sda,
            .scl = Hardware.i2c_scl,
            .freq_hz = 400_000,
        });
        errdefer self.i2c.deinit();

        // Initialize ES7210 ADC
        self.adc = Es7210.init(&self.i2c, .{
            .address = Hardware.es7210_addr,
            .mic_select = .{
                .mic1 = true, // Voice
                .mic2 = false,
                .mic3 = true, // AEC reference
                .mic4 = false,
            },
        });

        // Open and configure ADC
        try self.adc.open();
        errdefer self.adc.close() catch {};

        // Set initial gains
        try self.adc.setChannelGain(0, 30); // MIC1: voice
        try self.adc.setChannelGain(2, 10); // MIC3: AEC ref (lower gain)

        // TODO: Initialize I2S
        // For now, just mark as initialized
        std.log.info("MicDriver: ES7210 initialized on I2C 0x{x:0>2}", .{Hardware.es7210_addr});

        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.adc.close() catch {};
            self.i2c.deinit();
            self.initialized = false;
        }
    }

    // ================================================================
    // HAL Microphone.Driver interface
    // ================================================================

    /// Read audio samples (blocking)
    /// Returns mono audio after AEC processing
    pub fn read(self: *Self, buffer: []i16) !usize {
        if (!self.initialized) return error.NotInitialized;

        // TODO: Implement actual I2S read
        // 1. Read multi-channel data from I2S (ES7210 TDM output)
        // 2. Extract MIC1 (voice) and MIC3 (reference)
        // 3. Apply AEC
        // 4. Return processed mono audio

        // Placeholder: return silence
        const samples = @min(buffer.len, 160);
        @memset(buffer[0..samples], 0);
        return samples;
    }

    /// Set gain for a specific channel (runtime)
    pub fn setGain(self: *Self, gain_db: i8) !void {
        // Set gain for all voice channels
        for (0..4) |i| {
            if (self.channel_enabled[i] and i != 2) { // Not AEC ref
                try self.setChannelGain(@intCast(i), gain_db);
            }
        }
    }

    /// Set gain for a specific channel
    pub fn setChannelGain(self: *Self, channel: u8, gain_db: i8) !void {
        if (channel >= 4) return error.InvalidChannel;

        const clamped = @min(gain_db, max_gain_db);
        self.channel_gain[channel] = clamped;

        if (self.initialized) {
            try self.adc.setChannelGain(@intCast(channel), @enumFromInt(@as(u8, @intCast(clamped / 3))));
        }
    }

    /// Enable or disable a channel (for factory testing)
    pub fn setChannelEnabled(self: *Self, channel: u8, enabled: bool) !void {
        if (channel >= 4) return error.InvalidChannel;
        self.channel_enabled[channel] = enabled;

        // TODO: Update ES7210 mic selection
        std.log.info("MicDriver: Channel {} {s}", .{ channel, if (enabled) "enabled" else "disabled" });
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
        .channels = 1, // Mono output after AEC
    };
};
