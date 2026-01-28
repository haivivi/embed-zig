//! Microphone Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for audio input:
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   const n = board.mic.read(&buffer);    │
//! ├─────────────────────────────────────────┤
//! │ Microphone(spec)  ← HAL wrapper         │
//! │   - Unified read() interface            │
//! │   - Returns AEC-processed audio         │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← board impl      │
//! │   - Combines codec + I2S + AEC          │
//! │   - Returns clean audio samples         │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Design Principles
//!
//! The HAL layer provides a clean abstraction where:
//! - `read()` returns already AEC-processed audio (if AEC is enabled)
//! - The board implementation handles all complexity:
//!   - Chip configuration (ES8311, ES7210, etc.)
//!   - I2S data transfer
//!   - Multi-channel routing
//!   - AEC processing
//! - Blocking is handled by the underlying platform (FreeRTOS semaphore, io_uring, etc.)
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const mic_spec = struct {
//!     pub const Driver = Korvo2MicDriver;  // Board-specific implementation
//!     pub const meta = hal.spec.Meta{ .id = "mic.main" };
//! };
//!
//! // Create HAL wrapper
//! const MyMic = hal.Microphone(mic_spec);
//! var mic = MyMic.init(&driver_instance);
//!
//! // Use unified interface
//! var buffer: [160]i16 = undefined;  // 10ms @ 16kHz
//! const samples_read = try mic.read(&buffer);
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _MicrophoneMarker = struct {};

/// Check if a type is a Microphone peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _MicrophoneMarker;
}

// ============================================================================
// Audio Format Types
// ============================================================================

/// Audio sample format
pub const SampleFormat = enum {
    /// Signed 16-bit integer (-32768 to 32767)
    s16,
    /// Signed 32-bit integer
    s32,
    /// 32-bit float (-1.0 to 1.0)
    f32,
};

/// Microphone configuration (compile-time)
pub const Config = struct {
    /// Sample rate in Hz (e.g., 8000, 16000, 44100, 48000)
    sample_rate: u32 = 16000,
    /// Number of output channels (typically 1 after AEC)
    channels: u8 = 1,
    /// Bits per sample
    bits_per_sample: u8 = 16,
};

// ============================================================================
// Microphone HAL Wrapper
// ============================================================================

/// Microphone HAL component
///
/// Wraps a low-level Driver and provides:
/// - Unified read interface
/// - Clean audio output (AEC-processed if board supports it)
/// - Blocking read semantics
///
/// spec must define:
/// - `Driver`: struct implementing read method
/// - `meta`: spec.Meta with component id
///
/// Driver required methods:
/// - `fn read(self: *Self, buffer: []i16) !usize` - Blocking read, returns samples read
///
/// Driver optional methods:
/// - `fn setGain(self: *Self, gain_db: i8) !void` - Set microphone gain
/// - `fn start(self: *Self) !void` - Start recording
/// - `fn stop(self: *Self) !void` - Stop recording
///
/// Example:
/// ```zig
/// const mic_spec = struct {
///     pub const Driver = Korvo2MicDriver;
///     pub const meta = hal.spec.Meta{ .id = "mic.main" };
/// };
/// const MyMic = mic.from(mic_spec);
/// ```
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify read method signature: fn(*Self, []i16) !usize
        _ = @as(*const fn (*BaseDriver, []i16) anyerror!usize, &BaseDriver.read);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _MicrophoneMarker;

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

        /// Read audio samples (blocking)
        ///
        /// Blocks until audio data is available, then reads samples into buffer.
        /// Returns the number of samples actually read.
        ///
        /// The audio is already processed (AEC, noise reduction, etc.)
        /// depending on the board implementation.
        ///
        /// Example:
        /// ```zig
        /// var buffer: [160]i16 = undefined;  // 10ms @ 16kHz
        /// const n = try mic.read(&buffer);
        /// processAudio(buffer[0..n]);
        /// ```
        pub fn read(self: *Self, buffer: []i16) !usize {
            return self.driver.read(buffer);
        }

        // ================================================================
        // Optional API (depends on driver support)
        // ================================================================

        /// Set microphone gain in dB
        ///
        /// Typical range: 0-42dB for ES8311, 0-37.5dB for ES7210
        /// Returns error if driver doesn't support gain control.
        pub fn setGain(self: *Self, gain_db: i8) !void {
            if (@hasDecl(Driver, "setGain")) {
                return self.driver.setGain(gain_db);
            }
            return error.NotSupported;
        }

        /// Start recording
        ///
        /// Some drivers may require explicit start/stop.
        /// Returns error if driver doesn't support this.
        pub fn start(self: *Self) !void {
            if (@hasDecl(Driver, "start")) {
                return self.driver.start();
            }
            // If not supported, assume always running
        }

        /// Stop recording
        ///
        /// Some drivers may require explicit start/stop.
        /// Returns error if driver doesn't support this.
        pub fn stop(self: *Self) !void {
            if (@hasDecl(Driver, "stop")) {
                return self.driver.stop();
            }
            // If not supported, assume always running
        }

        /// Check if driver supports gain control
        pub fn supportsGain() bool {
            return @hasDecl(Driver, "setGain");
        }

        /// Check if driver supports start/stop
        pub fn supportsStartStop() bool {
            return @hasDecl(Driver, "start") and @hasDecl(Driver, "stop");
        }

        // ================================================================
        // Utilities
        // ================================================================

        /// Calculate buffer size for given duration
        ///
        /// Example:
        /// ```zig
        /// const buffer_size = MyMic.samplesForMs(10);  // 160 @ 16kHz
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

test "Microphone with mock driver" {
    // Mock driver implementation
    const MockDriver = struct {
        sample_value: i16 = 0,
        read_count: usize = 0,

        pub fn read(self: *@This(), buffer: []i16) !usize {
            self.read_count += 1;
            for (buffer) |*sample| {
                sample.* = self.sample_value;
            }
            return buffer.len;
        }

        pub fn setGain(self: *@This(), gain_db: i8) !void {
            _ = self;
            _ = gain_db;
        }
    };

    // Define spec
    const mic_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "mic.test" };
        pub const config = Config{ .sample_rate = 16000 };
    };

    const TestMic = from(mic_spec);

    var driver = MockDriver{ .sample_value = 1234 };
    var mic = TestMic.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("mic.test", TestMic.meta.id);

    // Test config
    try std.testing.expectEqual(@as(u32, 16000), TestMic.config.sample_rate);

    // Test read
    var buffer: [160]i16 = undefined;
    const n = try mic.read(&buffer);
    try std.testing.expectEqual(@as(usize, 160), n);
    try std.testing.expectEqual(@as(i16, 1234), buffer[0]);
    try std.testing.expectEqual(@as(usize, 1), driver.read_count);

    // Test setGain
    try mic.setGain(24);

    // Test utilities
    try std.testing.expectEqual(@as(u32, 160), TestMic.samplesForMs(10));
    try std.testing.expectEqual(@as(u32, 10), TestMic.msForSamples(160));

    // Test feature detection
    try std.testing.expect(TestMic.supportsGain());
}

test "Microphone without optional features" {
    const MinimalDriver = struct {
        pub fn read(_: *@This(), buffer: []i16) !usize {
            return buffer.len;
        }
    };

    const mic_spec = struct {
        pub const Driver = MinimalDriver;
        pub const meta = .{ .id = "mic.minimal" };
    };

    const TestMic = from(mic_spec);

    // Test feature detection
    try std.testing.expect(!TestMic.supportsGain());
    try std.testing.expect(!TestMic.supportsStartStop());
}

test "samplesForMs calculation" {
    const MockDriver = struct {
        pub fn read(_: *@This(), buffer: []i16) !usize {
            return buffer.len;
        }
    };

    // 16kHz
    const Mic16k = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "test" };
        pub const config = Config{ .sample_rate = 16000 };
    });
    try std.testing.expectEqual(@as(u32, 160), Mic16k.samplesForMs(10));
    try std.testing.expectEqual(@as(u32, 480), Mic16k.samplesForMs(30));

    // 48kHz
    const Mic48k = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "test" };
        pub const config = Config{ .sample_rate = 48000 };
    });
    try std.testing.expectEqual(@as(u32, 480), Mic48k.samplesForMs(10));
}
