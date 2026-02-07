//! LiChuang GoCool Board Support Package
//!
//! Motion detection configuration for the LiChuang GoCool ESP32-S3 board.
//! Uses QMI8658 6-axis IMU for motion detection.

const std = @import("std");
const hal = @import("hal");
const esp = @import("esp");

const idf = esp.idf;
const board = esp.boards.lichuang_gocool;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
};

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = board.RtcDriver;

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc.esp32s3" };
};

// ============================================================================
// Button Driver (Boot button)
// ============================================================================

pub const button_spec = struct {
    pub const Driver = board.BootButtonDriver;
    pub const meta = .{ .id = "button.boot" };
    pub const ButtonId = enum(u8) { boot = 0 };

    pub fn mapButton(_: usize) ButtonId {
        return .boot;
    }
};

// ============================================================================
// IMU Driver (QMI8658)
// ============================================================================

/// Custom IMU driver that initializes I2C and QMI8658.
///
/// Uses two-phase init: init() returns a lightweight struct, ensureInit()
/// performs the actual I2C + QMI8658 initialization on first use.
/// This is necessary because init() returns Self by value (copy), so any
/// internal pointers (e.g. inner.i2c → &self.i2c_bus) would dangle after
/// the struct is moved to its final address in the HAL Board.
pub const ImuDriver = struct {
    const Self = @This();

    i2c_bus: idf.I2c = undefined,
    inner: board.ImuDriver = undefined,
    initialized: bool = false,

    pub fn init() !Self {
        return .{};
    }

    /// Initialize I2C and QMI8658 on first use (self must be at stable address)
    fn ensureInit(self: *Self) !void {
        if (self.initialized) return;

        self.i2c_bus = try idf.I2c.init(.{
            .port = 0,
            .sda = board.i2c_sda,
            .scl = board.i2c_scl,
            .freq_hz = board.i2c_freq_hz,
        });
        errdefer self.i2c_bus.deinit();

        self.inner = board.ImuDriver{};
        try self.inner.initWithI2c(&self.i2c_bus);

        self.initialized = true;
        log.info("ImuDriver: I2C and QMI8658 initialized", .{});
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.inner.deinit();
            self.i2c_bus.deinit();
            self.initialized = false;
        }
    }

    pub fn readAccel(self: *Self) !hal.AccelData {
        try self.ensureInit();
        return self.inner.readAccel();
    }

    pub fn readGyro(self: *Self) !hal.GyroData {
        try self.ensureInit();
        return self.inner.readGyro();
    }

    pub fn readAngles(self: *Self) !struct { roll: f32, pitch: f32 } {
        try self.ensureInit();
        return self.inner.readAngles();
    }

    pub fn readTemperature(self: *Self) !f32 {
        try self.ensureInit();
        return self.inner.readTemperature();
    }

    pub fn isDataReady(self: *Self) !bool {
        if (!self.initialized) return false;
        return self.inner.isDataReady();
    }
};

pub const imu_spec = struct {
    pub const Driver = ImuDriver;
    pub const meta = .{ .id = "imu.qmi8658" };
};

// ============================================================================
// Motion Detection Spec
// ============================================================================

pub const motion_spec = struct {
    /// IMU type used by motion detector
    pub const Imu = ImuDriver;
    pub const meta = .{ .id = "motion.qmi8658" };
};
