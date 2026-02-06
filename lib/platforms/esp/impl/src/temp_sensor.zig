//! Temperature Sensor Implementation for ESP32
//!
//! Implements hal.temp_sensor Driver interface using idf.adc.TempSensor.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const temp_spec = struct {
//!       pub const Driver = impl.TempSensorDriver;
//!       pub const meta = .{ .id = "temp.internal" };
//!   };
//!   const TempSensor = hal.temp_sensor.from(temp_spec);

const idf = @import("idf");

/// Temperature Sensor Driver that implements hal.temp_sensor.Driver interface
/// Uses ESP32 internal temperature sensor
pub const TempSensorDriver = struct {
    const Self = @This();

    sensor: idf.TempSensor,
    enabled: bool = false,

    /// Initialize temperature sensor
    pub fn init() !Self {
        const sensor = try idf.TempSensor.init(.{});
        return .{ .sensor = sensor };
    }

    /// Deinitialize temperature sensor
    pub fn deinit(self: *Self) void {
        if (self.enabled) {
            self.sensor.disable() catch {};
        }
        self.sensor.deinit();
    }

    /// Enable sensor (must call before reading)
    pub fn enable(self: *Self) !void {
        try self.sensor.enable();
        self.enabled = true;
    }

    /// Disable sensor
    pub fn disable(self: *Self) !void {
        try self.sensor.disable();
        self.enabled = false;
    }

    /// Read temperature in Celsius (required by hal.temp_sensor)
    pub fn readCelsius(self: *Self) !f32 {
        if (!self.enabled) {
            try self.enable();
        }
        return self.sensor.readCelsius();
    }
};
