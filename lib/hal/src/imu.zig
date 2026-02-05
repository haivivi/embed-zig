//! IMU (Inertial Measurement Unit) Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for inertial sensors:
//! - Accelerometer (3-axis)
//! - Gyroscope (3-axis)
//! - Magnetometer (3-axis, optional)
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   const accel = board.imu.readAccel()   │
//! │   const gyro = board.imu.readGyro()     │
//! ├─────────────────────────────────────────┤
//! │ Imu(spec)  ← HAL wrapper               │
//! │   - Comptime capability detection       │
//! │   - Only exposes methods Driver has     │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← hardware impl  │
//! │   - readAccel() -> AccelData           │
//! │   - readGyro()  -> GyroData (optional) │
//! │   - readMag()   -> MagData  (optional) │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Capability Detection
//!
//! Capabilities are detected via comptime duck typing:
//! - Driver has `readAccel()` → accelerometer available
//! - Driver has `readGyro()` → gyroscope available
//! - Driver has `readMag()` → magnetometer available
//!
//! ## Usage
//!
//! ```zig
//! const imu_spec = struct {
//!     pub const Driver = Qmi8658Driver;
//!     pub const meta = .{ .id = "imu.qmi8658" };
//! };
//!
//! const MyImu = imu.from(imu_spec);
//! var sensor = MyImu.init(&driver);
//!
//! // Always available (accelerometer required)
//! const accel = try sensor.readAccel();
//!
//! // Only available if Driver has readGyro()
//! if (MyImu.has_gyro) {
//!     const gyro = try sensor.readGyro();
//! }
//! ```

const std = @import("std");

// ============================================================================
// Data Types
// ============================================================================

/// Accelerometer data (in g, where 1g ≈ 9.81 m/s²)
pub const AccelData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

/// Gyroscope data (in degrees per second)
pub const GyroData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

/// Magnetometer data (in microtesla)
pub const MagData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

const _ImuMarker = struct {};

/// Check if a type is an IMU peripheral
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _ImuMarker;
}

// ============================================================================
// IMU HAL Wrapper
// ============================================================================

/// Create IMU HAL type from spec
///
/// Capabilities are detected by checking what methods the Driver implements:
/// - `readAccel()` → accelerometer (required)
/// - `readGyro()` → gyroscope (optional)
/// - `readMag()` → magnetometer (optional)
///
/// The Driver can also implement a combined method:
/// - `readScaled()` → returns struct with acc_x/y/z and optionally gyr_x/y/z
///
/// spec must define:
/// - `Driver`: struct with at least readAccel() or readScaled()
/// - `meta`: .{ .id = "component_id" }
///
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    // Detect capabilities by checking which methods exist
    const has_read_accel = @hasDecl(BaseDriver, "readAccel");
    const has_read_gyro = @hasDecl(BaseDriver, "readGyro");
    const has_read_mag = @hasDecl(BaseDriver, "readMag");
    const has_read_scaled = @hasDecl(BaseDriver, "readScaled");

    // Verify at least one accel method exists
    comptime {
        if (!has_read_accel and !has_read_scaled) {
            @compileError("IMU Driver must implement readAccel() or readScaled()");
        }
        _ = @as([]const u8, spec.meta.id);
    }

    // Check readScaled return type for gyro fields
    const scaled_has_gyro = comptime blk: {
        if (!has_read_scaled) break :blk false;
        const ReturnType = @typeInfo(@TypeOf(BaseDriver.readScaled)).@"fn".return_type.?;
        const Payload = switch (@typeInfo(ReturnType)) {
            .error_union => |eu| eu.payload,
            else => ReturnType,
        };
        break :blk @hasField(Payload, "gyr_x") or @hasField(Payload, "gyro_x");
    };

    const Driver = spec.Driver;

    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        pub const _hal_marker = _ImuMarker;
        pub const DriverType = Driver;

        // ================================================================
        // Capabilities (comptime)
        // ================================================================

        /// Driver has accelerometer
        pub const has_accel = true;
        /// Driver has gyroscope
        pub const has_gyro = has_read_gyro or scaled_has_gyro;
        /// Driver has magnetometer
        pub const has_mag = has_read_mag;

        // ================================================================
        // Metadata
        // ================================================================

        pub const meta = spec.meta;

        // ================================================================
        // Fields
        // ================================================================

        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ================================================================
        // Accelerometer (always available)
        // ================================================================

        /// Read accelerometer data in g
        pub fn readAccel(self: *Self) !AccelData {
            if (has_read_accel) {
                const data = try self.driver.readAccel();
                return normalizeAccel(data);
            } else if (has_read_scaled) {
                const data = try self.driver.readScaled();
                return normalizeAccelFromScaled(data);
            } else {
                unreachable;
            }
        }

        fn normalizeAccel(data: anytype) AccelData {
            // Handle different field naming conventions
            const x = if (@hasField(@TypeOf(data), "x")) data.x else if (@hasField(@TypeOf(data), "acc_x")) data.acc_x else 0;
            const y = if (@hasField(@TypeOf(data), "y")) data.y else if (@hasField(@TypeOf(data), "acc_y")) data.acc_y else 0;
            const z = if (@hasField(@TypeOf(data), "z")) data.z else if (@hasField(@TypeOf(data), "acc_z")) data.acc_z else 0;
            return .{ .x = x, .y = y, .z = z };
        }

        fn normalizeAccelFromScaled(data: anytype) AccelData {
            const x = if (@hasField(@TypeOf(data), "acc_x")) data.acc_x else 0;
            const y = if (@hasField(@TypeOf(data), "acc_y")) data.acc_y else 0;
            const z = if (@hasField(@TypeOf(data), "acc_z")) data.acc_z else 0;
            return .{ .x = x, .y = y, .z = z };
        }

        // ================================================================
        // Gyroscope (check has_gyro before calling)
        // ================================================================

        /// Read gyroscope data in degrees per second
        /// Check has_gyro before calling; returns error.NotSupported if unavailable
        pub fn readGyro(self: *Self) !GyroData {
            if (!has_gyro) return error.NotSupported;

            if (has_read_gyro) {
                const data = try self.driver.readGyro();
                return normalizeGyro(data);
            } else if (has_read_scaled and scaled_has_gyro) {
                const data = try self.driver.readScaled();
                return normalizeGyroFromScaled(data);
            } else {
                return error.NotSupported;
            }
        }

        fn normalizeGyro(data: anytype) GyroData {
            const x = if (@hasField(@TypeOf(data), "x")) data.x else if (@hasField(@TypeOf(data), "gyr_x")) data.gyr_x else 0;
            const y = if (@hasField(@TypeOf(data), "y")) data.y else if (@hasField(@TypeOf(data), "gyr_y")) data.gyr_y else 0;
            const z = if (@hasField(@TypeOf(data), "z")) data.z else if (@hasField(@TypeOf(data), "gyr_z")) data.gyr_z else 0;
            return .{ .x = x, .y = y, .z = z };
        }

        fn normalizeGyroFromScaled(data: anytype) GyroData {
            const x = if (@hasField(@TypeOf(data), "gyr_x")) data.gyr_x else if (@hasField(@TypeOf(data), "gyro_x")) data.gyro_x else 0;
            const y = if (@hasField(@TypeOf(data), "gyr_y")) data.gyr_y else if (@hasField(@TypeOf(data), "gyro_y")) data.gyro_y else 0;
            const z = if (@hasField(@TypeOf(data), "gyr_z")) data.gyr_z else if (@hasField(@TypeOf(data), "gyro_z")) data.gyro_z else 0;
            return .{ .x = x, .y = y, .z = z };
        }

        // ================================================================
        // Magnetometer (check has_mag before calling)
        // ================================================================

        /// Read magnetometer data in microtesla
        /// Check has_mag before calling; returns error.NotSupported if unavailable
        pub fn readMag(self: *Self) !MagData {
            if (!has_mag) return error.NotSupported;

            const data = try self.driver.readMag();
            return normalizeMag(data);
        }

        fn normalizeMag(data: anytype) MagData {
            const x = if (@hasField(@TypeOf(data), "x")) data.x else if (@hasField(@TypeOf(data), "mag_x")) data.mag_x else 0;
            const y = if (@hasField(@TypeOf(data), "y")) data.y else if (@hasField(@TypeOf(data), "mag_y")) data.mag_y else 0;
            const z = if (@hasField(@TypeOf(data), "z")) data.z else if (@hasField(@TypeOf(data), "mag_z")) data.mag_z else 0;
            return .{ .x = x, .y = y, .z = z };
        }

        // ================================================================
        // Direct driver access
        // ================================================================

        /// Check if new data is available (if driver supports it)
        pub fn isDataReady(self: *Self) !bool {
            if (@hasDecl(BaseDriver, "isDataReady")) {
                return self.driver.isDataReady();
            }
            return true; // Assume always ready if not supported
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "IMU with 6-axis driver (readScaled)" {
    // Mock driver that implements readScaled (like QMI8658)
    const Mock6AxisDriver = struct {
        pub fn readScaled(_: *@This()) !struct { acc_x: f32, acc_y: f32, acc_z: f32, gyr_x: f32, gyr_y: f32, gyr_z: f32 } {
            return .{
                .acc_x = 0.1,
                .acc_y = 0.2,
                .acc_z = 1.0,
                .gyr_x = 10.0,
                .gyr_y = 20.0,
                .gyr_z = 30.0,
            };
        }
    };

    const TestImu = from(struct {
        pub const Driver = Mock6AxisDriver;
        pub const meta = .{ .id = "imu.test6" };
    });

    // Verify capabilities
    try std.testing.expect(TestImu.has_accel);
    try std.testing.expect(TestImu.has_gyro);
    try std.testing.expect(!TestImu.has_mag);

    var driver = Mock6AxisDriver{};
    var imu_hal = TestImu.init(&driver);

    // Test accel
    const accel = try imu_hal.readAccel();
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), accel.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), accel.z, 0.01);

    // Test gyro (should be available)
    try std.testing.expect(TestImu.has_gyro);
    const gyro = try imu_hal.readGyro();
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), gyro.x, 0.01);
}

test "IMU with 3-axis driver (readAccel only)" {
    // Mock driver that only has accelerometer
    const Mock3AxisDriver = struct {
        pub fn readAccel(_: *@This()) !AccelData {
            return .{ .x = 0.0, .y = 0.0, .z = 1.0 };
        }
    };

    const TestImu = from(struct {
        pub const Driver = Mock3AxisDriver;
        pub const meta = .{ .id = "imu.test3" };
    });

    // Verify capabilities
    try std.testing.expect(TestImu.has_accel);
    try std.testing.expect(!TestImu.has_gyro);
    try std.testing.expect(!TestImu.has_mag);

    var driver = Mock3AxisDriver{};
    var imu_hal = TestImu.init(&driver);

    const accel = try imu_hal.readAccel();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), accel.z, 0.01);

    // readGyro should return NotSupported
    try std.testing.expect(!TestImu.has_gyro);
    try std.testing.expectError(error.NotSupported, imu_hal.readGyro());
}

test "IMU is() function" {
    const MockDriver = struct {
        pub fn readAccel(_: *@This()) !AccelData {
            return .{};
        }
    };

    const TestImu = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "test" };
    });

    try std.testing.expect(is(TestImu));
    try std.testing.expect(!is(u32));
}
