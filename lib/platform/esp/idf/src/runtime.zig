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

    pub const TimedWaitResult = enum { signaled, timed_out };

    /// Wait with timeout (nanoseconds).
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) TimedWaitResult {
        _ = self.waiters.fetchAdd(1, .acq_rel);
        const timeout_ms: u32 = @intCast(@min(timeout_ns / 1_000_000, std.math.maxInt(u32)));
        const ticks = if (timeout_ms > 0) timeout_ms / c.portTICK_PERIOD_MS else 1;
        mutex.unlock();
        const result = c.xSemaphoreTake(self.sem, ticks);
        mutex.lock();
        if (result != c.pdTRUE) {
            // Timed out — decrement waiter count
            _ = self.waiters.fetchSub(1, .acq_rel);
            return .timed_out;
        }
        return .signaled;
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
// Time — for Mux/Stream Runtime trait
// ============================================================================

/// Current time in milliseconds (from FreeRTOS tick count).
pub fn nowMs() u64 {
    return @as(u64, c.xTaskGetTickCount()) * c.portTICK_PERIOD_MS;
}

/// Sleep for the specified number of milliseconds.
pub fn sleepMs(ms: u32) void {
    c.vTaskDelay(ms / c.portTICK_PERIOD_MS);
}

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
const SpawnCtx = struct {
    func: TaskFn,
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
};

/// C-calling-convention wrapper that FreeRTOS calls.
/// Calls the Zig function, frees context, then deletes the task.
///
/// Note on stack cleanup: we do NOT free the stack here. The stack was
/// allocated by the caller and passed to xTaskCreateRestrictedPinnedToCore.
/// This is an ESP-IDF extension (idf_additions.h) that sets
/// ucStaticallyAllocated = tskDYNAMICALLY_ALLOCATED_STACK_AND_TCB,
/// so prvDeleteTCB will free BOTH the stack and TCB via vPortFreeStack/vPortFree
/// when vTaskDelete is called. (This differs from standard FreeRTOS
/// xTaskCreateRestricted which marks the stack as static and does NOT free it.)
fn spawnWrapper(raw_ctx: ?*anyopaque) callconv(.c) void {
    const spawn_ctx: *SpawnCtx = @ptrCast(@alignCast(raw_ctx));
    const func = spawn_ctx.func;
    const ctx = spawn_ctx.ctx;
    const allocator = spawn_ctx.allocator;
    allocator.destroy(spawn_ctx);

    // Run user function
    func(ctx);

    // Delete self (does not return).
    // Stack is freed automatically by FreeRTOS (see note above).
    c.vTaskDelete(null);
}

/// Spawn a detached FreeRTOS task.
///
/// Allocates stack from `opts.allocator` and creates the task via
/// xTaskCreateRestrictedPinnedToCore. The stack is automatically freed
/// by FreeRTOS when the task exits (via vTaskDelete).
pub fn spawn(name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Options) !void {
    const allocator = opts.allocator;

    // Allocate context (freed by spawnWrapper before user function runs)
    const spawn_ctx = try allocator.create(SpawnCtx);
    errdefer allocator.destroy(spawn_ctx);

    // Allocate stack (freed by FreeRTOS on vTaskDelete, see spawnWrapper note)
    const stack = try allocator.alloc(u8, opts.stack_size);
    errdefer allocator.free(stack);

    spawn_ctx.* = .{
        .func = func,
        .ctx = ctx,
        .allocator = allocator,
    };

    // Create FreeRTOS task with custom stack.
    // Uses ESP-IDF's xTaskCreateRestrictedPinnedToCore which takes ownership
    // of the stack buffer and frees it on task deletion.
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

// ============================================================================
// Thread — Joinable thread with FreeRTOS task + binary semaphore
// ============================================================================

/// Joinable thread handle — wraps FreeRTOS task with completion semaphore.
pub const Thread = struct {
    handle: c.TaskHandle_t,
    done_sem: c.SemaphoreHandle_t,

    /// Spawn configuration
    pub const SpawnConfig = struct {
        stack_size: usize = 8192,
        priority: u8 = 16,
        core: i8 = -1,
        allocator: std.mem.Allocator = heap.psram,
    };

    /// Context for joinable thread wrapper
    const ThreadCtx = struct {
        func_ptr: *const anyopaque,
        args_ptr: *const anyopaque,
        done_sem: c.SemaphoreHandle_t,
        allocator: std.mem.Allocator,
    };

    /// Thread wrapper that calls user function and signals completion
    fn threadWrapper(raw_ctx: ?*anyopaque) callconv(.c) void {
        const thread_ctx: *ThreadCtx = @ptrCast(@alignCast(raw_ctx));
        const done_sem = thread_ctx.done_sem;
        const allocator = thread_ctx.allocator;
        
        // Extract function pointer and args
        const func_ptr = thread_ctx.func_ptr;
        const args_ptr = thread_ctx.args_ptr;
        
        // Free context
        allocator.destroy(thread_ctx);
        
        // Call user function (type-erased, will be cast back by spawn)
        // This is safe because spawn() stores the correct types
        const FnType = *const fn (*const anyopaque) void;
        const func: FnType = @ptrCast(func_ptr);
        func(args_ptr);
        
        // Signal completion
        _ = c.xSemaphoreGive(done_sem);
        
        // Delete self (stack freed by FreeRTOS)
        c.vTaskDelete(null);
    }

    /// Spawn a joinable thread
    pub fn spawn(config: SpawnConfig, comptime func: anytype, args: anytype) !Thread {
        const allocator = config.allocator;
        
        // Create binary semaphore for join
        const done_sem = c.xSemaphoreCreateBinary();
        if (done_sem == null) return error.OutOfMemory;
        errdefer c.vSemaphoreDelete(done_sem);
        
        // Allocate context
        const thread_ctx = try allocator.create(ThreadCtx);
        errdefer allocator.destroy(thread_ctx);
        
        // Allocate stack
        const stack = try allocator.alloc(u8, config.stack_size);
        errdefer allocator.free(stack);
        
        // Store function and args (type-erased)
        const ArgsType = @TypeOf(args);
        const args_copy = try allocator.create(ArgsType);
        errdefer allocator.destroy(args_copy);
        args_copy.* = args;
        
        // Wrapper function to call user function with correct types
        const Wrapper = struct {
            fn call(args_ptr: *const anyopaque) void {
                const typed_args: *const ArgsType = @ptrCast(@alignCast(args_ptr));
                @call(.auto, func, typed_args.*);
            }
        };
        
        thread_ctx.* = .{
            .func_ptr = @ptrCast(&Wrapper.call),
            .args_ptr = @ptrCast(args_copy),
            .done_sem = done_sem,
            .allocator = allocator,
        };
        
        // Create FreeRTOS task
        var task_params: c.TaskParameters_t = std.mem.zeroes(c.TaskParameters_t);
        task_params.pvTaskCode = threadWrapper;
        task_params.pcName = "thread";
        task_params.usStackDepth = config.stack_size / @sizeOf(c.StackType_t);
        task_params.puxStackBuffer = @ptrCast(@alignCast(stack.ptr));
        task_params.pvParameters = thread_ctx;
        task_params.uxPriority = config.priority;
        
        var handle: c.TaskHandle_t = null;
        const core_id: c.BaseType_t = if (config.core < 0) c.tskNO_AFFINITY else config.core;
        const result = c.xTaskCreateRestrictedPinnedToCore(&task_params, &handle, core_id);
        
        if (result != c.pdPASS) {
            allocator.destroy(args_copy);
            allocator.destroy(thread_ctx);
            allocator.free(stack);
            c.vSemaphoreDelete(done_sem);
            return error.SpawnFailed;
        }
        
        return Thread{
            .handle = handle,
            .done_sem = done_sem,
        };
    }

    /// Wait for thread to complete
    pub fn join(self: Thread) void {
        _ = c.xSemaphoreTake(self.done_sem, c.portMAX_DELAY);
        c.vSemaphoreDelete(self.done_sem);
    }

    /// Detach thread (release resources without waiting)
    pub fn detach(self: Thread) void {
        c.vSemaphoreDelete(self.done_sem);
    }
};

/// Get CPU core count
pub fn getCpuCount() !usize {
    // ESP32-S3 is dual-core, ESP32-C3 is single-core
    // For simplicity, return 2 (can be made configurable if needed)
    return 2;
}
