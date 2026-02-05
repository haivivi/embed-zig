//! ESP32-S3-DevKitC-1 Board Support Package
//!
//! Temperature sensor configuration for the ESP32-S3 DevKit.

const std = @import("std");
const hal = @import("hal");
const esp = @import("esp");

const idf = esp.idf;
const board = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
};

// ============================================================================
// Drivers (re-export from central board)
// ============================================================================

pub const RtcDriver = board.RtcDriver;

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc.esp32s3" };
};

// ============================================================================
// Platform Primitives (re-export from central board)
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

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
    pub const meta = .{ .id = "temp.internal" };
};
