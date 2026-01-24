//! Hardware Timer (GPTimer) driver
//!
//! Example:
//! ```zig
//! const timer = idf.timer;
//!
//! var t = try timer.Timer.init(1_000_000); // 1MHz resolution
//! defer t.deinit();
//!
//! try t.setAlarm(1_000_000, true); // 1 second, auto-reload
//! try t.registerCallback(myCallback, null);
//! try t.enable();
//! try t.start();
//! ```

const std = @import("std");
const sys = @import("../sys.zig");

const c = @cImport({
    @cInclude("driver/gptimer.h");
});

// Extern declarations for helper functions
extern fn gptimer_new_timer_simple(resolution_hz: u32, out_handle: *c.gptimer_handle_t) c_int;
extern fn gptimer_set_alarm_simple(timer: c.gptimer_handle_t, alarm_count: u64, auto_reload: c_int) c_int;
extern fn gptimer_register_callback_simple(timer: c.gptimer_handle_t, callback: *const anyopaque, user_data: ?*anyopaque) c_int;

/// Alarm event data passed to callback
pub const AlarmEventData = extern struct {
    count_value: u64,
    alarm_value: u64,
};

/// Alarm callback function type
/// Returns true to yield from ISR (for high priority tasks)
pub const AlarmCallback = *const fn (?*anyopaque, *const AlarmEventData, ?*anyopaque) callconv(.c) bool;

/// Hardware Timer wrapper
pub const Timer = struct {
    handle: c.gptimer_handle_t,

    /// Initialize a new timer with given resolution in Hz
    pub fn init(resolution_hz: u32) !Timer {
        var handle: c.gptimer_handle_t = null;
        const err = gptimer_new_timer_simple(resolution_hz, &handle);
        try sys.espErrToZig(err);
        return Timer{ .handle = handle };
    }

    /// Deinitialize the timer
    pub fn deinit(self: *Timer) void {
        _ = c.gptimer_del_timer(self.handle);
        self.handle = null;
    }

    /// Enable the timer
    pub fn enable(self: Timer) !void {
        const err = c.gptimer_enable(self.handle);
        try sys.espErrToZig(err);
    }

    /// Disable the timer
    pub fn disable(self: Timer) !void {
        const err = c.gptimer_disable(self.handle);
        try sys.espErrToZig(err);
    }

    /// Start the timer
    pub fn start(self: Timer) !void {
        const err = c.gptimer_start(self.handle);
        try sys.espErrToZig(err);
    }

    /// Stop the timer
    pub fn stop(self: Timer) !void {
        const err = c.gptimer_stop(self.handle);
        try sys.espErrToZig(err);
    }

    /// Set the timer count value
    pub fn setCount(self: Timer, count: u64) !void {
        const err = c.gptimer_set_raw_count(self.handle, count);
        try sys.espErrToZig(err);
    }

    /// Get the current count value
    pub fn getCount(self: Timer) !u64 {
        var count: u64 = 0;
        const err = c.gptimer_get_raw_count(self.handle, &count);
        try sys.espErrToZig(err);
        return count;
    }

    /// Set alarm with target count and auto-reload option
    pub fn setAlarm(self: Timer, alarm_count: u64, auto_reload: bool) !void {
        const err = gptimer_set_alarm_simple(self.handle, alarm_count, if (auto_reload) 1 else 0);
        try sys.espErrToZig(err);
    }

    /// Register alarm callback
    pub fn registerCallback(self: Timer, callback: AlarmCallback, user_data: ?*anyopaque) !void {
        const err = gptimer_register_callback_simple(self.handle, @ptrCast(callback), user_data);
        try sys.espErrToZig(err);
    }
};
