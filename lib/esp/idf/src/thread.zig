//! FreeRTOS Task Wrapper (Low-level)
//!
//! Low-level FreeRTOS task creation with PSRAM stack support.
//! For most use cases, prefer `idf.async_` which provides higher-level
//! `go()` and `WaitGroup` primitives.

const std = @import("std");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("freertos/semphr.h");
    @cInclude("freertos/idf_additions.h");
    @cInclude("esp_heap_caps.h");
});

// ============================================================================
// Types
// ============================================================================

/// Task function type
pub const TaskFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

/// Task creation options
pub const Options = struct {
    /// Stack size in bytes
    stack_size: u32 = 8192,
    /// Task priority (FreeRTOS: 0-24, higher = more priority)
    priority: u8 = 16,
    /// CPU core affinity (-1 = any core)
    core: i8 = 1,
};

/// Task handle
pub const Handle = struct {
    freertos_handle: c.TaskHandle_t,
    stack: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Handle) void {
        // Note: FreeRTOS frees the stack when task is deleted via
        // xTaskCreateRestrictedPinnedToCore, so we don't free here
        _ = self;
    }
};

// ============================================================================
// Thread Functions
// ============================================================================

/// Spawn a new task with stack allocated from the provided allocator
pub fn spawn(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: TaskFn,
    arg: ?*anyopaque,
    options: Options,
) !Handle {
    // Allocate stack from provided allocator (e.g., psram or iram)
    const stack = try allocator.alloc(u8, options.stack_size);
    errdefer allocator.free(stack);

    // Create FreeRTOS task with custom stack
    var task_params: c.TaskParameters_t = std.mem.zeroes(c.TaskParameters_t);
    task_params.pvTaskCode = func;
    task_params.pcName = name.ptr;
    task_params.usStackDepth = options.stack_size / @sizeOf(c.StackType_t);
    task_params.puxStackBuffer = @ptrCast(@alignCast(stack.ptr));
    task_params.pvParameters = arg;
    task_params.uxPriority = options.priority;

    var handle: c.TaskHandle_t = null;
    const core: c.BaseType_t = if (options.core < 0) c.tskNO_AFFINITY else options.core;
    const result = c.xTaskCreateRestrictedPinnedToCore(&task_params, &handle, core);

    if (result != c.pdPASS) {
        allocator.free(stack);
        return error.TaskCreateFailed;
    }

    return Handle{
        .freertos_handle = handle,
        .stack = stack,
        .allocator = allocator,
    };
}

/// Yield execution to other tasks
pub fn yield() void {
    c.taskYIELD();
}

/// Get current task handle
pub fn current() c.TaskHandle_t {
    return c.xTaskGetCurrentTaskHandle();
}

/// Delete current task (does not return)
pub fn deleteSelf() noreturn {
    c.vTaskDelete(null);
    unreachable;
}

/// Get stack high water mark (minimum free stack ever)
pub fn getStackHighWaterMark(task: ?c.TaskHandle_t) u32 {
    return c.uxTaskGetStackHighWaterMark(task) * @sizeOf(c.StackType_t);
}
