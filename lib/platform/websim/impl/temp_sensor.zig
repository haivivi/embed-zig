//! WebSim Temperature Sensor Driver
//!
//! Returns a simulated temperature value.
//! Could be made interactive via JS (slider) in the future.

const state_mod = @import("state.zig");
const shared = &state_mod.state;

pub const TempSensorDriver = struct {
    const Self = @This();

    /// Simulated temperature in Celsius (default: room temperature)
    temperature: f32 = 25.0,
    enabled: bool = false,

    pub fn init() !Self {
        shared.addLog("WebSim: Temperature sensor initialized");
        return .{ .enabled = true };
    }

    pub fn deinit(_: *Self) void {}

    pub fn enable(self: *Self) !void {
        self.enabled = true;
    }

    pub fn disable(self: *Self) !void {
        self.enabled = false;
    }

    /// Read temperature in Celsius
    pub fn readCelsius(self: *Self) !f32 {
        if (!self.enabled) try self.enable();
        return self.temperature;
    }
};
