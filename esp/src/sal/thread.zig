//! SAL Thread Implementation - FreeRTOS
//!
//! Implements sal.thread interface using FreeRTOS tasks with PSRAM stack support.

const std = @import("std");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("freertos/semphr.h");
    @cInclude("freertos/idf_additions.h");
    @cInclude("esp_heap_caps.h");
});

// ============================================================================
// Types (matching sal.thread interface)
// ============================================================================

/// Task function type (no return value)
pub const TaskFn = *const fn (?*anyopaque) callconv(.c) void;

/// Go-style task function type (returns result code)
pub const GoFn = *const fn (?*anyopaque) callconv(.c) i32;

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

/// Context for go-style task execution
const GoContext = struct {
    func: GoFn,
    arg: ?*anyopaque,
    result: i32,
    done_sem: c.SemaphoreHandle_t,
    stack_size: u32,
    name: [:0]const u8,
};

/// Wrapper function for go-style execution
fn goWrapper(ctx_ptr: ?*anyopaque) callconv(.c) void {
    const ctx: *GoContext = @ptrCast(@alignCast(ctx_ptr));

    // Execute the user function
    ctx.result = ctx.func(ctx.arg);

    // Log stack usage
    const high_water_mark = c.uxTaskGetStackHighWaterMark(null);
    const min_free_bytes = high_water_mark * @sizeOf(c.StackType_t);
    const max_used_bytes = ctx.stack_size - min_free_bytes;

    std.log.info("task '{s}' exit, stack used: {}/{} bytes (free: {})", .{
        ctx.name,
        max_used_bytes,
        ctx.stack_size,
        min_free_bytes,
    });

    // Signal completion
    _ = c.xSemaphoreGive(ctx.done_sem);

    // Delete self
    c.vTaskDelete(null);
}

/// Run a function on a new task and wait for completion (Go-style)
///
/// This is useful for running code that needs a large stack (e.g., HTTP
/// downloads with 32KB buffers) without affecting the main task stack.
///
/// Example:
///   const result = try sal.thread.go(psram, "http_test", httpTestFn, null, .{
///       .stack_size = 65536,  // 64KB stack in PSRAM
///   });
pub fn go(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: GoFn,
    arg: ?*anyopaque,
    options: Options,
) !i32 {
    // Create semaphore for completion notification
    const done_sem = c.xSemaphoreCreateBinary();
    if (done_sem == null) {
        return error.SemaphoreCreateFailed;
    }
    defer c.vSemaphoreDelete(done_sem);

    var ctx = GoContext{
        .func = func,
        .arg = arg,
        .result = -1,
        .done_sem = done_sem,
        .stack_size = options.stack_size,
        .name = name,
    };

    // Create task
    var handle = try spawn(allocator, name, goWrapper, &ctx, options);
    defer handle.deinit();

    // Wait for completion (blocks until task signals done)
    _ = c.xSemaphoreTake(done_sem, c.portMAX_DELAY);

    return ctx.result;
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
