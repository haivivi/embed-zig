//! Mono Speaker Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for mono audio output:
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   const n = board.speaker.write(&buf);  │
//! ├─────────────────────────────────────────┤
//! │ MonoSpeaker(spec)  ← HAL wrapper        │
//! │   - Unified write() interface           │
//! │   - Volume/mute control (optional)      │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← board impl      │
//! │   - I2S + DAC configuration             │
//! │   - Outputs audio samples               │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Design Principles
//!
//! The HAL layer provides a clean abstraction where:
//! - `write()` sends mono audio samples to the speaker
//! - The board implementation handles all complexity:
//!   - DAC chip configuration (ES8311, etc.)
//!   - I2S data transfer
//! - Blocking is handled by the underlying platform
//! - Power control (start/stop) is managed by separate Switch components
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const speaker_spec = struct {
//!     pub const Driver = Korvo2SpeakerDriver;
//!     pub const meta = hal.spec.Meta{ .id = "speaker.main" };
//! };
//!
//! // Create HAL wrapper
//! const MySpeaker = hal.mono_speaker.from(speaker_spec);
//! var speaker = MySpeaker.init(&driver_instance);
//!
//! // Use unified interface
//! var buffer: [160]i16 = undefined;  // 10ms @ 16kHz
//! generateSineWave(&buffer);
//! const samples_written = try speaker.write(&buffer);
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _MonoSpeakerMarker = struct {};

/// Check if a type is a MonoSpeaker peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _MonoSpeakerMarker;
}

// ============================================================================
// Audio Format Types
// ============================================================================

/// Speaker configuration (compile-time)
pub const Config = struct {
    /// Sample rate in Hz (e.g., 8000, 16000, 44100, 48000)
    sample_rate: u32 = 16000,
    /// Bits per sample
    bits_per_sample: u8 = 16,
};

// ============================================================================
// MonoSpeaker HAL Wrapper
// ============================================================================

/// MonoSpeaker HAL component
///
/// Wraps a low-level Driver and provides:
/// - Unified write interface
/// - Optional volume/mute control
/// - Blocking write semantics
///
/// spec must define:
/// - `Driver`: struct implementing write method
/// - `meta`: spec.Meta with component id
///
/// Driver required methods:
/// - `fn write(self: *Self, buffer: []const i16) !usize` - Blocking write, returns samples written
///
/// Driver optional methods:
/// - `fn setVolume(self: *Self, volume: u8) !void` - Set output volume (0-255)
/// - `fn setMute(self: *Self, mute: bool) !void` - Mute/unmute output
///
/// Example:
/// ```zig
/// const speaker_spec = struct {
///     pub const Driver = Korvo2SpeakerDriver;
///     pub const meta = hal.spec.Meta{ .id = "speaker.main" };
/// };
/// const MySpeaker = mono_speaker.from(speaker_spec);
/// ```
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify write method signature: fn(*Self, []const i16) !usize
        _ = @as(*const fn (*BaseDriver, []const i16) anyerror!usize, &BaseDriver.write);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _MonoSpeakerMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// Configuration (if provided in spec)
        pub const config: Config = if (@hasDecl(spec, "config")) spec.config else .{};

        // ================================================================
        // Instance Fields
        // ================================================================

        /// The underlying driver instance
        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ================================================================
        // Core API
        // ================================================================

        /// Write audio samples (blocking)
        ///
        /// Blocks until the audio data is written to the output buffer.
        /// Returns the number of samples actually written.
        ///
        /// Example:
        /// ```zig
        /// var buffer: [160]i16 = undefined;  // 10ms @ 16kHz
        /// generateTone(&buffer, 440);  // 440Hz sine wave
        /// const n = try speaker.write(&buffer);
        /// ```
        pub fn write(self: *Self, buffer: []const i16) !usize {
            return self.driver.write(buffer);
        }

        // ================================================================
        // Optional API (depends on driver support)
        // ================================================================

        /// Set output volume (0-255)
        ///
        /// 0 = minimum/mute, 255 = maximum
        /// Returns error if driver doesn't support volume control.
        pub fn setVolume(self: *Self, volume: u8) !void {
            if (@hasDecl(Driver, "setVolume")) {
                return self.driver.setVolume(volume);
            }
            return error.NotSupported;
        }

        /// Mute or unmute output
        ///
        /// Returns error if driver doesn't support mute control.
        pub fn setMute(self: *Self, mute: bool) !void {
            if (@hasDecl(Driver, "setMute")) {
                return self.driver.setMute(mute);
            }
            return error.NotSupported;
        }

        /// Check if driver supports volume control
        pub fn supportsVolume() bool {
            return @hasDecl(Driver, "setVolume");
        }

        /// Check if driver supports mute control
        pub fn supportsMute() bool {
            return @hasDecl(Driver, "setMute");
        }

        // ================================================================
        // Utilities
        // ================================================================

        /// Calculate buffer size for given duration
        ///
        /// Example:
        /// ```zig
        /// const buffer_size = MySpeaker.samplesForMs(10);  // 160 @ 16kHz
        /// var buffer: [buffer_size]i16 = undefined;
        /// ```
        pub fn samplesForMs(duration_ms: u32) u32 {
            return config.sample_rate * duration_ms / 1000;
        }

        /// Calculate duration in milliseconds for given sample count
        pub fn msForSamples(samples: u32) u32 {
            return samples * 1000 / config.sample_rate;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "MonoSpeaker with mock driver" {
    // Mock driver implementation
    const MockDriver = struct {
        write_count: usize = 0,
        last_sample: i16 = 0,
        volume: u8 = 128,
        muted: bool = false,

        pub fn write(self: *@This(), buffer: []const i16) !usize {
            self.write_count += 1;
            if (buffer.len > 0) {
                self.last_sample = buffer[0];
            }
            return buffer.len;
        }

        pub fn setVolume(self: *@This(), volume: u8) !void {
            self.volume = volume;
        }

        pub fn setMute(self: *@This(), mute: bool) !void {
            self.muted = mute;
        }
    };

    // Define spec
    const speaker_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "speaker.test" };
        pub const config = Config{ .sample_rate = 16000 };
    };

    const TestSpeaker = from(speaker_spec);

    var driver = MockDriver{};
    var speaker = TestSpeaker.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("speaker.test", TestSpeaker.meta.id);

    // Test config
    try std.testing.expectEqual(@as(u32, 16000), TestSpeaker.config.sample_rate);

    // Test write
    const buffer = [_]i16{ 1000, 2000, 3000 };
    const n = try speaker.write(&buffer);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(i16, 1000), driver.last_sample);
    try std.testing.expectEqual(@as(usize, 1), driver.write_count);

    // Test setVolume
    try speaker.setVolume(200);
    try std.testing.expectEqual(@as(u8, 200), driver.volume);

    // Test setMute
    try speaker.setMute(true);
    try std.testing.expect(driver.muted);

    // Test utilities
    try std.testing.expectEqual(@as(u32, 160), TestSpeaker.samplesForMs(10));
    try std.testing.expectEqual(@as(u32, 10), TestSpeaker.msForSamples(160));

    // Test feature detection
    try std.testing.expect(TestSpeaker.supportsVolume());
    try std.testing.expect(TestSpeaker.supportsMute());
}

test "MonoSpeaker without optional features" {
    const MinimalDriver = struct {
        pub fn write(_: *@This(), buffer: []const i16) !usize {
            return buffer.len;
        }
    };

    const speaker_spec = struct {
        pub const Driver = MinimalDriver;
        pub const meta = .{ .id = "speaker.minimal" };
    };

    const TestSpeaker = from(speaker_spec);

    // Test feature detection
    try std.testing.expect(!TestSpeaker.supportsVolume());
    try std.testing.expect(!TestSpeaker.supportsMute());
}

test "samplesForMs calculation" {
    const MockDriver = struct {
        pub fn write(_: *@This(), buffer: []const i16) !usize {
            return buffer.len;
        }
    };

    // 16kHz
    const Speaker16k = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "test" };
        pub const config = Config{ .sample_rate = 16000 };
    });
    try std.testing.expectEqual(@as(u32, 160), Speaker16k.samplesForMs(10));
    try std.testing.expectEqual(@as(u32, 480), Speaker16k.samplesForMs(30));

    // 48kHz
    const Speaker48k = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "test" };
        pub const config = Config{ .sample_rate = 48000 };
    });
    try std.testing.expectEqual(@as(u32, 480), Speaker48k.samplesForMs(10));
}
