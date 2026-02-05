//! Motion Detection HAL Component
//!
//! Provides motion detection as a HAL peripheral using lib/motion.Detector.
//! Supports shake, tap, tilt, flip (with gyro), and freefall (with gyro) detection.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   board.nextEvent() -> .motion event   │
//! ├─────────────────────────────────────────┤
//! │ hal.motion.from(spec)  ← HAL           │
//! │   - Reads IMU sensor data              │
//! │   - Runs motion.Detector algorithms    │
//! │   - Generates motion events            │
//! ├─────────────────────────────────────────┤
//! │ lib/motion.Detector  ← detection lib   │
//! │   - Shake/tap/tilt/flip/freefall       │
//! ├─────────────────────────────────────────┤
//! │ IMU Driver (spec.Imu)  ← hardware      │
//! │   - readAccel() -> AccelData           │
//! │   - readGyro() -> GyroData (optional)  │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // In platform.zig
//! const spec = struct {
//!     pub const motion = hal.motion.from(.{
//!         .Imu = hw.ImuDriver,
//!         .meta = .{ .id = "motion.main" },
//!     });
//! };
//!
//! // Background task (recommended)
//! fn motionTask(board: *Board) void {
//!     while (Board.isRunning()) {
//!         board.pollMotion();
//!         Board.time.sleepMs(20);
//!     }
//! }
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _MotionMarker = struct {};

/// Check if a type is a Motion peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _MotionMarker;
}

// ============================================================================
// Motion Event Types (for board.Event union)
// ============================================================================

/// Axis identifier (matches motion.Axis)
pub const Axis = enum(u2) {
    x = 0,
    y = 1,
    z = 2,
};

/// Device orientation
pub const Orientation = enum(u3) {
    face_up = 0,
    face_down = 1,
    portrait = 2,
    portrait_inverted = 3,
    landscape_left = 4,
    landscape_right = 5,
    unknown = 7,
};

/// Motion event payload for board.Event
/// This is the type stored in board's Event union
pub const MotionEventPayload = struct {
    /// Source component ID
    source: []const u8,
    /// Event timestamp
    timestamp_ms: u64,
    /// Motion action data
    action: Action,

    pub const Action = union(enum) {
        shake: struct {
            magnitude: f32,
            duration_ms: u32,
        },
        tap: struct {
            axis: Axis,
            count: u8,
            positive: bool,
        },
        tilt: struct {
            roll: f32,
            pitch: f32,
        },
        flip: struct {
            from: Orientation,
            to: Orientation,
        },
        freefall: struct {
            duration_ms: u32,
        },
    };
};

// ============================================================================
// Motion HAL Component
// ============================================================================

/// Motion detection HAL component
///
/// spec must define:
/// - `Imu`: IMU type with readAccel() and optionally readGyro()
/// - `meta`: .{ .id = "motion.xxx" }
///
/// Optional:
/// - `thresholds`: Detection thresholds (default = default)
pub fn from(comptime spec: type) type {
    // Import motion library types
    const motion_lib = @import("motion");
    const motion_types = motion_lib.types;

    comptime {
        // Verify Imu type has readAccel method
        if (!@hasDecl(spec.Imu, "readAccel")) {
            @compileError("spec.Imu must have readAccel() method");
        }
        // Verify meta.id
        _ = @as([]const u8, spec.meta.id);
    }

    const ImuType = spec.Imu;
    const DetectorType = motion_lib.Detector(ImuType);
    const has_gyro = DetectorType.has_gyroscope;
    const SampleType = DetectorType.SampleType;
    const ActionType = DetectorType.ActionType;

    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _MotionMarker;

        /// Exported types for hal.Board to access
        pub const ImuDriverType = ImuType;

        /// Whether gyroscope is available
        pub const has_gyroscope = has_gyro;

        // ================================================================
        // Metadata
        // ================================================================

        pub const meta = spec.meta;

        /// Event type for internal queue
        pub const Event = MotionEventPayload;

        /// Event callback type for direct push to Board queue
        pub const EventCallback = *const fn (?*anyopaque, Event) void;

        // ================================================================
        // Fields
        // ================================================================

        /// IMU sensor instance
        imu: *ImuType,

        /// Motion detector instance
        detector: DetectorType,

        /// Time function
        time_fn: *const fn () u64,

        /// Event queue (for poll mode)
        event_queue: [8]Event = undefined,
        event_count: u8 = 0,
        event_index: u8 = 0,

        /// Running flag for task mode
        running: bool = false,

        /// Event callback for direct push (set by Board)
        event_callback: ?EventCallback = null,
        event_ctx: ?*anyopaque = null,

        // ================================================================
        // Initialization
        // ================================================================

        /// Initialize motion detection with IMU and time source
        pub fn init(imu: *ImuType, time_fn: *const fn () u64) Self {
            const thresholds = if (@hasDecl(spec, "thresholds"))
                spec.thresholds
            else
                motion_types.Thresholds.default;

            return .{
                .imu = imu,
                .detector = DetectorType.init(thresholds),
                .time_fn = time_fn,
            };
        }

        /// Initialize with custom thresholds
        pub fn initWithThresholds(imu: *ImuType, time_fn: *const fn () u64, thresholds: motion_types.Thresholds) Self {
            return .{
                .imu = imu,
                .detector = DetectorType.init(thresholds),
                .time_fn = time_fn,
            };
        }

        /// Set event callback for direct push to Board queue
        pub fn setCallback(self: *Self, callback: EventCallback, ctx: ?*anyopaque) void {
            self.event_callback = callback;
            self.event_ctx = ctx;
        }

        // ================================================================
        // Polling
        // ================================================================

        /// Poll IMU and run motion detection
        /// Events are queued internally, retrieve with nextEvent()
        pub fn poll(self: *Self) void {
            const timestamp = self.time_fn();

            // Read accelerometer data
            const accel = self.imu.readAccel() catch return;

            // Create sample
            const sample = if (has_gyro) blk: {
                const gyro = self.imu.readGyro() catch return;
                break :blk SampleType{
                    .accel = motion_types.accelFrom(accel),
                    .gyro = motion_types.gyroFrom(gyro),
                    .timestamp_ms = timestamp,
                };
            } else SampleType{
                .accel = motion_types.accelFrom(accel),
                .gyro = {},
                .timestamp_ms = timestamp,
            };

            // Run detector and queue any events
            // Call update() once, then drain remaining events with nextEvent()
            if (self.detector.update(sample)) |action| {
                self.queueEvent(self.convertAction(action, timestamp));
                while (self.detector.nextEvent()) |next_action| {
                    self.queueEvent(self.convertAction(next_action, timestamp));
                }
            }
        }

        /// Get next event from queue
        pub fn nextEvent(self: *Self) ?Event {
            if (self.event_index < self.event_count) {
                const event = self.event_queue[self.event_index];
                self.event_index += 1;
                return event;
            }
            // Reset queue when exhausted
            self.event_count = 0;
            self.event_index = 0;
            return null;
        }

        // ================================================================
        // Task Mode
        // ================================================================

        /// Stop the run loop
        pub fn stop(self: *Self) void {
            self.running = false;
        }

        /// Run in background task mode
        /// Continuously reads IMU, detects motion, and queues events
        pub fn run(self: *Self, sleep_fn: *const fn (u32) void, poll_interval_ms: u32) void {
            self.running = true;

            while (self.running) {
                self.poll();
                sleep_fn(poll_interval_ms);
            }
        }

        /// Run with default 20ms poll interval
        pub fn runDefault(self: *Self, sleep_fn: *const fn (u32) void) void {
            self.run(sleep_fn, 20);
        }

        // ================================================================
        // Threshold Configuration
        // ================================================================

        /// Update detection thresholds
        pub fn setThresholds(self: *Self, thresholds: motion_types.Thresholds) void {
            self.detector.thresholds = thresholds;
        }

        /// Get current thresholds
        pub fn getThresholds(self: *const Self) motion_types.Thresholds {
            return self.detector.thresholds;
        }

        /// Reset detector state (clear all detection state)
        pub fn reset(self: *Self) void {
            self.detector = DetectorType.init(self.detector.thresholds);
            self.event_count = 0;
            self.event_index = 0;
        }

        // ================================================================
        // Internal
        // ================================================================

        /// Convert motion.Action to HAL Event
        fn convertAction(self: *const Self, action: ActionType, timestamp: u64) Event {
            _ = self;
            const converted: Event.Action = switch (action) {
                .shake => |s| .{ .shake = .{
                    .magnitude = s.magnitude,
                    .duration_ms = s.duration_ms,
                } },
                .tap => |t| .{ .tap = .{
                    .axis = @enumFromInt(@intFromEnum(t.axis)),
                    .count = t.count,
                    .positive = t.positive,
                } },
                .tilt => |t| .{ .tilt = .{
                    .roll = t.roll,
                    .pitch = t.pitch,
                } },
                .flip => |f| if (has_gyro) .{ .flip = .{
                    .from = @enumFromInt(@intFromEnum(f.from)),
                    .to = @enumFromInt(@intFromEnum(f.to)),
                } } else .{ .shake = .{ .magnitude = 0, .duration_ms = 0 } }, // Dummy, shouldn't happen
                .freefall => |f| if (has_gyro) .{ .freefall = .{
                    .duration_ms = f.duration_ms,
                } } else .{ .shake = .{ .magnitude = 0, .duration_ms = 0 } }, // Dummy, shouldn't happen
            };

            return Event{
                .source = meta.id,
                .timestamp_ms = timestamp,
                .action = converted,
            };
        }

        fn queueEvent(self: *Self, event: Event) void {
            // If callback is set, push directly to Board queue
            if (self.event_callback) |callback| {
                callback(self.event_ctx, event);
                return;
            }
            // Fallback to internal queue
            if (self.event_count < self.event_queue.len) {
                self.event_queue[self.event_count] = event;
                self.event_count += 1;
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Motion HAL marker" {
    const MockImu = struct {
        pub fn readAccel(_: *@This()) !struct { x: f32, y: f32, z: f32 } {
            return .{ .x = 0, .y = 0, .z = 1.0 };
        }
    };

    const spec = struct {
        pub const Imu = MockImu;
        pub const meta = .{ .id = "motion.test" };
    };

    const MotionType = from(spec);
    try std.testing.expect(is(MotionType));
    try std.testing.expect(!MotionType.has_gyroscope);
}
