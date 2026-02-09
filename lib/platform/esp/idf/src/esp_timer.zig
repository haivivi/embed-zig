//! ESP-IDF esp_timer bindings
//!
//! High-level timer service. Callbacks run in esp_timer task context
//! (not ISR), safe for most operations.
//!
//! For hardware GPTimer (ISR callbacks), see timer.zig.

const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("esp_timer.h");
});

/// esp_timer handle (opaque pointer)
pub const Handle = c.esp_timer_handle_t;

/// C-callable callback type
pub const CCallback = *const fn (?*anyopaque) callconv(.c) void;

// Helper function from esp_timer/helper.c
extern fn esp_timer_create_oneshot(callback: CCallback, arg: ?*anyopaque, out_handle: *Handle) c_int;

/// Create a one-shot timer with callback dispatched in task context.
pub fn createOneshot(callback: CCallback, arg: ?*anyopaque) !Handle {
    var handle: Handle = null;
    const err = esp_timer_create_oneshot(callback, arg, &handle);
    try sys.espErrToZig(err);
    return handle;
}

/// Start a one-shot timer with timeout in microseconds.
pub fn startOnce(handle: Handle, timeout_us: u64) !void {
    const err = c.esp_timer_start_once(handle, @intCast(timeout_us));
    try sys.espErrToZig(err);
}

/// Stop a running timer.
pub fn stop(handle: Handle) void {
    _ = c.esp_timer_stop(handle);
}

/// Delete a timer.
pub fn delete(handle: Handle) void {
    _ = c.esp_timer_delete(handle);
}
