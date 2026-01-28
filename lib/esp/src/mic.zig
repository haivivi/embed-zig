//! ESP-IDF Microphone Implementation
//!
//! Provides audio input using I2S with configurable ADC codec.
//! Supports multi-channel ADC chips like ES7210 with AEC reference channel.
//!
//! Usage:
//!   const idf = @import("esp");
//!   const drivers = @import("drivers");
//!
//!   // Create with ES7210 ADC driver
//!   const Es7210 = drivers.Es7210(idf.sal.I2c);
//!   const Mic = idf.Mic(Es7210);
//!
//!   var adc = try Es7210.init(&i2c, .{});
//!   var mic = try Mic.init(&adc, .{
//!       .sample_rate = 16000,
//!       .channels = .{ .voice, .disabled, .aec_ref, .disabled },
//!   });
//!   defer mic.deinit();
//!
//!   const n = try mic.read(&buffer);

const std = @import("std");
const log = @import("log.zig");

/// Channel role in audio processing
pub const ChannelRole = enum {
    /// Channel is disabled
    disabled,
    /// Voice microphone input
    voice,
    /// AEC reference signal (e.g., from speaker output)
    aec_ref,
};

/// I2S configuration
pub const I2sConfig = struct {
    /// I2S port number
    port: u8 = 0,
    /// Bit clock pin
    bclk_pin: u8,
    /// Word select (LRCK) pin
    ws_pin: u8,
    /// Data in pin
    din_pin: u8,
    /// MCLK pin (optional, 0 = disabled)
    mclk_pin: u8 = 0,
};

/// Mic configuration
pub const Config = struct {
    /// Sample rate in Hz
    sample_rate: u32 = 16000,
    /// Bits per sample
    bits_per_sample: u8 = 16,
    /// Channel roles (up to 4 channels for ES7210)
    channels: [4]ChannelRole = .{ .voice, .disabled, .aec_ref, .disabled },
    /// Enable AEC processing
    aec_enabled: bool = true,
    /// I2S configuration
    i2s: I2sConfig,
};

/// ESP Microphone driver
/// Generic over ADC driver type for flexibility
pub fn Mic(comptime Adc: type) type {
    // Verify ADC has required methods and constants
    comptime {
        if (!@hasDecl(Adc, "setChannelGain")) {
            @compileError("Adc must have setChannelGain method");
        }
    }

    return struct {
        const Self = @This();

        // ================================================================
        // ADC metadata (from driver type)
        // ================================================================

        /// Maximum supported channels from ADC
        pub const max_channels: u8 = if (@hasDecl(Adc, "channel_count")) Adc.channel_count else 4;

        /// Maximum gain in dB
        pub const max_gain_db: i8 = if (@hasDecl(Adc, "max_gain_db")) Adc.max_gain_db else 37;

        // ================================================================
        // Instance fields
        // ================================================================

        adc: *Adc,
        config: Config,
        initialized: bool = false,

        // Runtime state
        voice_channel_mask: u8 = 0,
        ref_channel: ?u8 = null,
        aec_enabled: bool = true,

        // Buffers
        raw_buffer: [1024]i16 = undefined,

        /// Initialize microphone
        pub fn init(adc: *Adc, config: Config) !Self {
            var self = Self{
                .adc = adc,
                .config = config,
                .aec_enabled = config.aec_enabled,
            };

            // Analyze channel configuration
            for (config.channels, 0..) |role, i| {
                switch (role) {
                    .voice => self.voice_channel_mask |= @as(u8, 1) << @intCast(i),
                    .aec_ref => self.ref_channel = @intCast(i),
                    .disabled => {},
                }
            }

            // TODO: Initialize I2S with config.i2s settings
            // For now, just mark as initialized
            log.info("Mic: Initialized with {} voice channels, AEC ref channel: {?}", .{
                @popCount(self.voice_channel_mask),
                self.ref_channel,
            });

            self.initialized = true;
            return self;
        }

        /// Deinitialize microphone
        pub fn deinit(self: *Self) void {
            if (self.initialized) {
                // TODO: Deinitialize I2S
                self.initialized = false;
            }
        }

        // ================================================================
        // Core API (satisfies HAL Microphone.Driver interface)
        // ================================================================

        /// Read audio samples (blocking)
        ///
        /// Returns processed audio (AEC applied if enabled).
        /// Buffer receives mono audio if single voice channel,
        /// or interleaved stereo if multiple voice channels.
        pub fn read(self: *Self, buffer: []i16) !usize {
            if (!self.initialized) return error.NotInitialized;

            // TODO: Read from I2S
            // For now, return zeros as placeholder
            const samples_to_read = @min(buffer.len, 160); // 10ms @ 16kHz

            // Placeholder: fill with silence
            @memset(buffer[0..samples_to_read], 0);

            // In real implementation:
            // 1. Read raw multi-channel data from I2S
            // 2. Extract voice and reference channels
            // 3. Apply AEC if enabled
            // 4. Return processed audio

            return samples_to_read;
        }

        // ================================================================
        // Channel control (runtime configurable)
        // ================================================================

        /// Enable or disable a channel
        pub fn setChannelEnabled(self: *Self, channel: u8, enabled: bool) !void {
            if (channel >= max_channels) return error.InvalidChannel;

            const role = self.config.channels[channel];
            const mask = @as(u8, 1) << @intCast(channel);

            if (role == .voice) {
                if (enabled) {
                    self.voice_channel_mask |= mask;
                } else {
                    self.voice_channel_mask &= ~mask;
                }
            }

            // TODO: Update ADC configuration
            log.info("Mic: Channel {} {s}", .{ channel, if (enabled) "enabled" else "disabled" });
        }

        /// Set gain for a channel
        pub fn setChannelGain(self: *Self, channel: u8, gain_db: i8) !void {
            if (channel >= max_channels) return error.InvalidChannel;

            const clamped_gain = @min(gain_db, max_gain_db);
            try self.adc.setChannelGain(@intCast(channel), clamped_gain);

            log.info("Mic: Channel {} gain set to {}dB", .{ channel, clamped_gain });
        }

        /// Set gain for all voice channels
        pub fn setGain(self: *Self, gain_db: i8) !void {
            for (0..max_channels) |i| {
                if (self.config.channels[i] == .voice) {
                    try self.setChannelGain(@intCast(i), gain_db);
                }
            }
        }

        // ================================================================
        // AEC control
        // ================================================================

        /// Enable or disable AEC processing
        pub fn setAecEnabled(self: *Self, enabled: bool) void {
            self.aec_enabled = enabled;
            log.info("Mic: AEC {s}", .{if (enabled) "enabled" else "disabled"});
        }

        /// Check if AEC is enabled
        pub fn isAecEnabled(self: *const Self) bool {
            return self.aec_enabled and self.ref_channel != null;
        }

        // ================================================================
        // Status
        // ================================================================

        /// Get number of active voice channels
        pub fn getVoiceChannelCount(self: *const Self) u8 {
            return @popCount(self.voice_channel_mask);
        }

        /// Get configured sample rate
        pub fn getSampleRate(self: *const Self) u32 {
            return self.config.sample_rate;
        }

        /// Check if a specific channel is enabled
        pub fn isChannelEnabled(self: *const Self, channel: u8) bool {
            if (channel >= max_channels) return false;
            const role = self.config.channels[channel];
            if (role == .disabled) return false;
            if (role == .voice) {
                return (self.voice_channel_mask & (@as(u8, 1) << @intCast(channel))) != 0;
            }
            return true; // AEC ref channel
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Mic basic functionality" {
    // Mock ADC driver
    const MockAdc = struct {
        pub const channel_count = 4;
        pub const max_gain_db = 37;

        gain: [4]i8 = .{ 0, 0, 0, 0 },

        pub fn setChannelGain(self: *@This(), ch: u8, gain: i8) !void {
            if (ch < 4) self.gain[ch] = gain;
        }
    };

    const TestMic = Mic(MockAdc);

    var adc = MockAdc{};
    var mic = try TestMic.init(&adc, .{
        .channels = .{ .voice, .disabled, .aec_ref, .disabled },
        .i2s = .{ .bclk_pin = 9, .ws_pin = 45, .din_pin = 10 },
    });
    defer mic.deinit();

    // Test channel detection
    try std.testing.expectEqual(@as(u8, 1), mic.getVoiceChannelCount());
    try std.testing.expect(mic.isChannelEnabled(0)); // voice
    try std.testing.expect(!mic.isChannelEnabled(1)); // disabled
    try std.testing.expect(mic.isChannelEnabled(2)); // aec_ref

    // Test gain setting
    try mic.setChannelGain(0, 30);
    try std.testing.expectEqual(@as(i8, 30), adc.gain[0]);

    // Test AEC control
    try std.testing.expect(mic.isAecEnabled());
    mic.setAecEnabled(false);
    try std.testing.expect(!mic.isAecEnabled());
}
