//! LED Implementation for BK7258
//!
//! Implements hal.led Driver interface using armino PWM.

const armino = @import("../../armino/src/armino.zig");

/// LED Driver using PWM channel
pub fn PwmLedDriver(comptime pwm_channel: u32, comptime period_us: u32) type {
    return struct {
        const Self = @This();
        const MAX_DUTY: u16 = 65535;

        duty: u16 = 0,
        initialized: bool = false,

        pub fn init() !Self {
            armino.pwm.init(pwm_channel, period_us, 0) catch return error.InitFailed;
            armino.pwm.start(pwm_channel) catch return error.InitFailed;
            return .{ .initialized = true };
        }

        pub fn deinit(self: *Self) void {
            if (self.initialized) {
                armino.pwm.stop(pwm_channel) catch {};
                self.initialized = false;
            }
        }

        pub fn setDuty(self: *Self, duty: u16) void {
            self.duty = duty;
            const hw_duty: u32 = @as(u32, duty) * period_us / MAX_DUTY;
            armino.pwm.setDuty(pwm_channel, hw_duty) catch {};
        }

        pub fn getDuty(self: *const Self) u16 {
            return self.duty;
        }

        pub fn fade(self: *Self, target: u16, duration_ms: u32) void {
            const steps: u32 = duration_ms / 10;
            if (steps == 0) {
                self.setDuty(target);
                return;
            }
            const current = self.duty;
            var i: u32 = 0;
            while (i <= steps) : (i += 1) {
                const progress = @as(u32, i) * 65535 / steps;
                const new_duty: u16 = @intCast(
                    (@as(u32, current) * (65535 - progress) + @as(u32, target) * progress) / 65535,
                );
                self.setDuty(new_duty);
                armino.time.sleepMs(10);
            }
        }
    };
}
