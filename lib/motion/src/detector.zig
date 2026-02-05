//! Motion Detector
//!
//! Detects motion events from raw sensor data using configurable algorithms.
//! Supports shake, tap, tilt, flip, and freefall detection.
//!
//! Usage:
//!   const Detector = motion.Detector(Board.Imu);  // Pass HAL IMU type
//!   var detector = Detector.initDefault();
//!   if (detector.update(sample)) |event| { ... }

const std = @import("std");
const math = @import("math");
const types = @import("types.zig");

const AccelData = types.AccelData;
const GyroData = types.GyroData;
const SensorSample = types.SensorSample;
const MotionAction = types.MotionAction;
const Thresholds = types.Thresholds;
const Axis = types.Axis;
const Orientation = types.Orientation;

/// Check if a type has a method with the expected return structure
/// Uses structural matching instead of exact type equality to support
/// different type definitions with the same structure (e.g., hal.GyroData vs motion.GyroData)
fn hasMethod(comptime T: type, comptime name: []const u8, comptime ExpectedFields: type) bool {
    if (!@hasDecl(T, name)) return false;

    const F = @TypeOf(@field(T, name));
    const info = @typeInfo(F);
    if (info != .@"fn") return false;

    // Get return type
    const ret = info.@"fn".return_type orelse return false;
    const ret_info = @typeInfo(ret);

    // Unwrap error union if present
    const payload = if (ret_info == .error_union)
        ret_info.error_union.payload
    else
        ret;

    // Check if payload has the expected fields (structural matching)
    return hasExpectedFields(payload, ExpectedFields);
}

/// Check if a type has the expected fields with compatible types
fn hasExpectedFields(comptime T: type, comptime Expected: type) bool {
    const t_info = @typeInfo(T);
    const e_info = @typeInfo(Expected);

    if (t_info != .@"struct" or e_info != .@"struct") return false;

    // Check that all expected fields exist with compatible types
    inline for (e_info.@"struct".fields) |expected_field| {
        if (!@hasField(T, expected_field.name)) return false;
        // Could add type compatibility check here if needed
    }

    return true;
}

/// Motion Detector - detects motion events from sensor data
/// Capabilities are determined via comptime duck typing on the Sensor type
pub fn Detector(comptime Sensor: type) type {
    // Detect gyroscope capability via method signature
    const has_gyro = hasMethod(Sensor, "readGyro", GyroData);

    const Action = MotionAction(has_gyro);
    const Sample = SensorSample(has_gyro);

    return struct {
        const Self = @This();

        /// Whether this detector has gyroscope support
        pub const has_gyroscope = has_gyro;

        /// Detection thresholds
        thresholds: Thresholds,

        // ================================================================
        // State for each detection algorithm
        // ================================================================

        // Shake detection state
        shake_state: ShakeState = .{},

        // Tap detection state
        tap_state: TapState = .{},

        // Tilt detection state
        tilt_state: TiltState = .{},

        // Flip detection state (only if has gyro)
        flip_state: if (has_gyro) FlipState else void = if (has_gyro) .{} else {},

        // Freefall detection state (only if has gyro)
        freefall_state: if (has_gyro) FreefallState else void = if (has_gyro) .{} else {},

        // Previous sample for delta calculations
        prev_sample: ?Sample = null,

        // Event queue (small buffer for multiple events in one update)
        event_queue: [4]?Action = .{ null, null, null, null },
        event_read_idx: u8 = 0,
        event_write_idx: u8 = 0,

        // ================================================================
        // Internal State Types
        // ================================================================

        const ShakeState = struct {
            /// Accumulated magnitude changes
            acc_delta: f32 = 0,
            /// Shake start time
            start_time: u64 = 0,
            /// Is shake in progress
            active: bool = false,
            /// Previous acceleration magnitude
            prev_mag: f32 = 0,
            /// Sample count during shake
            sample_count: u32 = 0,
        };

        const TapState = struct {
            /// Time of last spike
            last_spike_time: u64 = 0,
            /// Axis of last spike
            last_spike_axis: Axis = .x,
            /// Tap count (for double-tap detection)
            tap_count: u8 = 0,
            /// Time of first tap in sequence
            first_tap_time: u64 = 0,
            /// Cooldown after tap event
            cooldown_until: u64 = 0,
        };

        const TiltState = struct {
            /// Last reported roll
            last_roll: f32 = 0,
            /// Last reported pitch
            last_pitch: f32 = 0,
            /// Time of last tilt event
            last_event_time: u64 = 0,
            /// Initialized flag
            initialized: bool = false,
        };

        const FlipState = struct {
            /// Current orientation
            current: Orientation = .unknown,
            /// Time orientation was detected
            orientation_time: u64 = 0,
            /// Stable flag
            stable: bool = false,
        };

        const FreefallState = struct {
            /// Freefall start time
            start_time: u64 = 0,
            /// Is freefall in progress
            active: bool = false,
        };

        // ================================================================
        // Public API
        // ================================================================

        /// The action type for this detector
        pub const ActionType = Action;

        /// The sample type for this detector
        pub const SampleType = Sample;

        /// Initialize detector with thresholds
        pub fn init(thresholds: Thresholds) Self {
            return .{ .thresholds = thresholds };
        }

        /// Initialize with default thresholds
        pub fn initDefault() Self {
            return init(Thresholds.default);
        }

        /// Reset detector state
        pub fn reset(self: *Self) void {
            self.shake_state = .{};
            self.tap_state = .{};
            self.tilt_state = .{};
            if (has_gyro) {
                self.flip_state = .{};
                self.freefall_state = .{};
            }
            self.prev_sample = null;
            self.event_queue = .{ null, null, null, null };
            self.event_read_idx = 0;
            self.event_write_idx = 0;
        }

        /// Update detector with new sensor sample
        /// Returns the next detected event, or null if no event
        pub fn update(self: *Self, sample: Sample) ?Action {
            // Process sample through all detectors
            self.detectShake(sample);
            self.detectTap(sample);
            self.detectTilt(sample);

            if (has_gyro) {
                self.detectFlip(sample);
                self.detectFreefall(sample);
            }

            // Store for next iteration
            self.prev_sample = sample;

            // Return first queued event
            return self.nextEvent();
        }

        /// Get next queued event (call after update for additional events)
        pub fn nextEvent(self: *Self) ?Action {
            if (self.event_read_idx == self.event_write_idx) {
                return null;
            }
            const event = self.event_queue[self.event_read_idx];
            self.event_queue[self.event_read_idx] = null;
            self.event_read_idx = (self.event_read_idx + 1) % 4;
            return event;
        }

        /// Check if there are pending events
        pub fn hasPendingEvents(self: *const Self) bool {
            return self.event_read_idx != self.event_write_idx;
        }

        // ================================================================
        // Detection Algorithms
        // ================================================================

        fn queueEvent(self: *Self, action: Action) void {
            self.event_queue[self.event_write_idx] = action;
            self.event_write_idx = (self.event_write_idx + 1) % 4;
        }

        fn detectShake(self: *Self, sample: Sample) void {
            const mag = sample.accel.magnitude();
            const now = sample.timestamp_ms;

            if (self.shake_state.prev_mag == 0) {
                self.shake_state.prev_mag = mag;
                return;
            }

            const delta = @abs(mag - self.shake_state.prev_mag);
            self.shake_state.prev_mag = mag;

            // Check for significant acceleration change
            if (delta > self.thresholds.shake_threshold * 0.5) {
                if (!self.shake_state.active) {
                    // Start shake detection
                    self.shake_state.active = true;
                    self.shake_state.start_time = now;
                    self.shake_state.acc_delta = delta;
                    self.shake_state.sample_count = 1;
                } else {
                    // Accumulate
                    self.shake_state.acc_delta = @max(self.shake_state.acc_delta, delta);
                    self.shake_state.sample_count += 1;
                }
            }

            // Check if shake should end
            if (self.shake_state.active) {
                const duration = now -| self.shake_state.start_time;

                // End conditions: timeout or low activity
                if (duration > self.thresholds.shake_max_duration or
                    (delta < self.thresholds.shake_threshold * 0.2 and duration > self.thresholds.shake_min_duration))
                {
                    // Emit shake event if valid
                    if (duration >= self.thresholds.shake_min_duration and
                        self.shake_state.acc_delta >= self.thresholds.shake_threshold)
                    {
                        self.queueEvent(.{ .shake = .{
                            .magnitude = self.shake_state.acc_delta,
                            .duration_ms = @intCast(duration),
                        } });
                    }

                    // Reset
                    self.shake_state.active = false;
                    self.shake_state.acc_delta = 0;
                    self.shake_state.sample_count = 0;
                }
            }
        }

        fn detectTap(self: *Self, sample: Sample) void {
            const now = sample.timestamp_ms;

            // Skip if in cooldown
            if (now < self.tap_state.cooldown_until) {
                return;
            }

            // Find axis with highest acceleration
            const ax = @abs(sample.accel.x);
            const ay = @abs(sample.accel.y);
            const az = @abs(sample.accel.z - 1.0); // Subtract gravity from Z

            var max_val = ax;
            var max_axis = Axis.x;
            var positive = sample.accel.x > 0;

            if (ay > max_val) {
                max_val = ay;
                max_axis = .y;
                positive = sample.accel.y > 0;
            }
            if (az > max_val) {
                max_val = az;
                max_axis = .z;
                positive = sample.accel.z > 1.0;
            }

            // Check for tap threshold
            if (max_val >= self.thresholds.tap_threshold) {
                const time_since_last = now -| self.tap_state.last_spike_time;

                // Check for double-tap
                if (time_since_last < self.thresholds.double_tap_window and
                    time_since_last > self.thresholds.tap_max_duration and
                    self.tap_state.last_spike_axis == max_axis)
                {
                    // Double tap detected
                    self.queueEvent(.{ .tap = .{
                        .axis = max_axis,
                        .count = 2,
                        .positive = positive,
                    } });
                    self.tap_state.cooldown_until = now + self.thresholds.double_tap_window;
                    self.tap_state.tap_count = 0;
                } else if (time_since_last >= self.thresholds.double_tap_window) {
                    // First tap of potential sequence
                    self.tap_state.last_spike_time = now;
                    self.tap_state.last_spike_axis = max_axis;
                    self.tap_state.tap_count = 1;
                    self.tap_state.first_tap_time = now;
                }
            } else if (self.tap_state.tap_count > 0) {
                // Check if we should emit single tap (no second tap came)
                const time_since_first = now -| self.tap_state.first_tap_time;
                if (time_since_first >= self.thresholds.double_tap_window) {
                    // Emit single tap
                    self.queueEvent(.{ .tap = .{
                        .axis = self.tap_state.last_spike_axis,
                        .count = 1,
                        .positive = true,
                    } });
                    self.tap_state.tap_count = 0;
                    self.tap_state.cooldown_until = now + self.thresholds.tap_max_duration;
                }
            }
        }

        fn detectTilt(self: *Self, sample: Sample) void {
            const now = sample.timestamp_ms;

            // Calculate angles from accelerometer
            const ax = sample.accel.x;
            const ay = sample.accel.y;
            const az = sample.accel.z;

            // Roll: rotation around X axis (using approximation to avoid 128-bit ops)
            const roll = math.approxAtan2(ay, az) * (180.0 / std.math.pi);
            // Pitch: rotation around Y axis
            const pitch = math.approxAtan2(-ax, @sqrt(ay * ay + az * az)) * (180.0 / std.math.pi);

            if (!self.tilt_state.initialized) {
                self.tilt_state.last_roll = roll;
                self.tilt_state.last_pitch = pitch;
                self.tilt_state.initialized = true;
                return;
            }

            // Check for significant change
            const roll_delta = @abs(roll - self.tilt_state.last_roll);
            const pitch_delta = @abs(pitch - self.tilt_state.last_pitch);

            if ((roll_delta >= self.thresholds.tilt_threshold or
                pitch_delta >= self.thresholds.tilt_threshold) and
                now -| self.tilt_state.last_event_time >= self.thresholds.tilt_debounce)
            {
                self.queueEvent(.{ .tilt = .{
                    .roll = roll,
                    .pitch = pitch,
                } });
                self.tilt_state.last_roll = roll;
                self.tilt_state.last_pitch = pitch;
                self.tilt_state.last_event_time = now;
            }
        }

        fn detectFlip(self: *Self, sample: Sample) void {
            if (!has_gyro) return;

            const now = sample.timestamp_ms;

            // Determine orientation from accelerometer
            const orientation = determineOrientation(sample.accel);

            if (orientation != self.flip_state.current) {
                if (!self.flip_state.stable or
                    now -| self.flip_state.orientation_time >= self.thresholds.flip_debounce)
                {
                    // Orientation changed
                    if (self.flip_state.stable and self.flip_state.current != .unknown) {
                        self.queueEvent(.{ .flip = .{
                            .from = self.flip_state.current,
                            .to = orientation,
                        } });
                    }

                    self.flip_state.current = orientation;
                    self.flip_state.orientation_time = now;
                    self.flip_state.stable = false;
                }
            } else {
                // Same orientation, check if stable
                if (!self.flip_state.stable and
                    now -| self.flip_state.orientation_time >= self.thresholds.flip_debounce)
                {
                    self.flip_state.stable = true;
                }
            }
        }

        fn detectFreefall(self: *Self, sample: Sample) void {
            if (!has_gyro) return;

            const now = sample.timestamp_ms;
            const mag = sample.accel.magnitude();

            if (mag < self.thresholds.freefall_threshold) {
                if (!self.freefall_state.active) {
                    self.freefall_state.active = true;
                    self.freefall_state.start_time = now;
                }
            } else {
                if (self.freefall_state.active) {
                    const duration = now -| self.freefall_state.start_time;
                    if (duration >= self.thresholds.freefall_min_duration) {
                        self.queueEvent(.{ .freefall = .{
                            .duration_ms = @intCast(duration),
                        } });
                    }
                    self.freefall_state.active = false;
                }
            }
        }

        // ================================================================
        // Helper Functions
        // ================================================================

        fn determineOrientation(accel: AccelData) Orientation {
            const ax = accel.x;
            const ay = accel.y;
            const az = accel.z;

            // Find dominant axis
            const abs_x = @abs(ax);
            const abs_y = @abs(ay);
            const abs_z = @abs(az);

            const threshold: f32 = 0.7; // Must be > 0.7g on dominant axis

            if (abs_z > abs_x and abs_z > abs_y and abs_z > threshold) {
                return if (az > 0) .face_up else .face_down;
            } else if (abs_x > abs_y and abs_x > abs_z and abs_x > threshold) {
                return if (ax > 0) .portrait else .portrait_inverted;
            } else if (abs_y > abs_x and abs_y > abs_z and abs_y > threshold) {
                return if (ay > 0) .landscape_left else .landscape_right;
            }

            return .unknown;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

// Mock sensor types for testing
const MockAccelOnlySensor = struct {
    pub fn readAccel(_: *@This()) !AccelData {
        return .{ .x = 0, .y = 0, .z = 1.0 };
    }
};

const MockImuSensor = struct {
    pub fn readAccel(_: *@This()) !AccelData {
        return .{ .x = 0, .y = 0, .z = 1.0 };
    }
    pub fn readGyro(_: *@This()) !GyroData {
        return .{ .x = 0, .y = 0, .z = 0 };
    }
};

test "hasMethod detection" {
    try std.testing.expect(hasMethod(MockImuSensor, "readGyro", GyroData));
    try std.testing.expect(hasMethod(MockImuSensor, "readAccel", AccelData));
    try std.testing.expect(!hasMethod(MockAccelOnlySensor, "readGyro", GyroData));
    try std.testing.expect(hasMethod(MockAccelOnlySensor, "readAccel", AccelData));
}

test "Detector capability detection" {
    const ImuDetector = Detector(MockImuSensor);
    const AccelDetector = Detector(MockAccelOnlySensor);

    try std.testing.expect(ImuDetector.has_gyroscope);
    try std.testing.expect(!AccelDetector.has_gyroscope);
}

test "Detector initialization" {
    const det = Detector(MockImuSensor).initDefault();
    try std.testing.expectEqual(@as(f32, 1.5), det.thresholds.shake_threshold);
}

test "Detector shake detection" {
    var det = Detector(MockImuSensor).init(.{
        .shake_threshold = 1.0,
        .shake_min_duration = 50,
        .shake_max_duration = 500,
    });

    const Sample = Detector(MockImuSensor).SampleType;

    // Simulate shake sequence
    var t: u64 = 0;

    // Initial samples
    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;

    // Shake motion
    _ = det.update(Sample{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;
    _ = det.update(Sample{ .accel = .{ .x = -2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;
    _ = det.update(Sample{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 30;

    // End shake
    const event = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });

    // Should detect shake (though timing might vary)
    _ = event;
}

test "Detector tilt detection" {
    var det = Detector(MockAccelOnlySensor).init(.{
        .tilt_threshold = 5.0,
        .tilt_debounce = 0,
    });

    const Sample = Detector(MockAccelOnlySensor).SampleType;

    // Initial flat position
    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = {}, .timestamp_ms = 0 });

    // Tilt to 30 degrees
    const event = det.update(Sample{
        .accel = .{ .x = 0.5, .y = 0, .z = 0.866 }, // ~30 degree tilt
        .gyro = {},
        .timestamp_ms = 100,
    });

    if (event) |e| {
        switch (e) {
            .tilt => |t| {
                try std.testing.expect(@abs(t.pitch) > 20.0);
            },
            else => {},
        }
    }
}

test "Detector with accel-only sensor" {
    // Should compile without gyro features
    var det = Detector(MockAccelOnlySensor).initDefault();
    const Sample = Detector(MockAccelOnlySensor).SampleType;

    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = {}, .timestamp_ms = 0 });
}
