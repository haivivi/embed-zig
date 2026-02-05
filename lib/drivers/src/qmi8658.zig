//! QMI8658 6-Axis IMU Driver
//!
//! Platform-independent driver for QST QMI8658 6-axis inertial measurement unit.
//! Integrates 3-axis accelerometer and 3-axis gyroscope.
//!
//! Features:
//! - Accelerometer: ±2g, ±4g, ±8g, ±16g full scale
//! - Gyroscope: ±16 to ±2048 dps full scale
//! - Configurable output data rate (ODR)
//! - Temperature sensor
//! - FIFO support
//!
//! Usage:
//!   const Qmi8658 = drivers.Qmi8658(MyI2cBus, MyTime);
//!   var imu = Qmi8658.init(i2c_bus, .{});
//!   try imu.open();
//!   const data = try imu.read();
//!   // data.acc_x, data.acc_y, data.acc_z (raw 16-bit)
//!   // data.gyr_x, data.gyr_y, data.gyr_z (raw 16-bit)

const std = @import("std");
const trait = @import("trait");
const math = @import("math");
const qmi8658 = @This();

// ============================================================================
// Constants
// ============================================================================

/// QMI8658 I2C addresses (depends on SA0 pin)
pub const Address = enum(u7) {
    sa0_low = 0x6A, // SA0 = GND (default for LiChuang SZP)
    sa0_high = 0x6B, // SA0 = VDD
};

pub const DEFAULT_ADDRESS: u7 = @intFromEnum(Address.sa0_low);

/// Expected WHO_AM_I value
pub const WHO_AM_I_VALUE: u8 = 0x05;

// ============================================================================
// Register Definitions
// ============================================================================

/// QMI8658 register addresses
pub const Register = enum(u8) {
    who_am_i = 0x00,
    revision_id = 0x01,
    ctrl1 = 0x02, // Serial interface and sensor enable
    ctrl2 = 0x03, // Accelerometer settings
    ctrl3 = 0x04, // Gyroscope settings
    ctrl4 = 0x05, // Reserved
    ctrl5 = 0x06, // Low power mode
    ctrl6 = 0x07, // AttitudeEngine settings
    ctrl7 = 0x08, // Enable sensors
    ctrl8 = 0x09, // Motion detection
    ctrl9 = 0x0A, // Host commands
    // FIFO registers
    fifo_wtm_th = 0x13,
    fifo_ctrl = 0x14,
    fifo_smpl_cnt = 0x15,
    fifo_status = 0x16,
    fifo_data = 0x17,
    // Status registers
    statusint = 0x2D,
    status0 = 0x2E,
    status1 = 0x2F,
    // Timestamp
    timestamp_low = 0x30,
    timestamp_mid = 0x31,
    timestamp_high = 0x32,
    // Temperature
    temp_l = 0x33,
    temp_h = 0x34,
    // Accelerometer data
    ax_l = 0x35,
    ax_h = 0x36,
    ay_l = 0x37,
    ay_h = 0x38,
    az_l = 0x39,
    az_h = 0x3A,
    // Gyroscope data
    gx_l = 0x3B,
    gx_h = 0x3C,
    gy_l = 0x3D,
    gy_h = 0x3E,
    gz_l = 0x3F,
    gz_h = 0x40,
    // Quaternion/delta velocity (AttitudeEngine output)
    cod_status = 0x46,
    dqw_l = 0x49,
    dqw_h = 0x4A,
    dqx_l = 0x4B,
    dqx_h = 0x4C,
    dqy_l = 0x4D,
    dqy_h = 0x4E,
    dqz_l = 0x4F,
    dqz_h = 0x50,
    dvx_l = 0x51,
    dvx_h = 0x52,
    dvy_l = 0x53,
    dvy_h = 0x54,
    dvz_l = 0x55,
    dvz_h = 0x56,
    // Motion detection
    tap_status = 0x59,
    step_cnt_low = 0x5A,
    step_cnt_mid = 0x5B,
    step_cnt_high = 0x5C,
    // Reset
    reset = 0x60,
};

// ============================================================================
// Configuration Enums
// ============================================================================

/// Accelerometer full scale range
pub const AccelRange = enum(u3) {
    @"2g" = 0b000,
    @"4g" = 0b001,
    @"8g" = 0b010,
    @"16g" = 0b011,

    /// Get sensitivity in LSB/g (from QMI8658C datasheet)
    pub fn sensitivity(self: AccelRange) f32 {
        return switch (self) {
            .@"2g" => 16384.0, // ±2g: 16384 LSB/g
            .@"4g" => 8192.0, // ±4g: 8192 LSB/g
            .@"8g" => 4096.0, // ±8g: 4096 LSB/g
            .@"16g" => 2048.0, // ±16g: 2048 LSB/g
        };
    }
};

/// Gyroscope full scale range
pub const GyroRange = enum(u3) {
    @"16dps" = 0b000,
    @"32dps" = 0b001,
    @"64dps" = 0b010,
    @"128dps" = 0b011,
    @"256dps" = 0b100,
    @"512dps" = 0b101,
    @"1024dps" = 0b110,
    @"2048dps" = 0b111,

    /// Get sensitivity in LSB/dps (from QMI8658C datasheet)
    pub fn sensitivity(self: GyroRange) f32 {
        return switch (self) {
            .@"16dps" => 2048.0,
            .@"32dps" => 1024.0,
            .@"64dps" => 512.0,
            .@"128dps" => 256.0,
            .@"256dps" => 128.0,
            .@"512dps" => 64.0,
            .@"1024dps" => 32.0,
            .@"2048dps" => 16.0,
        };
    }
};

/// Output data rate for accelerometer
pub const AccelOdr = enum(u4) {
    @"8000Hz" = 0b0000,
    @"4000Hz" = 0b0001,
    @"2000Hz" = 0b0010,
    @"1000Hz" = 0b0011,
    @"500Hz" = 0b0100,
    @"250Hz" = 0b0101,
    @"125Hz" = 0b0110,
    @"62.5Hz" = 0b0111,
    @"31.25Hz" = 0b1000,
    low_power_128Hz = 0b1100,
    low_power_21Hz = 0b1101,
    low_power_11Hz = 0b1110,
    low_power_3Hz = 0b1111,
};

/// Output data rate for gyroscope
pub const GyroOdr = enum(u4) {
    @"8000Hz" = 0b0000,
    @"4000Hz" = 0b0001,
    @"2000Hz" = 0b0010,
    @"1000Hz" = 0b0011,
    @"500Hz" = 0b0100,
    @"250Hz" = 0b0101,
    @"125Hz" = 0b0110,
    @"62.5Hz" = 0b0111,
    @"31.25Hz" = 0b1000,
};

// ============================================================================
// Data Structures
// ============================================================================

/// Raw IMU data (16-bit signed values)
pub const RawData = struct {
    acc_x: i16 = 0,
    acc_y: i16 = 0,
    acc_z: i16 = 0,
    gyr_x: i16 = 0,
    gyr_y: i16 = 0,
    gyr_z: i16 = 0,
};

/// Scaled IMU data (physical units)
pub const ScaledData = struct {
    /// Acceleration in g
    acc_x: f32 = 0,
    acc_y: f32 = 0,
    acc_z: f32 = 0,
    /// Angular velocity in degrees per second
    gyr_x: f32 = 0,
    gyr_y: f32 = 0,
    gyr_z: f32 = 0,
};

/// Euler angles calculated from accelerometer
/// Note: Yaw cannot be determined from accelerometer alone
/// (would need magnetometer or gyro integration)
pub const Angles = struct {
    /// Roll angle in degrees (rotation around X axis)
    roll: f32 = 0,
    /// Pitch angle in degrees (rotation around Y axis)
    pitch: f32 = 0,
};

/// Configuration for QMI8658
pub const Config = struct {
    /// I2C address
    address: u7 = DEFAULT_ADDRESS,
    /// Accelerometer range
    accel_range: AccelRange = .@"4g",
    /// Gyroscope range
    gyro_range: GyroRange = .@"512dps",
    /// Accelerometer ODR
    accel_odr: AccelOdr = .@"250Hz",
    /// Gyroscope ODR
    gyro_odr: GyroOdr = .@"250Hz",
};

// ============================================================================
// Driver Implementation
// ============================================================================

/// QMI8658 6-Axis IMU Driver
/// Generic over I2C bus type and Time interface for platform independence
pub fn Qmi8658(comptime I2cImpl: type, comptime TimeImpl: type) type {
    const I2c = trait.i2c.from(I2cImpl);
    const Time = trait.time.from(TimeImpl);

    return struct {
        const Self = @This();

        /// Sensor capabilities
        pub const capabilities = struct {
            pub const has_gyro = true;
            pub const has_temp = true;
            pub const axis_count = 6;
        };

        i2c: I2c,
        config: Config,
        is_open: bool = false,

        /// Initialize driver with I2C bus and configuration
        pub fn init(i2c_impl: I2cImpl, config: Config) Self {
            return .{
                .i2c = I2c.wrap(i2c_impl),
                .config = config,
            };
        }

        /// Read a register value
        pub fn readRegister(self: *Self, reg: Register) !u8 {
            var buf: [1]u8 = undefined;
            try self.i2c.writeRead(self.config.address, &.{@intFromEnum(reg)}, &buf);
            return buf[0];
        }

        /// Write a register value
        pub fn writeRegister(self: *Self, reg: Register, value: u8) !void {
            try self.i2c.write(self.config.address, &.{ @intFromEnum(reg), value });
        }

        /// Read multiple bytes starting from a register
        pub fn readRegisters(self: *Self, start_reg: Register, buf: []u8) !void {
            try self.i2c.writeRead(self.config.address, &.{@intFromEnum(start_reg)}, buf);
        }

        // ====================================================================
        // High-level API
        // ====================================================================

        /// Open and initialize the IMU
        pub fn open(self: *Self) !void {
            // Verify chip ID
            const id = try self.readRegister(.who_am_i);
            if (id != WHO_AM_I_VALUE) {
                return error.InvalidChipId;
            }

            // Software reset
            try self.writeRegister(.reset, 0xB0);

            // Wait for reset (~10ms required by QMI8658 datasheet)
            Time.sleepMs(10);

            // Configure CTRL1: address auto-increment enabled
            try self.writeRegister(.ctrl1, 0x40);

            // Configure CTRL7: enable accelerometer and gyroscope
            // Bit 0: Accelerometer enable
            // Bit 1: Gyroscope enable
            try self.writeRegister(.ctrl7, 0x03);

            // Configure accelerometer (CTRL2)
            // QMI8658C datasheet CTRL2 format:
            // Bit 7: aST (Self Test) - should be 0
            // Bits 6:4: aFS (Full Scale) - 000=2g, 001=4g, 010=8g, 011=16g
            // Bits 3:0: aODR (ODR) - 0101=235Hz (250Hz nominal)
            const ctrl2 = (@as(u8, @intFromEnum(self.config.accel_range)) << 4) |
                @as(u8, @intFromEnum(self.config.accel_odr));
            try self.writeRegister(.ctrl2, ctrl2);

            // Configure gyroscope (CTRL3)
            // QMI8658C datasheet CTRL3 format:
            // Bit 7: gST (Self Test) - should be 0
            // Bits 6:4: gFS (Full Scale) - 101=512dps
            // Bits 3:0: gODR (ODR) - 0101=235Hz
            const ctrl3 = (@as(u8, @intFromEnum(self.config.gyro_range)) << 4) |
                @as(u8, @intFromEnum(self.config.gyro_odr));
            try self.writeRegister(.ctrl3, ctrl3);

            self.is_open = true;
        }

        /// Close the IMU
        pub fn close(self: *Self) !void {
            if (self.is_open) {
                // Disable sensors
                try self.writeRegister(.ctrl7, 0x00);
                self.is_open = false;
            }
        }

        /// Check if data is ready
        pub fn isDataReady(self: *Self) !bool {
            const status = try self.readRegister(.status0);
            // Bit 0: Accelerometer data available
            // Bit 1: Gyroscope data available
            return (status & 0x03) == 0x03;
        }

        /// Read raw accelerometer and gyroscope data
        pub fn readRaw(self: *Self) !qmi8658.RawData {
            if (!self.is_open) return error.NotOpen;

            // Read 12 bytes starting from AX_L (accel + gyro data)
            var buf: [12]u8 = undefined;
            try self.readRegisters(.ax_l, &buf);

            return qmi8658.RawData{
                .acc_x = @bitCast([2]u8{ buf[0], buf[1] }),
                .acc_y = @bitCast([2]u8{ buf[2], buf[3] }),
                .acc_z = @bitCast([2]u8{ buf[4], buf[5] }),
                .gyr_x = @bitCast([2]u8{ buf[6], buf[7] }),
                .gyr_y = @bitCast([2]u8{ buf[8], buf[9] }),
                .gyr_z = @bitCast([2]u8{ buf[10], buf[11] }),
            };
        }

        /// Read and convert to physical units
        pub fn readScaled(self: *Self) !qmi8658.ScaledData {
            const raw = try self.readRaw();
            const acc_sens = self.config.accel_range.sensitivity();
            const gyr_sens = self.config.gyro_range.sensitivity();

            return qmi8658.ScaledData{
                .acc_x = @as(f32, @floatFromInt(raw.acc_x)) / acc_sens,
                .acc_y = @as(f32, @floatFromInt(raw.acc_y)) / acc_sens,
                .acc_z = @as(f32, @floatFromInt(raw.acc_z)) / acc_sens,
                .gyr_x = @as(f32, @floatFromInt(raw.gyr_x)) / gyr_sens,
                .gyr_y = @as(f32, @floatFromInt(raw.gyr_y)) / gyr_sens,
                .gyr_z = @as(f32, @floatFromInt(raw.gyr_z)) / gyr_sens,
            };
        }

        /// Calculate tilt angles from accelerometer data
        /// Note: This only works when the device is stationary or moving slowly
        pub fn readAngles(self: *Self) !qmi8658.Angles {
            const raw = try self.readRaw();
            const ax: f32 = @floatFromInt(raw.acc_x);
            const ay: f32 = @floatFromInt(raw.acc_y);
            const az: f32 = @floatFromInt(raw.acc_z);

            // Calculate roll (rotation around X)
            // roll = atan2(ay, az)
            const roll = math.approxAtan2(ay, az) * (180.0 / std.math.pi);

            // Calculate pitch (rotation around Y)
            // pitch = atan2(-ax, sqrt(ay^2 + az^2))
            const pitch = math.approxAtan2(-ax, @sqrt(ay * ay + az * az)) * (180.0 / std.math.pi);

            return qmi8658.Angles{
                .roll = roll,
                .pitch = pitch,
            };
        }

        /// Read temperature in Celsius
        pub fn readTemperature(self: *Self) !f32 {
            if (!self.is_open) return error.NotOpen;

            var buf: [2]u8 = undefined;
            try self.readRegisters(.temp_l, &buf);
            const raw: i16 = @bitCast([2]u8{ buf[0], buf[1] });

            // Temperature formula: T = raw / 256 + 25
            return @as(f32, @floatFromInt(raw)) / 256.0 + 25.0;
        }

        /// Set accelerometer range
        pub fn setAccelRange(self: *Self, range: qmi8658.AccelRange) !void {
            self.config.accel_range = range;
            if (self.is_open) {
                const ctrl2 = (@as(u8, @intFromEnum(self.config.accel_odr)) << 4) |
                    @as(u8, @intFromEnum(range));
                try self.writeRegister(.ctrl2, ctrl2);
            }
        }

        /// Set gyroscope range
        pub fn setGyroRange(self: *Self, range: qmi8658.GyroRange) !void {
            self.config.gyro_range = range;
            if (self.is_open) {
                const ctrl3 = (@as(u8, @intFromEnum(self.config.gyro_odr)) << 4) |
                    @as(u8, @intFromEnum(range));
                try self.writeRegister(.ctrl3, ctrl3);
            }
        }

        /// Perform self-test
        pub fn selfTest(self: *Self) !bool {
            const id = try self.readRegister(.who_am_i);
            return id == WHO_AM_I_VALUE;
        }

        /// Get revision ID
        pub fn getRevisionId(self: *Self) !u8 {
            return self.readRegister(.revision_id);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn init() MockI2c {
        var self = MockI2c{};
        // Set WHO_AM_I to expected value
        self.registers[@intFromEnum(Register.who_am_i)] = WHO_AM_I_VALUE;
        return self;
    }

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0) {
            const start_reg = write_buf[0];
            for (read_buf, 0..) |*byte, i| {
                byte.* = self.registers[start_reg + i];
            }
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

test "Qmi8658 initialization" {
    var mock = MockI2c.init();
    var imu = Qmi8658(*MockI2c).init(&mock, .{});

    try imu.open();
    try std.testing.expect(imu.is_open);

    try imu.close();
    try std.testing.expect(!imu.is_open);
}

test "Qmi8658 self test" {
    var mock = MockI2c.init();
    var imu = Qmi8658(*MockI2c).init(&mock, .{});

    const result = try imu.selfTest();
    try std.testing.expect(result);
}

test "AccelRange sensitivity" {
    try std.testing.expectEqual(@as(f32, 16384.0), AccelRange.@"2g".sensitivity());
    try std.testing.expectEqual(@as(f32, 8192.0), AccelRange.@"4g".sensitivity());
    try std.testing.expectEqual(@as(f32, 4096.0), AccelRange.@"8g".sensitivity());
    try std.testing.expectEqual(@as(f32, 2048.0), AccelRange.@"16g".sensitivity());
}

test "GyroRange sensitivity" {
    try std.testing.expectEqual(@as(f32, 64.0), GyroRange.@"512dps".sensitivity());
    try std.testing.expectEqual(@as(f32, 32.0), GyroRange.@"1024dps".sensitivity());
}
