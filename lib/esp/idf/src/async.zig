//! FreeRTOS Async Task Utilities
//!
//! Provides go() fire-and-forget tasks and WaitGroup using FreeRTOS.

const std = @import("std");
const thread = @import("thread.zig");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("freertos/semphr.h");
    @cInclude("freertos/idf_additions.h");
});

/// Task function signature
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

/// CancellationToken - signal for graceful task termination
///
/// Used to signal long-running tasks to exit. Pass it through the ctx
/// parameter and check periodically in the task loop.
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool),

    /// Initialize a new token (not cancelled)
    pub fn init() CancellationToken {
        return .{ .cancelled = std.atomic.Value(bool).init(false) };
    }

    /// Check if cancellation has been requested
    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.monotonic);
    }

    /// Request cancellation
    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .monotonic);
    }

    /// Reset to non-cancelled state
    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .monotonic);
    }
};

/// Context for fire-and-forget task
const GoContext = struct {
    func: TaskFn,
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
};

/// Wrapper for fire-and-forget task
fn goWrapperFireAndForget(raw_ctx: ?*anyopaque) callconv(.c) void {
    const go_ctx: *GoContext = @ptrCast(@alignCast(raw_ctx));

    // Call user function
    go_ctx.func(go_ctx.ctx);

    // Free context (stack is freed by FreeRTOS via xTaskCreateRestrictedPinnedToCore)
    go_ctx.allocator.destroy(go_ctx);

    // Delete self
    c.vTaskDelete(null);
}

/// Fire and forget - spawn a task that runs independently
///
/// The task will execute asynchronously. There is no way to wait for
/// completion or get a result. Use WaitGroup if you need to wait.
pub fn go(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: TaskFn,
    ctx: ?*anyopaque,
    options: Options,
) !void {
    // Allocate context
    const go_ctx = try allocator.create(GoContext);
    errdefer allocator.destroy(go_ctx);

    // Allocate stack
    const stack = try allocator.alloc(u8, options.stack_size);
    errdefer allocator.free(stack);

    go_ctx.* = .{
        .func = func,
        .ctx = ctx,
        .allocator = allocator,
    };

    // Create FreeRTOS task
    var task_params: c.TaskParameters_t = std.mem.zeroes(c.TaskParameters_t);
    task_params.pvTaskCode = goWrapperFireAndForget;
    task_params.pcName = name.ptr;
    task_params.usStackDepth = options.stack_size / @sizeOf(c.StackType_t);
    task_params.puxStackBuffer = @ptrCast(@alignCast(stack.ptr));
    task_params.pvParameters = go_ctx;
    task_params.uxPriority = options.priority;

    var handle: c.TaskHandle_t = null;
    const core_id: c.BaseType_t = if (options.core < 0) c.tskNO_AFFINITY else options.core;
    const result = c.xTaskCreateRestrictedPinnedToCore(&task_params, &handle, core_id);

    if (result != c.pdPASS) {
        allocator.free(stack);
        allocator.destroy(go_ctx);
        return error.TaskCreateFailed;
    }
}

/// WaitGroup - wait for a collection of tasks to complete
///
/// Similar to Go's sync.WaitGroup.
pub const WaitGroup = struct {
    counter: std.atomic.Value(i32),
    done_sem: c.SemaphoreHandle_t,
    allocator: std.mem.Allocator,

    /// Initialize a new WaitGroup
    pub fn init(allocator: std.mem.Allocator) WaitGroup {
        return .{
            .counter = std.atomic.Value(i32).init(0),
            .done_sem = c.xSemaphoreCreateBinary(),
            .allocator = allocator,
        };
    }

    /// Release WaitGroup resources
    pub fn deinit(self: *WaitGroup) void {
        if (self.done_sem != null) {
            c.vSemaphoreDelete(self.done_sem);
            self.done_sem = null;
        }
    }

    /// Add to the counter
    pub fn add(self: *WaitGroup, delta: i32) void {
        _ = self.counter.fetchAdd(delta, .seq_cst);
    }

    /// Decrement the counter and signal if zero
    pub fn done(self: *WaitGroup) void {
        const prev = self.counter.fetchSub(1, .seq_cst);
        if (prev == 1) {
            // Counter reached zero, signal waiter
            _ = c.xSemaphoreGive(self.done_sem);
        }
    }

    /// Block until counter reaches zero
    pub fn wait(self: *WaitGroup) void {
        // If counter is already zero, return immediately
        if (self.counter.load(.seq_cst) <= 0) {
            return;
        }

        // Wait for signal
        _ = c.xSemaphoreTake(self.done_sem, c.portMAX_DELAY);
    }

    /// Context for wrapped task
    const WgGoContext = struct {
        wg: *WaitGroup,
        func: TaskFn,
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        stack_size: u32,
        name: [:0]const u8,
    };

    /// Wrapper that calls done() after task completes
    fn wgGoWrapper(raw_ctx: ?*anyopaque) callconv(.c) void {
        const go_ctx: *WgGoContext = @ptrCast(@alignCast(raw_ctx));

        // Call user function
        go_ctx.func(go_ctx.ctx);

        // Log stack usage
        const high_water_mark = c.uxTaskGetStackHighWaterMark(null);
        const min_free_bytes = high_water_mark * @sizeOf(c.StackType_t);
        const max_used_bytes = go_ctx.stack_size - min_free_bytes;

        std.log.info("task '{s}' exit, stack used: {}/{} bytes (free: {})", .{
            go_ctx.name,
            max_used_bytes,
            go_ctx.stack_size,
            min_free_bytes,
        });

        // Signal completion to WaitGroup
        go_ctx.wg.done();

        // Free context (stack is freed by FreeRTOS via xTaskCreateRestrictedPinnedToCore)
        go_ctx.allocator.destroy(go_ctx);

        // Delete self
        c.vTaskDelete(null);
    }

    /// Spawn a task that automatically calls done() on completion
    pub fn go(
        self: *WaitGroup,
        allocator: std.mem.Allocator,
        name: [:0]const u8,
        func: TaskFn,
        ctx: ?*anyopaque,
        options: Options,
    ) !void {
        // Allocate context
        const go_ctx = try allocator.create(WgGoContext);
        errdefer allocator.destroy(go_ctx);

        // Allocate stack
        const stack = try allocator.alloc(u8, options.stack_size);
        errdefer allocator.free(stack);

        go_ctx.* = .{
            .wg = self,
            .func = func,
            .ctx = ctx,
            .allocator = allocator,
            .stack_size = options.stack_size,
            .name = name,
        };

        // Increment counter before spawning
        self.add(1);

        // Create FreeRTOS task using xTaskCreateRestrictedPinnedToCore
        // This ESP-IDF extension takes ownership of the stack and will free it
        // when the task is deleted via vTaskDelete().
        var task_params: c.TaskParameters_t = std.mem.zeroes(c.TaskParameters_t);
        task_params.pvTaskCode = wgGoWrapper;
        task_params.pcName = name.ptr;
        task_params.usStackDepth = options.stack_size / @sizeOf(c.StackType_t);
        task_params.puxStackBuffer = @ptrCast(@alignCast(stack.ptr));
        task_params.pvParameters = go_ctx;
        task_params.uxPriority = options.priority;

        var handle: c.TaskHandle_t = null;
        const core_id: c.BaseType_t = if (options.core < 0) c.tskNO_AFFINITY else options.core;
        const result = c.xTaskCreateRestrictedPinnedToCore(&task_params, &handle, core_id);

        if (result != c.pdPASS) {
            self.done(); // Decrement on error
            allocator.free(stack);
            allocator.destroy(go_ctx);
            return error.TaskCreateFailed;
        }

        // Note: Stack is now owned by FreeRTOS and will be freed when task is deleted.
        // Context (go_ctx) will be freed in wgGoWrapper before vTaskDelete.
    }
};
