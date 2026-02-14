//! BK7258 Hardware Timer Binding
//!
//! 4 available channels (TIMER_ID0, 1, 4, 5 — timer2/3 system-reserved).
//! Callbacks run in ISR context — must be fast, no blocking.
//! Periodic (ms) and one-shot (us) modes.

pub const TimerCallback = *const fn (slot: c_uint) callconv(.c) void;

extern fn bk_zig_hw_timer_start(period_ms: c_uint, callback: TimerCallback) c_int;
extern fn bk_zig_hw_timer_oneshot_us(delay_us: c_ulonglong, callback: TimerCallback) c_int;
extern fn bk_zig_hw_timer_stop(slot: c_int) void;
extern fn bk_zig_hw_timer_get_cnt(slot: c_int) c_uint;
extern fn bk_zig_hw_timer_available() c_int;

pub const Error = error{TimerError};

/// Maximum usable hardware timer slots
pub const MAX_TIMERS = 4;

pub const Timer = struct {
    slot: c_int,

    /// Start a periodic hardware timer (ISR callback).
    pub fn startPeriodic(period_ms: u32, callback: TimerCallback) Error!Timer {
        const s = bk_zig_hw_timer_start(@intCast(period_ms), callback);
        if (s < 0) return error.TimerError;
        return .{ .slot = s };
    }

    /// Start a one-shot hardware timer with microsecond precision (ISR callback).
    pub fn startOneshotUs(delay_us: u64, callback: TimerCallback) Error!Timer {
        const s = bk_zig_hw_timer_oneshot_us(@intCast(delay_us), callback);
        if (s < 0) return error.TimerError;
        return .{ .slot = s };
    }

    /// Start a one-shot hardware timer with millisecond precision.
    pub fn startOneshot(delay_ms: u32, callback: TimerCallback) Error!Timer {
        return startOneshotUs(@as(u64, delay_ms) * 1000, callback);
    }

    /// Stop and release the timer.
    pub fn stop(self: *Timer) void {
        bk_zig_hw_timer_stop(self.slot);
        self.slot = -1;
    }

    /// Get current counter value (counts down from period).
    pub fn getCount(self: Timer) u32 {
        return @intCast(bk_zig_hw_timer_get_cnt(self.slot));
    }
};

/// Get number of free timer slots.
pub fn available() u32 {
    return @intCast(bk_zig_hw_timer_available());
}
