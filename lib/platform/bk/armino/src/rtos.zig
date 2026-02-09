//! Armino SDK RTOS (FreeRTOS) Bindings
//!
//! Provides task/thread management via C helper functions.

// C helper functions (defined in bk_zig_helper.c)
extern fn bk_zig_delay_ms(ms: u32) void;
extern fn bk_zig_create_thread(
    name: [*:0]const u8,
    func: *const fn (?*anyopaque) callconv(.C) void,
    arg: ?*anyopaque,
    stack_size: u32,
    priority: u32,
) i32;

/// Delay for specified milliseconds
pub fn delayMs(ms: u32) void {
    bk_zig_delay_ms(ms);
}

/// Create a new FreeRTOS thread
/// Returns 0 on success, negative on error.
pub fn createThread(
    name: [*:0]const u8,
    func: *const fn (?*anyopaque) callconv(.C) void,
    arg: ?*anyopaque,
    stack_size: u32,
    priority: u32,
) !void {
    const ret = bk_zig_create_thread(name, func, arg, stack_size, priority);
    if (ret != 0) return error.ThreadCreateFailed;
}
