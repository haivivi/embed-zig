//! BK7258 Software Timer Binding
//!
//! Wraps RTOS software timers (periodic + one-shot).

pub const TimerCallback = *const fn (timer_id: c_uint) callconv(.c) void;

extern fn bk_zig_timer_start_periodic(period_ms: c_uint, callback: TimerCallback) c_int;
extern fn bk_zig_timer_start_oneshot(delay_ms: c_uint, callback: TimerCallback) c_int;
extern fn bk_zig_timer_stop_periodic(handle: c_int) void;
extern fn bk_zig_timer_stop_oneshot(handle: c_int) void;

pub const Error = error{TimerError};

pub const Timer = struct {
    handle: c_int,
    is_oneshot: bool,

    /// Start a periodic timer with callback
    pub fn startPeriodic(period_ms: u32, callback: TimerCallback) Error!Timer {
        const h = bk_zig_timer_start_periodic(@intCast(period_ms), callback);
        if (h < 0) return error.TimerError;
        return .{ .handle = h, .is_oneshot = false };
    }

    /// Start a one-shot timer with callback
    pub fn startOneshot(delay_ms: u32, callback: TimerCallback) Error!Timer {
        const h = bk_zig_timer_start_oneshot(@intCast(delay_ms), callback);
        if (h < 0) return error.TimerError;
        return .{ .handle = h, .is_oneshot = true };
    }

    /// Stop and free the timer
    pub fn stop(self: *Timer) void {
        if (self.is_oneshot) {
            bk_zig_timer_stop_oneshot(self.handle);
        } else {
            bk_zig_timer_stop_periodic(self.handle);
        }
        self.handle = -1;
    }
};
