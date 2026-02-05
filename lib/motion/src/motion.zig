//! Motion Detection Library
//!
//! Cross-platform motion detection using accelerometer and optionally gyroscope data.
//! Detects various motion events: shake, tap, tilt, flip, freefall.
//!
//! ## Architecture
//!
//! The library uses comptime duck typing to detect sensor capabilities:
//! - 3-axis accelerometer (readAccel only): shake, tap, tilt
//! - 6-axis IMU (readAccel + readGyro): adds flip, freefall
//!
//! ## Usage
//!
//! ```zig
//! const motion = @import("motion");
//!
//! // Create detector - capabilities detected from Sensor type
//! const MyDetector = motion.Detector(Board.Imu);
//! var detector = MyDetector.initDefault();
//!
//! // Feed sensor data and get events
//! const sample = MyDetector.SampleType{
//!     .accel = motion.accelFrom(board.imu.readAccel()),
//!     .gyro = motion.gyroFrom(board.imu.readGyro()),
//!     .timestamp_ms = now,
//! };
//!
//! while (detector.update(sample)) |event| {
//!     switch (event) {
//!         .shake => |s| handleShake(s.magnitude),
//!         .tap => |t| handleTap(t.axis, t.count),
//!         .tilt => |t| handleTilt(t.roll, t.pitch),
//!         .flip => |f| handleFlip(f.from, f.to),
//!         .freefall => |f| handleFreefall(f.duration_ms),
//!     }
//! }
//! ```

// Re-export types
pub const types = @import("types.zig");
pub const Axis = types.Axis;
pub const Orientation = types.Orientation;
pub const ShakeData = types.ShakeData;
pub const TapData = types.TapData;
pub const TiltData = types.TiltData;
pub const FlipData = types.FlipData;
pub const FreefallData = types.FreefallData;
pub const MotionAction = types.MotionAction;
pub const MotionEvent = types.MotionEvent;
pub const AccelData = types.AccelData;
pub const GyroData = types.GyroData;
pub const SensorSample = types.SensorSample;
pub const Thresholds = types.Thresholds;

// HAL integration helpers
pub const accelFrom = types.accelFrom;
pub const gyroFrom = types.gyroFrom;

// Re-export detector
pub const detector = @import("detector.zig");
pub const Detector = detector.Detector;

test {
    _ = types;
    _ = detector;
}
