//! Task management with PSRAM stack allocation support
//!
//! This module provides FreeRTOS task creation with stack allocated from
//! PSRAM instead of IRAM, allowing larger stack sizes for memory-intensive
//! operations like HTTP downloads with large buffers.
//!
//! Key features:
//! - Create tasks with stack in PSRAM
//! - Go-style synchronous task execution (run and wait for completion)

const std = @import("std");

const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("freertos/semphr.h");
    @cInclude("freertos/idf_additions.h");
    @cInclude("esp_heap_caps.h");
});

pub const MALLOC_CAP_SPIRAM = c.MALLOC_CAP_SPIRAM;
pub const MALLOC_CAP_INTERNAL = c.MALLOC_CAP_INTERNAL;
pub const MALLOC_CAP_8BIT = c.MALLOC_CAP_8BIT;

/// Task priority levels
pub const Priority = struct {
    pub const background: c_uint = 4;
    pub const user: c_uint = 16;
    pub const system: c_uint = 24;
};

/// CPU core selection
pub const Core = struct {
    pub const irq: c_int = 0;
    pub const user: c_int = 1;
    pub const any: c_int = c.tskNO_AFFINITY;
};

/// Task function type
pub const TaskFn = *const fn (?*anyopaque) callconv(.c) void;

/// Go-style task function type (returns int result)
pub const GoFn = *const fn (?*anyopaque) callconv(.c) c_int;

/// Task handle wrapper
pub const TaskHandle = c.TaskHandle_t;

/// Task creation options
pub const TaskOptions = struct {
    stack_size: u32 = 8192,
    priority: c_uint = Priority.user,
    core: c_int = Core.user,
    /// Memory capabilities for stack allocation
    /// Default: PSRAM for larger stacks
    caps: u32 = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT,
};

/// Create a task with stack allocated from specified memory
///
/// Unlike standard xTaskCreate, this allocates the stack from PSRAM,
/// allowing much larger stack sizes (e.g., 32KB+ for HTTP buffers).
pub fn create(
    name: [*:0]const u8,
    func: TaskFn,
    arg: ?*anyopaque,
    options: TaskOptions,
) !TaskHandle {
    // Allocate stack from specified memory caps
    const stack = @as(?[*]c.StackType_t, @ptrCast(@alignCast(
        c.heap_caps_malloc(options.stack_size, options.caps),
    )));
    if (stack == null) {
        return error.OutOfMemory;
    }

    // Use ESP-IDF's xTaskCreateRestrictedPinnedToCore
    // This takes ownership of the stack and frees it when task is deleted
    var task_params: c.TaskParameters_t = std.mem.zeroes(c.TaskParameters_t);
    task_params.pvTaskCode = func;
    task_params.pcName = name;
    task_params.usStackDepth = options.stack_size / @sizeOf(c.StackType_t);
    task_params.puxStackBuffer = stack;
    task_params.pvParameters = arg;
    task_params.uxPriority = options.priority;

    var handle: TaskHandle = null;
    const result = c.xTaskCreateRestrictedPinnedToCore(&task_params, &handle, options.core);

    if (result != c.pdPASS) {
        c.heap_caps_free(stack);
        return error.TaskCreateFailed;
    }

    return handle;
}

/// Context for go-style task execution
const GoContext = struct {
    func: GoFn,
    arg: ?*anyopaque,
    result: c_int,
    done_sem: c.SemaphoreHandle_t,
    stack_size: u32,
    name: [*:0]const u8,
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
        std.mem.span(ctx.name),
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
/// downloads with 16KB buffers) without affecting the main task stack.
///
/// Example:
/// ```zig
/// const result = try task.go("http_download", downloadFunc, &my_arg, .{
///     .stack_size = 32768,  // 32KB stack in PSRAM
/// });
/// ```
pub fn go(
    name: [*:0]const u8,
    func: GoFn,
    arg: ?*anyopaque,
    options: TaskOptions,
) !c_int {
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
    _ = create(name, goWrapper, &ctx, options) catch |err| {
        return err;
    };

    // Wait for completion
    _ = c.xSemaphoreTake(done_sem, c.portMAX_DELAY);

    return ctx.result;
}

/// Run a function on a PSRAM stack task (convenience wrapper)
pub fn goPsram(
    name: [*:0]const u8,
    func: GoFn,
    arg: ?*anyopaque,
    stack_size: u32,
) !c_int {
    return go(name, func, arg, .{
        .stack_size = stack_size,
        .caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT,
    });
}

/// Delete current task
pub fn deleteSelf() void {
    c.vTaskDelete(null);
}

/// Delay current task
pub fn delay(ms: u32) void {
    c.vTaskDelay(ms / c.portTICK_PERIOD_MS);
}

/// Get current task handle
pub fn current() TaskHandle {
    return c.xTaskGetCurrentTaskHandle();
}

/// Get stack high water mark (minimum free stack ever)
pub fn getStackHighWaterMark(task: ?TaskHandle) u32 {
    return c.uxTaskGetStackHighWaterMark(task) * @sizeOf(c.StackType_t);
}
