//! ESP-IDF Speaker Implementation
//!
//! Provides audio output using I2S with configurable DAC codec.
//! Supports mono output DAC chips like ES8311.
//!
//! Note: Power amplifier control should be managed separately using hal.switch_.
//!
//! Usage:
//!   const idf = @import("esp");
//!   const drivers = @import("drivers");
//!
//!   // Create I2S bus (shared with mic)
//!   var i2s = try idf.I2s.init(.{ ... });
//!
//!   // Create with ES8311 DAC driver
//!   const Es8311 = drivers.Es8311(idf.I2c);
//!   const Speaker = idf.Speaker(Es8311);
//!
//!   var dac = try Es8311.init(&i2c, .{});
//!   var speaker = try Speaker.init(&dac, &i2s, .{});
//!   defer speaker.deinit();
//!
//!   // Enable PA separately via switch
//!   try pa_switch.on();
//!   defer pa_switch.off() catch {};
//!
//!   const n = try speaker.write(&buffer);

const std = @import("std");
const log = std.log.scoped(.speaker);
const i2s_mod = @import("i2s.zig");
const I2s = i2s_mod.I2s;

/// Speaker configuration
pub const Config = struct {
    /// Initial volume (0-255)
    initial_volume: u8 = 180,
};

/// ESP Speaker driver
/// Generic over DAC driver type for flexibility
pub fn Speaker(comptime Dac: type) type {
    // Verify DAC has required methods
    comptime {
        if (!@hasDecl(Dac, "setVolume")) {
            @compileError("Dac must have setVolume method");
        }
    }

    return struct {
        const Self = @This();

        // ================================================================
        // DAC metadata (from driver type)
        // ================================================================

        /// Maximum volume level
        pub const max_volume: u8 = 255;

        // ================================================================
        // Instance fields
        // ================================================================

        dac: *Dac,
        i2s: *I2s,
        config: Config,
        initialized: bool = false,
        enabled: bool = false,

        /// Initialize speaker
        /// i2s: shared I2S bus instance (must be initialized with TX enabled)
        pub fn init(dac: *Dac, i2s: *I2s, config: Config) !Self {
            // Verify I2S has TX capability
            if (i2s.config.dout_pin == null) {
                return error.NoTxChannel;
            }

            var self = Self{
                .dac = dac,
                .i2s = i2s,
                .config = config,
                .initialized = true,
            };

            // Set initial volume
            try self.setVolume(config.initial_volume);

            log.info("Speaker: Initialized with I2S port {}", .{i2s.config.port});

            return self;
        }

        /// Deinitialize speaker
        /// Note: Does not deinit I2S (managed externally)
        pub fn deinit(self: *Self) void {
            if (self.initialized) {
                if (self.enabled) {
                    self.disable() catch {};
                }
                self.initialized = false;
                log.info("Speaker: Deinitialized", .{});
            }
        }

        /// Enable audio output (DAC + I2S channel)
        pub fn enable(self: *Self) !void {
            if (!self.initialized) return error.NotInitialized;
            if (self.enabled) return;

            // Enable DAC first
            try self.dac.enable(true);

            // Then enable I2S TX
            try self.i2s.enableTx();

            self.enabled = true;
            log.info("Speaker: Enabled", .{});
        }

        /// Disable audio output (DAC + I2S channel)
        pub fn disable(self: *Self) !void {
            if (!self.enabled) return;

            // Disable I2S TX first
            try self.i2s.disableTx();

            // Then disable DAC
            self.dac.enable(false) catch {};

            self.enabled = false;
            log.info("Speaker: Disabled", .{});
        }

        // ================================================================
        // Core API (satisfies HAL MonoSpeaker.Driver interface)
        // ================================================================

        /// Write audio samples (blocking)
        ///
        /// Writes mono audio samples to the speaker.
        /// Handles both 16-bit and 32-bit I2S modes:
        /// - 32-bit: Left-shift by 16 and duplicate to stereo
        /// - 16-bit: Duplicate mono to stereo directly
        pub fn write(self: *Self, buffer: []const i16) !usize {
            if (!self.initialized) return error.NotInitialized;
            if (!self.enabled) {
                // Auto-enable on first write
                try self.enable();
            }

            if (self.i2s.config.bits_per_sample == 32) {
                // Convert mono 16-bit to stereo 32-bit (left-justified)
                var stereo_buffer_32: [512]i32 = undefined;
                const max_mono_samples = stereo_buffer_32.len / 2;
                const mono_samples = @min(buffer.len, max_mono_samples);

                for (0..mono_samples) |i| {
                    const sample32: i32 = @as(i32, buffer[i]) << 16;
                    stereo_buffer_32[i * 2] = sample32; // Left channel
                    stereo_buffer_32[i * 2 + 1] = sample32; // Right channel
                }

                const stereo_bytes = std.mem.sliceAsBytes(stereo_buffer_32[0 .. mono_samples * 2]);
                const bytes_written = try self.i2s.write(stereo_bytes);
                return bytes_written / 8; // 4 bytes per sample * 2 channels
            } else {
                // 16-bit mode: duplicate mono to stereo directly
                var stereo_buffer_16: [1024]i16 = undefined;
                const max_mono_samples = stereo_buffer_16.len / 2;
                const mono_samples = @min(buffer.len, max_mono_samples);

                for (0..mono_samples) |i| {
                    stereo_buffer_16[i * 2] = buffer[i]; // Left channel
                    stereo_buffer_16[i * 2 + 1] = buffer[i]; // Right channel
                }

                const stereo_bytes = std.mem.sliceAsBytes(stereo_buffer_16[0 .. mono_samples * 2]);
                const bytes_written = try self.i2s.write(stereo_bytes);
                return bytes_written / 4; // 2 bytes per sample * 2 channels
            }
        }

        // ================================================================
        // Volume control
        // ================================================================

        /// Set volume (0-255)
        pub fn setVolume(self: *Self, volume: u8) !void {
            try self.dac.setVolume(volume);
            log.info("Speaker: Volume set to {}", .{volume});
        }

        /// Get current volume
        pub fn getVolume(self: *Self) !u8 {
            return try self.dac.getVolume();
        }

        // ================================================================
        // Status
        // ================================================================

        /// Check if speaker is enabled
        pub fn isEnabled(self: *const Self) bool {
            return self.enabled;
        }

        /// Get I2S port number
        pub fn getPort(self: *const Self) u8 {
            return self.i2s.config.port;
        }
    };
}
