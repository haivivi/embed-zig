//! ESP-IDF Microphone Implementation
//!
//! Provides audio input using I2S with configurable ADC codec.
//! Supports multi-channel ADC chips like ES7210 with AEC reference channel.
//! Integrates AEC (Acoustic Echo Cancellation) processing when enabled.
//!
//! Usage:
//!   const idf = @import("esp");
//!   const drivers = @import("drivers");
//!
//!   // Create I2S bus (shared with speaker)
//!   var i2s = try idf.I2s.init(.{ ... });
//!
//!   // Create with ES7210 ADC driver
//!   const Es7210 = drivers.Es7210(idf.I2c);
//!   const Mic = idf.Mic(Es7210);
//!
//!   var adc = try Es7210.init(&i2c, .{});
//!   var mic = try Mic.init(&adc, &i2s, .{
//!       .channels = .{ .aec_ref, .voice, .disabled, .voice },  // RMNM format
//!       .aec = .{ .enabled = true, .mode = .voice_communication },
//!   });
//!   defer mic.deinit();
//!
//!   try mic.start();
//!   const n = try mic.read(&buffer);  // Returns AEC-processed audio

const std = @import("std");
const log = std.log.scoped(.mic);
const i2s_mod = @import("i2s.zig");
const I2s = i2s_mod.I2s;

// ============================================================================
// AEC C Helper bindings
// ============================================================================

/// Opaque AEC handle type
const AecHandle = opaque {};

/// AEC helper C functions
extern fn aec_helper_create(input_format: [*:0]const u8, filter_length: c_int, aec_type: c_int, mode: c_int) ?*AecHandle;
extern fn aec_helper_process(handle: *AecHandle, indata: [*]const i16, outdata: [*]i16) c_int;
extern fn aec_helper_get_chunksize(handle: *AecHandle) c_int;
extern fn aec_helper_get_total_channels(handle: *AecHandle) c_int;
extern fn aec_helper_destroy(handle: *AecHandle) void;
extern fn aec_helper_alloc_buffer(samples: c_int) ?[*]i16;
extern fn aec_helper_free_buffer(buf: [*]i16) void;

/// Channel role in audio processing
pub const ChannelRole = enum {
    /// Channel is disabled
    disabled,
    /// Voice microphone input
    voice,
    /// AEC reference signal (e.g., from speaker output loopback)
    aec_ref,
};

/// AEC processing mode
pub const AecMode = enum(c_int) {
    /// Speech recognition - optimized for wake word detection
    speech_recognition = 0,
    /// Voice communication - optimized for full-duplex calls (16kHz)
    voice_communication = 1,
    /// Voice communication 8kHz - lower quality, lower CPU
    voice_communication_8k = 2,
};

/// AEC performance mode
pub const AecPerfMode = enum(c_int) {
    /// Low cost mode - lower CPU usage
    low_cost = 0,
    /// High performance mode - better quality
    high_perf = 1,
};

/// AEC (Acoustic Echo Cancellation) configuration
pub const AecConfig = struct {
    /// Enable AEC processing
    enabled: bool = true,
    /// AEC mode - determines optimization target
    mode: AecMode = .voice_communication,
    /// Performance mode
    perf_mode: AecPerfMode = .low_cost,
    /// Filter length (1-6, higher = better but more CPU)
    /// Recommended: 4 for ESP32-S3
    filter_length: u8 = 4,
};

/// Mic configuration
pub const Config = struct {
    /// Channel roles (up to 4 channels for ES7210)
    /// 
    /// ES7210 TDM output order (per datasheet Fig.2e): Ch1, Ch3, Ch2, Ch4
    /// With I2S STD 32-bit stereo:
    ///   L (32-bit) = [MIC1 (HI)] + [MIC3/REF (LO)]
    ///   R (32-bit) = [MIC2 (HI)] + [MIC4 (LO)]
    /// 
    /// Channel mapping for Korvo-2 V3:
    ///   Channel 0 = MIC1 (voice)
    ///   Channel 1 = MIC3/REF (aec_ref)
    ///   Channel 2 = MIC2 (voice)
    ///   Channel 3 = MIC4 (disabled)
    channels: [4]ChannelRole = .{ .voice, .aec_ref, .voice, .disabled },
    /// AEC configuration
    aec: AecConfig = .{},
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

        /// AEC chunk size in samples (typically 256 for 16ms @ 16kHz)
        /// This is determined at runtime by the AEC library
        const aec_chunk_size: usize = 256;

        /// Raw buffer size - needs to hold at least one AEC chunk * total channels
        const raw_buffer_size: usize = aec_chunk_size * @as(usize, max_channels);

        // ================================================================
        // Instance fields
        // ================================================================

        adc: *Adc,
        i2s: *I2s,
        config: Config,
        initialized: bool = false,
        started: bool = false,

        // Runtime state
        voice_channel_mask: u8 = 0,
        ref_channel: ?u8 = null,
        total_channels: u8 = 0, // Logical channels (from AEC format, e.g., "RM" = 2)
        bits_per_sample: u8 = 16, // I2S bits per sample (16 or 32)

        // AEC state
        aec_handle: ?*AecHandle = null,
        aec_chunk: usize = 0, // Actual chunk size from AEC library
        aec_input_format: [8:0]u8 = undefined, // e.g., "RM\x00"
        aec_out_buffer: ?[*]i16 = null, // 16-byte aligned buffer from heap

        // Buffer for multi-channel capture and processing
        // I2S data is 32-bit per channel, we convert to 16-bit for AEC
        raw_buffer_32: [raw_buffer_size]i32 = undefined, // Raw 32-bit I2S data
        raw_buffer: [raw_buffer_size]i16 = undefined, // Converted 16-bit for AEC

        /// Initialize microphone
        /// i2s: shared I2S bus instance (must be initialized with RX enabled)
        pub fn init(adc: *Adc, i2s: *I2s, config: Config) !Self {
            var self = Self{
                .adc = adc,
                .i2s = i2s,
                .config = config,
                .bits_per_sample = i2s.config.bits_per_sample,
            };

            // For STD mode with ES7210 TDM:
            // ES7210 TDM output (per datasheet): Ch1, Ch3, Ch2, Ch4
            // I2S STD 32-bit stereo:
            //   L (32-bit) = [MIC1 (HI)] + [MIC3/REF (LO)]
            //   R (32-bit) = [MIC2 (HI)] + [MIC4 (LO)]
            // Channel mapping:
            //   Channel 0 = MIC1 (L_HI)
            //   Channel 1 = REF/MIC3 (L_LO)
            //   Channel 2 = MIC2 (R_HI)
            //   Channel 3 = MIC4 (R_LO)

            // Analyze channel configuration
            for (config.channels, 0..) |role, i| {
                switch (role) {
                    .voice => {
                        self.voice_channel_mask |= @as(u8, 1) << @intCast(i);
                    },
                    .aec_ref => {
                        self.ref_channel = @intCast(i);
                    },
                    .disabled => {},
                }
            }

            // For AEC with ES7210 TDM + I2S STD mode, always use "MR" format
            // We extract MIC1 (L_HI) and REF (L_LO) in readWithAec
            self.aec_input_format[0] = 'M';
            self.aec_input_format[1] = 'R';
            self.aec_input_format[2] = 0; // Null terminate
            self.total_channels = 2; // "MR" = 2 logical channels for AEC

            log.info("Mic: Initialized with {} voice channels, AEC ref: {?}, format: MR", .{
                @popCount(self.voice_channel_mask),
                self.ref_channel,
            });

            // Initialize AEC if enabled and ref channel is configured
            if (config.aec.enabled and self.ref_channel != null) {
                log.info("Mic: Creating AEC with format: {s}", .{@as([*:0]const u8, &self.aec_input_format)});

                self.aec_handle = aec_helper_create(
                    &self.aec_input_format,
                    @intCast(config.aec.filter_length),
                    @intFromEnum(config.aec.mode),
                    @intFromEnum(config.aec.perf_mode),
                );

                if (self.aec_handle) |handle| {
                    self.aec_chunk = @intCast(aec_helper_get_chunksize(handle));

                    // Allocate 16-byte aligned output buffer (required by ESP-SR AEC)
                    self.aec_out_buffer = aec_helper_alloc_buffer(@intCast(self.aec_chunk));
                    if (self.aec_out_buffer == null) {
                        log.err("Mic: Failed to allocate aligned AEC output buffer", .{});
                        aec_helper_destroy(handle);
                        self.aec_handle = null;
                    } else {
                        log.info("Mic: AEC enabled, chunk size: {} samples", .{self.aec_chunk});
                    }
                } else {
                    log.warn("Mic: Failed to create AEC, continuing without echo cancellation", .{});
                }
            } else {
                log.info("Mic: AEC disabled", .{});
            }

            self.initialized = true;
            return self;
        }

        /// Deinitialize microphone
        /// Note: Does not deinit I2S (managed externally)
        pub fn deinit(self: *Self) void {
            if (self.initialized) {
                if (self.started) {
                    self.stop() catch {};
                }

                // Free AEC output buffer
                if (self.aec_out_buffer) |buf| {
                    aec_helper_free_buffer(buf);
                    self.aec_out_buffer = null;
                }

                // Destroy AEC instance
                if (self.aec_handle) |handle| {
                    log.info("Mic: Destroying AEC", .{});
                    aec_helper_destroy(handle);
                    self.aec_handle = null;
                }

                self.initialized = false;
            }
        }

        /// Start audio capture
        pub fn start(self: *Self) !void {
            if (!self.initialized) return error.NotInitialized;
            if (self.started) return;

            try self.i2s.enableRx();
            self.started = true;
            log.info("Mic: Started", .{});
        }

        /// Stop audio capture
        pub fn stop(self: *Self) !void {
            if (!self.started) return;

            try self.i2s.disableRx();
            self.started = false;
            log.info("Mic: Stopped", .{});
        }

        // ================================================================
        // Core API (satisfies HAL Microphone.Driver interface)
        // ================================================================

        /// Read audio samples (blocking)
        ///
        /// Returns processed audio:
        /// - If AEC is enabled: echo-cancelled mono audio
        /// - If AEC is disabled: voice channels extracted from raw TDM data
        ///
        /// Buffer receives mono audio (single channel output from AEC).
        pub fn read(self: *Self, buffer: []i16) !usize {
            if (!self.initialized) return error.NotInitialized;
            if (!self.started) {
                // Auto-start on first read
                try self.start();
            }

            const voice_count = @popCount(self.voice_channel_mask);
            if (voice_count == 0) return error.NoVoiceChannels;

            const total_channels = self.getTotalChannels();

            // If AEC is enabled, use AEC processing path
            if (self.aec_handle) |aec_handle| {
                return self.readWithAec(aec_handle, buffer, total_channels);
            }

            // No AEC - extract voice channels directly from TDM data
            return self.readWithoutAec(buffer, total_channels, voice_count);
        }

        /// Read with AEC processing
        /// 
        /// ES7210 TDM output order (per datasheet Fig.2e): Ch1, Ch3, Ch2, Ch4 (interleaved)
        /// With I2S STD 32-bit stereo mode:
        ///   L (32-bit) = [MIC1 (HI 16-bit)] + [MIC3/REF (LO 16-bit)]
        ///   R (32-bit) = [MIC2 (HI 16-bit)] + [MIC4 (LO 16-bit)]
        /// 
        /// AEC uses "MR" format: interleaved [Mic, Ref, Mic, Ref, ...]
        fn readWithAec(self: *Self, aec_handle: *AecHandle, buffer: []i16, total_channels: usize) !usize {
            _ = total_channels; // Not used in STD mode

            const chunk_size = self.aec_chunk;
            if (chunk_size == 0) return error.AecNotInitialized;

            const out_buffer = self.aec_out_buffer orelse return error.AecNotInitialized;

            // In STD 32-bit stereo mode, each "frame" = 2 x 32-bit samples (L + R)
            // We need chunk_size frames to process one AEC chunk
            const stereo_frames_needed = chunk_size;
            const raw_samples_needed = stereo_frames_needed * 2; // L + R per frame

            var out_idx: usize = 0;

            // Process in chunks
            while (out_idx < buffer.len) {
                const raw_to_read = @min(raw_samples_needed, self.raw_buffer_32.len);

                // Read I2S data as 32-bit samples (stereo: L, R, L, R, ...)
                const raw_bytes = std.mem.sliceAsBytes(self.raw_buffer_32[0..raw_to_read]);
                const bytes_read = try self.i2s.read(raw_bytes);
                const raw_samples = bytes_read / 4; // 32-bit samples
                if (raw_samples == 0) break;

                const frames_read = raw_samples / 2; // Stereo frames

                // Extract MIC1 and REF from ES7210 TDM data packed in STD stereo
                // L (32-bit) = [MIC1 (HI)] + [REF (LO)]
                // Build "MR" format for AEC: [Mic, Ref, Mic, Ref, ...]
                for (0..frames_read) |i| {
                    const L: i32 = self.raw_buffer_32[i * 2 + 0];
                    const mic1: i16 = @truncate(L >> 16); // MIC1 = L_HI
                    const ref: i16 = @truncate(L & 0xFFFF); // REF = L_LO (MIC3)

                    // "MR" format: [Mic, Ref] interleaved
                    self.raw_buffer[i * 2 + 0] = mic1;
                    self.raw_buffer[i * 2 + 1] = ref;
                }

                // Process through AEC
                const aec_out_samples = aec_helper_process(
                    aec_handle,
                    &self.raw_buffer,
                    out_buffer,
                );

                if (aec_out_samples <= 0) {
                    log.warn("Mic: AEC process returned {}", .{aec_out_samples});
                    break;
                }

                // Copy AEC output to user buffer
                const samples_to_copy = @min(@as(usize, @intCast(aec_out_samples)), buffer.len - out_idx);
                @memcpy(buffer[out_idx..][0..samples_to_copy], out_buffer[0..samples_to_copy]);
                out_idx += samples_to_copy;
            }

            return out_idx;
        }

        /// Read without AEC - extract voice channels from STD stereo data
        /// 
        /// ES7210 TDM output order (per datasheet): Ch1, Ch3, Ch2, Ch4
        /// With I2S STD 32-bit stereo:
        ///   L (32-bit) = [MIC1 (HI)] + [MIC3/REF (LO)]
        ///   R (32-bit) = [MIC2 (HI)] + [MIC4 (LO)]
        fn readWithoutAec(self: *Self, buffer: []i16, total_channels: usize, voice_count: u8) !usize {
            _ = total_channels;
            _ = voice_count;

            const output_samples = buffer.len;
            // Each stereo frame gives us potentially multiple voice samples
            // For STD mode: 1 stereo frame = 2 x 32-bit = 4 x 16-bit channels
            const frames_needed = output_samples; // One voice sample per frame
            const raw_samples_needed = frames_needed * 2; // 2 x 32-bit per stereo frame
            const raw_to_read = @min(raw_samples_needed, self.raw_buffer_32.len);

            // Read I2S data as 32-bit samples
            const raw_bytes = std.mem.sliceAsBytes(self.raw_buffer_32[0..raw_to_read]);
            const bytes_read = try self.i2s.read(raw_bytes);
            const raw_samples = bytes_read / 4; // 32-bit samples
            if (raw_samples == 0) return 0;

            const frames_read = raw_samples / 2; // Stereo frames

            // Extract voice channel(s) from ES7210 TDM data in STD stereo format
            var out_idx: usize = 0;

            for (0..frames_read) |frame| {
                const L: i32 = self.raw_buffer_32[frame * 2 + 0];
                const R: i32 = self.raw_buffer_32[frame * 2 + 1];

                // Extract channels based on voice_channel_mask
                // Channel mapping (ES7210 TDM in STD 32-bit stereo):
                //   Channel 0 (MIC1) = L_HI
                //   Channel 1 (REF/MIC3) = L_LO
                //   Channel 2 (MIC2) = R_HI
                //   Channel 3 (MIC4) = R_LO

                // Extract MIC1 if voice channel 0 is enabled
                if ((self.voice_channel_mask & 0x01) != 0 and out_idx < buffer.len) {
                    buffer[out_idx] = @truncate(L >> 16); // MIC1 = L_HI
                    out_idx += 1;
                }
                // Extract MIC2 if voice channel 2 is enabled
                if ((self.voice_channel_mask & 0x04) != 0 and out_idx < buffer.len) {
                    buffer[out_idx] = @truncate(R >> 16); // MIC2 = R_HI
                    out_idx += 1;
                }
            }

            return out_idx;
        }

        /// Get the total number of I2S channels (cached from init)
        fn getTotalChannels(self: *const Self) usize {
            return self.total_channels;
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

        /// Enable AEC processing at runtime
        /// Note: This requires AEC to be configured at init time
        pub fn enableAec(self: *Self) !void {
            if (self.ref_channel == null) {
                return error.NoRefChannel;
            }

            if (self.aec_handle != null) {
                // Already enabled
                return;
            }

            // Create AEC instance
            self.aec_handle = aec_helper_create(
                &self.aec_input_format,
                @intCast(self.config.aec.filter_length),
                @intFromEnum(self.config.aec.mode),
                @intFromEnum(self.config.aec.perf_mode),
            );

            if (self.aec_handle) |handle| {
                self.aec_chunk = @intCast(aec_helper_get_chunksize(handle));
                log.info("Mic: AEC enabled at runtime, chunk size: {}", .{self.aec_chunk});
            } else {
                return error.AecCreateFailed;
            }
        }

        /// Disable AEC processing at runtime
        pub fn disableAec(self: *Self) void {
            if (self.aec_handle) |handle| {
                aec_helper_destroy(handle);
                self.aec_handle = null;
                log.info("Mic: AEC disabled", .{});
            }
        }

        /// Check if AEC is currently active
        pub fn isAecEnabled(self: *const Self) bool {
            return self.aec_handle != null;
        }

        /// Check if AEC can be enabled (has ref channel configured)
        pub fn canEnableAec(self: *const Self) bool {
            return self.ref_channel != null;
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
    NoRefChannel,
    AecCreateFailed,
    AecNotInitialized,
};

// ============================================================================
// Tests
// ============================================================================

test "channel mask calculation" {
    // Test voice channel mask calculation
    const channels = [4]ChannelRole{ .voice, .voice, .disabled, .aec_ref };

    var mask: u8 = 0;
    for (0..4) |i| {
        if (channels[i] == .voice) {
            mask |= @as(u8, 1) << @intCast(i);
        }
    }

    // Channels 0 and 1 are voice, so mask should be 0b0011 = 3
    try std.testing.expectEqual(@as(u8, 0b0011), mask);
}

test "total channels calculation" {
    // Test total channel count (all non-disabled channels)
    const channels = [4]ChannelRole{ .voice, .voice, .disabled, .aec_ref };

    var count: u8 = 0;
    for (channels) |role| {
        if (role != .disabled) count += 1;
    }

    // 2 voice + 1 aec_ref = 3 total
    try std.testing.expectEqual(@as(u8, 3), count);
}

test "de-interleave TDM data" {
    // Simulate TDM data: 4 channels interleaved, extract channels 0 and 1 (voice)
    // Raw data: [ch0_f0, ch1_f0, ch2_f0, ch3_f0, ch0_f1, ch1_f1, ch2_f1, ch3_f1, ...]
    const raw_data = [_]i16{
        100, 200, 300, 400, // Frame 0: ch0=100, ch1=200, ch2=300, ch3=400
        110, 210, 310, 410, // Frame 1
        120, 220, 320, 420, // Frame 2
    };

    const total_channels: usize = 4;
    const voice_mask: u8 = 0b0011; // channels 0 and 1 are voice

    var output: [6]i16 = undefined;
    var out_idx: usize = 0;
    const frames = raw_data.len / total_channels;

    for (0..frames) |frame| {
        const base = frame * total_channels;
        for (0..total_channels) |ch| {
            if ((voice_mask & (@as(u8, 1) << @intCast(ch))) != 0) {
                output[out_idx] = raw_data[base + ch];
                out_idx += 1;
            }
        }
    }

    // Expected: [100, 200, 110, 210, 120, 220] (voice channels from each frame)
    try std.testing.expectEqual(@as(usize, 6), out_idx);
    try std.testing.expectEqual(@as(i16, 100), output[0]);
    try std.testing.expectEqual(@as(i16, 200), output[1]);
    try std.testing.expectEqual(@as(i16, 110), output[2]);
    try std.testing.expectEqual(@as(i16, 210), output[3]);
    try std.testing.expectEqual(@as(i16, 120), output[4]);
    try std.testing.expectEqual(@as(i16, 220), output[5]);
}

test "ceiling division for sample calculation" {
    // Test the ceiling division used in read()
    // Formula: (output_samples + voice_count - 1) / voice_count

    // Case 1: 160 samples, 2 voice channels -> 80 frames needed
    {
        const output_samples: usize = 160;
        const voice_count: usize = 2;
        const frames_needed = (output_samples + voice_count - 1) / voice_count;
        try std.testing.expectEqual(@as(usize, 80), frames_needed);
    }

    // Case 2: 159 samples, 2 voice channels -> 80 frames needed (ceiling)
    {
        const output_samples: usize = 159;
        const voice_count: usize = 2;
        const frames_needed = (output_samples + voice_count - 1) / voice_count;
        try std.testing.expectEqual(@as(usize, 80), frames_needed);
    }

    // Case 3: 161 samples, 2 voice channels -> 81 frames needed
    {
        const output_samples: usize = 161;
        const voice_count: usize = 2;
        const frames_needed = (output_samples + voice_count - 1) / voice_count;
        try std.testing.expectEqual(@as(usize, 81), frames_needed);
    }
}
