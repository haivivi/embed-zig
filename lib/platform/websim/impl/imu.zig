//! WebSim IMU (Inertial Measurement Unit) Driver
//!
//! Simulates accelerometer + gyroscope.
//! Default: stationary (accel = 0,0,1g, gyro = 0,0,0).
//! Could be made interactive via JS (mouse drag to tilt) in the future.

const hal = @import("hal");
const state_mod = @import("state.zig");
const shared = &state_mod.state;

pub const ImuDriver = struct {
    const Self = @This();

    /// Simulated accelerometer data (default: stationary, Z = 1g)
    accel_x: f32 = 0.0,
    accel_y: f32 = 0.0,
    accel_z: f32 = 1.0, // 1g downward

    /// Simulated gyroscope data (default: no rotation)
    gyro_x: f32 = 0.0,
    gyro_y: f32 = 0.0,
    gyro_z: f32 = 0.0,

    pub fn init() !Self {
        shared.addLog("WebSim: IMU initialized (accel+gyro)");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Read accelerometer (returns scaled values in g, where 1g = 9.81 m/s²)
    pub fn readAccel(self: *Self) !hal.imu.AccelData {
        return .{
            .x = self.accel_x,
            .y = self.accel_y,
            .z = self.accel_z,
        };
    }

    /// Read gyroscope (returns angular velocity in degrees/second)
    pub fn readGyro(self: *Self) !hal.imu.GyroData {
        return .{
            .x = self.gyro_x,
            .y = self.gyro_y,
            .z = self.gyro_z,
        };
    }
};
