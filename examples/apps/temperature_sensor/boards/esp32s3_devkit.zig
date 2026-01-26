//! ESP32-S3-DevKitC-1 Board Support Package
//!
//! Temperature sensor configuration for the ESP32-S3 DevKit.

const std = @import("std");
const hal = @import("hal");
const idf = @import("esp");

// ============================================================================
// Platform SAL
// ============================================================================

pub const sal = idf.sal;

// ============================================================================
// RTC Driver (required by hal.Board)
// ============================================================================

pub const RtcDriver = struct {
    pub fn init() !RtcDriver {
        return .{};
    }

    pub fn deinit(_: *RtcDriver) void {}

    pub fn uptime(_: *RtcDriver) u64 {
        return idf.nowMs();
    }

    pub fn read(_: *RtcDriver) ?i64 {
        return null; // No RTC hardware, return null
    }
};

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = hal.Meta{ .id = "rtc.esp32s3" };
};

// ============================================================================
// Temperature Sensor Driver
// ============================================================================

pub const TempDriver = struct {
    sensor: idf.adc.TempSensor,

    pub fn init() !TempDriver {
        var sensor = try idf.adc.TempSensor.init(.{
            .range = .{ .min = -10, .max = 80 },
        });
        try sensor.enable();
        std.log.info("DevKit TempDriver: Internal temp sensor initialized", .{});
        return .{ .sensor = sensor };
    }

    pub fn deinit(self: *TempDriver) void {
        self.sensor.deinit();
    }

    pub fn readCelsius(self: *TempDriver) !f32 {
        return self.sensor.readCelsius();
    }
};

pub const temp_spec = struct {
    pub const Driver = TempDriver;
    pub const meta = hal.Meta{ .id = "temp.internal" };
};
