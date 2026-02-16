//! Temperature Sensor Implementation for BK7258
//!
//! Uses internal MCU temperature sensor via Armino bk_sensor API.
//! Same interface as ESP's temp_sensor.

extern fn bk_zig_temp_read(temp_x100_out: *c_int) c_int;

pub const TempSensorDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn enable(_: *Self) !void {}
    pub fn disable(_: *Self) !void {}

    /// Read temperature in Celsius (integer x100, e.g. 3250 = 32.50°C)
    pub fn readCelsiusX100(self: *Self) !i32 {
        _ = self;
        var temp_x100: c_int = 0;
        if (bk_zig_temp_read(&temp_x100) != 0) return error.SensorError;
        return @intCast(temp_x100);
    }

    /// Read temperature in Celsius as f32 (compatible with e2e test interface)
    pub fn readCelsius(self: *Self) !f32 {
        const x100 = try self.readCelsiusX100();
        return @as(f32, @floatFromInt(x100)) / 100.0;
    }
};
