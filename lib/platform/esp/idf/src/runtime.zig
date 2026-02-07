//! EspRuntime — Runtime implementation using FreeRTOS
//!
//! Provides Mutex, Condition, and spawn for cross-platform async packages
//! on ESP32. Uses FreeRTOS semaphores, counting semaphores, and task API.
//!
//! ## Usage
//!
//! ```zig
//! const idf = @import("idf");
//! const Rt = idf.runtime;
//!
//! const MyChannel = channel.Channel(u32, 16, Rt);
//! const MyWaitGroup = waitgroup.WaitGroup(Rt);
//! ```

const std = @import("std");
const heap = @import("heap.zig");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("freertos/semphr.h");
    @cInclude("freertos/idf_additions.h");
});

// ============================================================================
// Mutex — wraps FreeRTOS xSemaphoreCreateMutex
// ============================================================================

pub const Mutex = struct {
    handle: c.SemaphoreHandle_t,

    pub fn init() Mutex {
        return .{ .handle = c.xSemaphoreCreateMutex() };
    }

    pub fn deinit(self: *Mutex) void {
        if (self.handle != null) {
            c.vSemaphoreDelete(self.handle);
            self.handle = null;
        }
    }

    pub fn lock(self: *Mutex) void {
        _ = c.xSemaphoreTake(self.handle, c.portMAX_DELAY);
    }

    pub fn unlock(self: *Mutex) void {
        _ = c.xSemaphoreGive(self.handle);
    }
};

// ============================================================================
// Condition — FreeRTOS counting semaphore + atomic waiter count
// ============================================================================

/// Condition variable implemented with a FreeRTOS counting semaphore.
///
/// Safe when signal/broadcast is called with the associated mutex held,
/// which is the usage pattern in Channel and WaitGroup.
pub const Condition = struct {
    sem: c.SemaphoreHandle_t,
    waiters: std.atomic.Value(u32),

    pub const InitError = error{SemaphoreCreateFailed};

    pub fn init() Condition {
        const sem = c.xSemaphoreCreateCounting(64, 0);
        if (sem == null) @panic("Condition.init: xSemaphoreCreateCounting failed (out of memory)");
        return .{
            .sem = sem,
            .waiters = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Condition) void {
        if (self.sem != null) {
            c.vSemaphoreDelete(self.sem);
            self.sem = null;
        }
    }

    /// Atomically release mutex, wait for signal, re-acquire mutex.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = self.waiters.fetchAdd(1, .acq_rel);
        mutex.unlock();
        _ = c.xSemaphoreTake(self.sem, c.portMAX_DELAY);
        mutex.lock();
    }

    /// Wake one waiting thread.
    pub fn signal(self: *Condition) void {
        var current = self.waiters.load(.acquire);
        while (current > 0) {
            if (self.waiters.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |actual| {
                current = actual;
                continue;
            }
            _ = c.xSemaphoreGive(self.sem);
            break;
        }
    }

    /// Wake all waiting threads.
    pub fn broadcast(self: *Condition) void {
        var current = self.waiters.load(.acquire);
        while (current > 0) {
            if (self.waiters.cmpxchgWeak(current, 0, .acq_rel, .acquire)) |actual| {
                current = actual;
                continue;
            }
            while (current > 0) : (current -= 1) {
                _ = c.xSemaphoreGive(self.sem);
            }
            break;
        }
    }
};

// ============================================================================
// Spawn — FreeRTOS task creation
// ============================================================================

/// Task function signature (Zig calling convention)
pub const TaskFn = *const fn (?*anyopaque) void;

/// Task spawn options
pub const Options = struct {
    /// Stack size in bytes
    stack_size: u32 = 8192,
    /// Task priority (FreeRTOS: 0-24, higher = more priority)
    priority: u8 = 16,
    /// CPU core affinity (-1 = any core)
    core: i8 = -1,
    /// Allocator for stack and context (ESP needs explicit allocation)
    allocator: std.mem.Allocator = heap.psram,
};

/// Context for the C-calling-convention wrapper.
/// Stores everything needed to run the user function and clean up afterwards.
const SpawnCtx = struct {
    func: TaskFn,
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    stack: []u8,
};

/// Deferred stack cleanup: a task cannot safely free its own stack before
/// vTaskDelete (the stack is still in use). Instead, each exiting task
/// schedules its stack for cleanup, and the next spawn() call frees it.
/// Protected by a FreeRTOS mutex for thread safety.
var deferred_mutex: c.SemaphoreHandle_t = null;
const max_deferred = 8;
var deferred_stacks: [max_deferred]?[]u8 = .{null} ** max_deferred;
var deferred_allocs: [max_deferred]std.mem.Allocator = undefined;
var deferred_count: usize = 0;

fn deferredInit() void {
    if (deferred_mutex == null) {
        deferred_mutex = c.xSemaphoreCreateMutex();
    }
}

/// Schedule a stack to be freed by the next spawn() call.
fn deferStackFree(stack: []u8, allocator: std.mem.Allocator) void {
    _ = c.xSemaphoreTake(deferred_mutex, c.portMAX_DELAY);
    defer _ = c.xSemaphoreGive(deferred_mutex);

    if (deferred_count < max_deferred) {
        deferred_stacks[deferred_count] = stack;
        deferred_allocs[deferred_count] = allocator;
        deferred_count += 1;
    }
    // If full, leak (bounded: max 8 * stack_size). This should not
    // happen in practice since spawn() drains the list.
}

/// Free all deferred stacks. Called at the start of spawn().
fn drainDeferredStacks() void {
    _ = c.xSemaphoreTake(deferred_mutex, c.portMAX_DELAY);
    defer _ = c.xSemaphoreGive(deferred_mutex);

    for (0..deferred_count) |i| {
        if (deferred_stacks[i]) |stack| {
            deferred_allocs[i].free(stack);
            deferred_stacks[i] = null;
        }
    }
    deferred_count = 0;
}

/// C-calling-convention wrapper that FreeRTOS calls.
/// Calls the Zig function, schedules stack cleanup, then deletes the task.
fn spawnWrapper(raw_ctx: ?*anyopaque) callconv(.c) void {
    const spawn_ctx: *SpawnCtx = @ptrCast(@alignCast(raw_ctx));
    const func = spawn_ctx.func;
    const ctx = spawn_ctx.ctx;
    const allocator = spawn_ctx.allocator;
    const stack = spawn_ctx.stack;
    allocator.destroy(spawn_ctx);

    // Run user function
    func(ctx);

    // Cannot free our own stack (we're running on it).
    // Schedule it for deferred cleanup by the next spawn() call.
    deferStackFree(stack, allocator);

    // Delete self (does not return)
    c.vTaskDelete(null);
}

/// Spawn a detached FreeRTOS task.
///
/// Allocates stack from `opts.allocator`, creates the task, and detaches it.
/// The task will call `vTaskDelete(null)` after the function returns.
pub fn spawn(name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Options) !void {
    const allocator = opts.allocator;

    // Initialize deferred cleanup on first call
    deferredInit();

    // Free stacks from previously completed tasks
    drainDeferredStacks();

    // Allocate context
    const spawn_ctx = try allocator.create(SpawnCtx);
    errdefer allocator.destroy(spawn_ctx);

    // Allocate stack
    const stack = try allocator.alloc(u8, opts.stack_size);
    errdefer allocator.free(stack);

    spawn_ctx.* = .{
        .func = func,
        .ctx = ctx,
        .allocator = allocator,
        .stack = stack,
    };

    // Create FreeRTOS task with custom stack
    var task_params: c.TaskParameters_t = std.mem.zeroes(c.TaskParameters_t);
    task_params.pvTaskCode = spawnWrapper;
    task_params.pcName = name.ptr;
    task_params.usStackDepth = opts.stack_size / @sizeOf(c.StackType_t);
    task_params.puxStackBuffer = @ptrCast(@alignCast(stack.ptr));
    task_params.pvParameters = spawn_ctx;
    task_params.uxPriority = opts.priority;

    var handle: c.TaskHandle_t = null;
    const core_id: c.BaseType_t = if (opts.core < 0) c.tskNO_AFFINITY else opts.core;
    const result = c.xTaskCreateRestrictedPinnedToCore(&task_params, &handle, core_id);

    if (result != c.pdPASS) {
        allocator.destroy(spawn_ctx);
        allocator.free(stack);
        return error.SpawnFailed;
    }
}
