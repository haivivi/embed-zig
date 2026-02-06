//! Motion Detection Types
//!
//! Common types for motion detection across platforms.
//! These types are used by both the motion detection library and HAL components.

const std = @import("std");

// ============================================================================
// Axis and Orientation
// ============================================================================

/// Axis identifier
pub const Axis = enum(u2) {
    x = 0,
    y = 1,
    z = 2,
};

/// Device orientation based on gravity direction
pub const Orientation = enum(u3) {
    /// Z-axis pointing up (screen facing up)
    face_up = 0,
    /// Z-axis pointing down (screen facing down)
    face_down = 1,
    /// X-axis pointing up (portrait)
    portrait = 2,
    /// X-axis pointing down (portrait upside-down)
    portrait_inverted = 3,
    /// Y-axis pointing up (landscape left)
    landscape_left = 4,
    /// Y-axis pointing down (landscape right)
    landscape_right = 5,
    /// Unknown/transitioning
    unknown = 7,
};

// ============================================================================
// Motion Actions
// ============================================================================

/// Shake event data
pub const ShakeData = struct {
    /// Peak magnitude of shake (in g)
    magnitude: f32,
    /// Duration of shake in milliseconds
    duration_ms: u32 = 0,
};

/// Tap event data
pub const TapData = struct {
    /// Which axis detected the tap
    axis: Axis,
    /// Number of taps (1 = single, 2 = double, etc.)
    count: u8,
    /// Direction: true = positive, false = negative
    positive: bool = true,
};

/// Tilt event data
pub const TiltData = struct {
    /// Roll angle in degrees (rotation around X axis)
    roll: f32,
    /// Pitch angle in degrees (rotation around Y axis)
    pitch: f32,
};

/// Flip event data (requires gyroscope for accurate detection)
pub const FlipData = struct {
    /// Previous orientation
    from: Orientation,
    /// Current orientation
    to: Orientation,
};

/// Freefall event data
pub const FreefallData = struct {
    /// Duration of freefall in milliseconds
    duration_ms: u32,
};

/// Motion action union - represents detected motion events
/// The available variants depend on sensor capabilities (comptime)
pub fn MotionAction(comptime has_gyro: bool) type {
    return union(enum) {
        /// Device was shaken (always available)
        shake: ShakeData,
        /// Device was tapped (always available)
        tap: TapData,
        /// Device tilt changed significantly (always available)
        tilt: TiltData,
        /// Device orientation flipped (requires gyro for accuracy)
        flip: if (has_gyro) FlipData else void,
        /// Device in freefall
        freefall: if (has_gyro) FreefallData else void,

        const Self = @This();

        /// Format for logging
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            switch (self) {
                .shake => |s| try writer.print("Shake(mag={d:.2}g)", .{s.magnitude}),
                .tap => |t| try writer.print("Tap({s}, count={})", .{ @tagName(t.axis), t.count }),
                .tilt => |t| try writer.print("Tilt(roll={d:.1}, pitch={d:.1})", .{ t.roll, t.pitch }),
                .flip => |f| if (has_gyro) {
                    try writer.print("Flip({s}->{s})", .{ @tagName(f.from), @tagName(f.to) });
                },
                .freefall => |f| if (has_gyro) {
                    try writer.print("Freefall({}ms)", .{f.duration_ms});
                },
            }
        }
    };
}

// ============================================================================
// Motion Event
// ============================================================================

/// Motion event with source identification and timestamp
pub fn MotionEvent(comptime has_gyro: bool) type {
    return struct {
        const Self = @This();
        pub const Action = MotionAction(has_gyro);

        /// Source component ID (from spec.meta.id)
        source: []const u8,
        /// The motion action that occurred
        action: Action,
        /// Event timestamp in milliseconds
        timestamp_ms: u64,

        /// Format for logging
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("Motion({s}: ", .{self.source});
            try self.action.format("", .{}, writer);
            try writer.print(" @{}ms)", .{self.timestamp_ms});
        }
    };
}

// ============================================================================
// Raw Sensor Data (for detector input)
// ============================================================================

/// Raw accelerometer data in g
pub const AccelData = struct {
    x: f32,
    y: f32,
    z: f32,

    /// Calculate magnitude
    pub fn magnitude(self: AccelData) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }
};

/// Raw gyroscope data in degrees per second
pub const GyroData = struct {
    x: f32,
    y: f32,
    z: f32,

    /// Calculate magnitude
    pub fn magnitude(self: GyroData) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }
};

/// Combined sensor sample
pub fn SensorSample(comptime has_gyro: bool) type {
    return struct {
        /// Accelerometer data (always present)
        accel: AccelData,
        /// Gyroscope data (only if has_gyro)
        gyro: if (has_gyro) GyroData else void,
        /// Timestamp in milliseconds
        timestamp_ms: u64,
    };
}

// ============================================================================
// Detection Thresholds
// ============================================================================

/// Configurable thresholds for motion detection
pub const Thresholds = struct {
    /// Shake detection: minimum acceleration change (g)
    shake_threshold: f32 = 1.5,
    /// Shake detection: minimum duration (ms)
    shake_min_duration: u32 = 100,
    /// Shake detection: maximum duration (ms)
    shake_max_duration: u32 = 1000,

    /// Tap detection: acceleration spike threshold (g)
    tap_threshold: f32 = 2.0,
    /// Tap detection: maximum tap duration (ms)
    tap_max_duration: u32 = 100,
    /// Tap detection: double-tap window (ms)
    double_tap_window: u32 = 300,

    /// Tilt detection: minimum angle change to report (degrees)
    tilt_threshold: f32 = 10.0,
    /// Tilt detection: debounce time (ms)
    tilt_debounce: u32 = 200,

    /// Flip detection: orientation change debounce (ms)
    flip_debounce: u32 = 500,

    /// Freefall detection: acceleration magnitude threshold (g)
    freefall_threshold: f32 = 0.3,
    /// Freefall detection: minimum duration (ms)
    freefall_min_duration: u32 = 50,

    /// Default thresholds
    pub const default = Thresholds{};

    /// Sensitive thresholds (lower values, more events)
    pub const sensitive = Thresholds{
        .shake_threshold = 1.0,
        .tap_threshold = 1.5,
        .tilt_threshold = 5.0,
    };

    /// Insensitive thresholds (higher values, fewer events)
    pub const insensitive = Thresholds{
        .shake_threshold = 2.5,
        .tap_threshold = 3.0,
        .tilt_threshold = 20.0,
    };
};

// ============================================================================
// HAL Integration Helpers
// ============================================================================

/// Create AccelData from any struct with x, y, z fields
pub fn accelFrom(data: anytype) AccelData {
    return .{
        .x = if (@hasField(@TypeOf(data), "x")) data.x else 0,
        .y = if (@hasField(@TypeOf(data), "y")) data.y else 0,
        .z = if (@hasField(@TypeOf(data), "z")) data.z else 0,
    };
}

/// Create GyroData from any struct with x, y, z fields
pub fn gyroFrom(data: anytype) GyroData {
    return .{
        .x = if (@hasField(@TypeOf(data), "x")) data.x else 0,
        .y = if (@hasField(@TypeOf(data), "y")) data.y else 0,
        .z = if (@hasField(@TypeOf(data), "z")) data.z else 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "AccelData magnitude" {
    const data = AccelData{ .x = 0, .y = 0, .z = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), data.magnitude(), 0.001);

    const data2 = AccelData{ .x = 1.0, .y = 1.0, .z = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.732), data2.magnitude(), 0.01);
}

test "MotionAction with gyro" {
    const Action = MotionAction(true);
    const shake = Action{ .shake = .{ .magnitude = 2.5, .duration_ms = 100 } };
    try std.testing.expectEqual(@as(f32, 2.5), shake.shake.magnitude);

    // Flip should be available with gyro
    const flip = Action{ .flip = .{ .from = .face_up, .to = .face_down } };
    try std.testing.expectEqual(Orientation.face_up, flip.flip.from);
}

test "MotionAction without gyro" {
    const Action = MotionAction(false);
    const shake = Action{ .shake = .{ .magnitude = 2.5, .duration_ms = 100 } };
    try std.testing.expectEqual(@as(f32, 2.5), shake.shake.magnitude);

    // Flip field exists but is void type
    _ = Action{ .flip = {} };
}

test "SensorSample with gyro" {
    const Sample = SensorSample(true);
    const s = Sample{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .gyro = .{ .x = 0, .y = 0, .z = 0 },
        .timestamp_ms = 100,
    };
    try std.testing.expectEqual(@as(f32, 1.0), s.accel.z);
}

test "SensorSample without gyro" {
    const Sample = SensorSample(false);
    const s = Sample{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .gyro = {},
        .timestamp_ms = 100,
    };
    try std.testing.expectEqual(@as(f32, 1.0), s.accel.z);
}
