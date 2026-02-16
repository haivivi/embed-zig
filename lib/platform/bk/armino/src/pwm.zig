//! BK7258 PWM Binding

extern fn bk_zig_pwm_init(channel: u32, period_us: u32, duty_cycle: u32) c_int;
extern fn bk_zig_pwm_start(channel: u32) c_int;
extern fn bk_zig_pwm_stop(channel: u32) c_int;
extern fn bk_zig_pwm_set_duty(channel: u32, duty_cycle: u32) c_int;

pub fn init(channel: u32, period_us: u32, duty_cycle: u32) !void {
    if (bk_zig_pwm_init(channel, period_us, duty_cycle) != 0) return error.PwmError;
}

pub fn start(channel: u32) !void {
    if (bk_zig_pwm_start(channel) != 0) return error.PwmError;
}

pub fn stop(channel: u32) !void {
    if (bk_zig_pwm_stop(channel) != 0) return error.PwmError;
}

pub fn setDuty(channel: u32, duty_cycle: u32) !void {
    if (bk_zig_pwm_set_duty(channel, duty_cycle) != 0) return error.PwmError;
}
