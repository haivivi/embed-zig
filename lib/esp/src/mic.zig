//! ESP-IDF Microphone Implementation
//!
//! Provides audio input using I2S TDM with configurable ADC codec.
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
//!       .i2s = .{ .bclk_pin = 9, .ws_pin = 45, .din_pin = 10, .mclk_pin = 16 },
//!   });
//!   defer mic.deinit();
//!
//!   try mic.start();
//!   const n = try mic.read(&buffer);

const std = @import("std");
const log = std.log.scoped(.mic);
const i2s_tdm = @import("i2s_tdm.zig");
const I2sTdm = i2s_tdm.I2sTdm;

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
    /// MCLK pin (optional, null = disabled)
    mclk_pin: ?u8 = null,
    /// MCLK multiple (256 or 384)
    mclk_multiple: u16 = 256,
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

        /// Raw buffer size (4 channels * 160 samples per 10ms @ 16kHz)
        const raw_buffer_size: usize = @as(usize, max_channels) * 320; // ~20ms buffer

        // ================================================================
        // Instance fields
        // ================================================================

        adc: *Adc,
        config: Config,
        i2s: I2sTdm,
        initialized: bool = false,
        started: bool = false,

        // Runtime state
        voice_channel_mask: u8 = 0,
        ref_channel: ?u8 = null,
        aec_enabled: bool = true,

        // Buffers for multi-channel capture and processing
        raw_buffer: [raw_buffer_size]i16 = undefined,

        /// Initialize microphone
        pub fn init(adc: *Adc, config: Config) !Self {
            // Count active channels for I2S configuration
            var active_channels: u8 = 0;
            for (config.channels) |role| {
                if (role != .disabled) active_channels += 1;
            }
            // Ensure we have at least the channels up to the last active one
            var last_active: u8 = 0;
            for (config.channels, 0..) |role, i| {
                if (role != .disabled) last_active = @intCast(i + 1);
            }
            const i2s_channels = @max(last_active, 2); // At least 2 for I2S stereo

            // Initialize I2S TDM
            var i2s = try I2sTdm.init(.{
                .port = config.i2s.port,
                .sample_rate = config.sample_rate,
                .channels = i2s_channels,
                .bits_per_sample = config.bits_per_sample,
                .bclk_pin = config.i2s.bclk_pin,
                .ws_pin = config.i2s.ws_pin,
                .din_pin = config.i2s.din_pin,
                .mclk_pin = config.i2s.mclk_pin,
                .mclk_multiple = config.i2s.mclk_multiple,
            });
            errdefer i2s.deinit();

            var self = Self{
                .adc = adc,
                .config = config,
                .i2s = i2s,
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

            log.info("Mic: Initialized with {} voice channels, AEC ref: {?}, I2S channels: {}", .{
                @popCount(self.voice_channel_mask),
                self.ref_channel,
                i2s_channels,
            });

            self.initialized = true;
            return self;
        }

        /// Deinitialize microphone
        pub fn deinit(self: *Self) void {
            if (self.initialized) {
                if (self.started) {
                    self.stop() catch {};
                }
                self.i2s.deinit();
                self.initialized = false;
            }
        }

        /// Start audio capture
        pub fn start(self: *Self) !void {
            if (!self.initialized) return error.NotInitialized;
            if (self.started) return;

            try self.i2s.enable();
            self.started = true;
            log.info("Mic: Started", .{});
        }

        /// Stop audio capture
        pub fn stop(self: *Self) !void {
            if (!self.started) return;

            try self.i2s.disable();
            self.started = false;
            log.info("Mic: Stopped", .{});
        }

        // ================================================================
        // Core API (satisfies HAL Microphone.Driver interface)
        // ================================================================

        /// Read audio samples (blocking)
        ///
        /// Returns processed audio (voice channels extracted).
        /// Buffer receives mono audio if single voice channel,
        /// or interleaved stereo if multiple voice channels.
        pub fn read(self: *Self, buffer: []i16) !usize {
            if (!self.initialized) return error.NotInitialized;
            if (!self.started) {
                // Auto-start on first read
                try self.start();
            }

            // Calculate how many raw samples we need
            // For N output samples with M voice channels, we need N * total_channels raw samples
            const voice_count = @popCount(self.voice_channel_mask);
            if (voice_count == 0) return error.NoVoiceChannels;

            const total_channels = self.getTotalChannels();
            const output_samples = buffer.len;
            const raw_samples_needed = (output_samples / voice_count) * total_channels;
            const raw_to_read = @min(raw_samples_needed, self.raw_buffer.len);

            // Read raw TDM data (interleaved: ch0, ch1, ch2, ch3, ch0, ch1, ...)
            const raw_samples = try self.i2s.read(self.raw_buffer[0..raw_to_read]);
            if (raw_samples == 0) return 0;

            // Extract voice channel(s) from interleaved data
            var out_idx: usize = 0;
            const frames = raw_samples / total_channels;

            for (0..frames) |frame| {
                const base = frame * total_channels;

                // Extract each voice channel
                for (0..max_channels) |ch| {
                    if (ch >= total_channels) break;
                    if ((self.voice_channel_mask & (@as(u8, 1) << @intCast(ch))) != 0) {
                        if (out_idx < buffer.len) {
                            buffer[out_idx] = self.raw_buffer[base + ch];
                            out_idx += 1;
                        }
                    }
                }
            }

            return out_idx;
        }

        /// Get the total number of I2S channels (up to last active)
        fn getTotalChannels(self: *const Self) usize {
            var last: usize = 2; // minimum
            for (self.config.channels, 0..) |role, i| {
                if (role != .disabled) last = @max(last, i + 1);
            }
            return last;
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

            log.info("Mic: Channel {} {s}", .{ channel, if (enabled) "enabled" else "disabled" });
        }

        /// Set gain for a channel
        pub fn setChannelGain(self: *Self, channel: u8, gain_db: i8) !void {
            if (channel >= max_channels) return error.InvalidChannel;

            const clamped_gain = @min(gain_db, max_gain_db);

            // Convert dB to Gain enum using the ADC's Gain type
            const gain = Adc.Gain.fromDb(@as(f32, @floatFromInt(clamped_gain)));
            try self.adc.setChannelGain(@intCast(channel), gain);

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

        /// Check if capture is started
        pub fn isStarted(self: *const Self) bool {
            return self.started;
        }
    };
}

// ============================================================================
// Errors
// ============================================================================

pub const MicError = error{
    NotInitialized,
    NoVoiceChannels,
    InvalidChannel,
};
