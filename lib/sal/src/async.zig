//! Async - Concurrent Task Primitives
//!
//! Go-style concurrency with fire-and-forget tasks and WaitGroup.
//!
//! Usage:
//!   const async_ = @import("sal").async_;
//!
//!   // Fire and forget - task runs independently
//!   try async_.go(allocator, "background", backgroundTask, null, .{});
//!
//!   // Wait for multiple tasks
//!   var wg = async_.WaitGroup.init();
//!   try wg.go(allocator, "task1", task1, &ctx1, .{});
//!   try wg.go(allocator, "task2", task2, &ctx2, .{});
//!   wg.wait(); // blocks until all tasks complete
//!
//! Platform implementations:
//!   - ESP32/FreeRTOS: FreeRTOS tasks + semaphores
//!   - std: std.Thread + std.Thread.Condition

const std = @import("std");

/// Task function signature
pub const TaskFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

/// Task creation options
pub const Options = struct {
    /// Stack size in bytes
    stack_size: u32 = 8192,
    /// Task priority (platform-specific range)
    priority: u8 = 16,
    /// CPU core affinity (-1 = any core)
    core: i8 = -1,
};

/// CancellationToken - signal for graceful task termination
///
/// Used to signal long-running tasks to exit. Pass it through the ctx
/// parameter and check periodically in the task loop.
///
/// Example:
///   const TaskCtx = struct {
///       token: *CancellationToken,
///       // ... other fields
///   };
///
///   fn longRunningTask(ctx_ptr: ?*anyopaque) callconv(.c) void {
///       const ctx: *TaskCtx = @ptrCast(@alignCast(ctx_ptr));
///       while (!ctx.token.isCancelled()) {
///           // do work
///           time.sleepMs(100);
///       }
///   }
///
///   var token = CancellationToken.init();
///   var ctx = TaskCtx{ .token = &token, ... };
///   try wg.go(allocator, "task", longRunningTask, &ctx, .{});
///
///   // Later, to stop:
///   token.cancel();
///   wg.wait();
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool),

    /// Initialize a new token (not cancelled)
    pub fn init() CancellationToken {
        return .{ .cancelled = std.atomic.Value(bool).init(false) };
    }

    /// Check if cancellation has been requested
    ///
    /// Call this periodically in long-running task loops.
    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.monotonic);
    }

    /// Request cancellation
    ///
    /// After calling this, isCancelled() will return true.
    /// Tasks should check and exit gracefully.
    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .monotonic);
    }

    /// Reset to non-cancelled state
    ///
    /// Allows reusing the token for another task cycle.
    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .monotonic);
    }
};

/// Fire and forget - spawn a task that runs independently
///
/// The task will execute asynchronously. There is no way to wait for
/// completion or get a result. Use WaitGroup if you need to wait.
///
/// Args:
///   - allocator: Used to allocate stack memory
///   - name: Task name for debugging
///   - func: Task entry function
///   - ctx: Context passed to func (can contain both input and output)
///   - options: Task configuration
pub fn go(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: TaskFn,
    ctx: ?*anyopaque,
    options: Options,
) !void {
    _ = allocator;
    _ = name;
    _ = func;
    _ = ctx;
    _ = options;
    @compileError("sal.async.go requires platform implementation");
}

/// WaitGroup - wait for a collection of tasks to complete
///
/// Similar to Go's sync.WaitGroup. Use `go()` method to spawn tasks
/// that automatically decrement the counter on completion.
///
/// Example:
///   var wg = WaitGroup.init();
///   defer wg.deinit();
///
///   try wg.go(allocator, "task1", task1, &ctx1, .{});
///   try wg.go(allocator, "task2", task2, &ctx2, .{});
///
///   wg.wait(); // blocks until both tasks complete
///   // Now ctx1 and ctx2 contain results
pub const WaitGroup = struct {
    /// Platform-specific implementation data
    impl: *anyopaque,

    /// Initialize a new WaitGroup
    pub fn init() WaitGroup {
        @compileError("sal.async.WaitGroup.init requires platform implementation");
    }

    /// Release WaitGroup resources
    pub fn deinit(self: *WaitGroup) void {
        _ = self;
        @compileError("sal.async.WaitGroup.deinit requires platform implementation");
    }

    /// Add to the counter
    ///
    /// Call before spawning tasks if using manual management.
    /// Not needed when using `go()` method.
    pub fn add(self: *WaitGroup, delta: i32) void {
        _ = self;
        _ = delta;
        @compileError("sal.async.WaitGroup.add requires platform implementation");
    }

    /// Decrement the counter
    ///
    /// Call when a task completes if using manual management.
    /// Not needed when using `go()` method.
    pub fn done(self: *WaitGroup) void {
        _ = self;
        @compileError("sal.async.WaitGroup.done requires platform implementation");
    }

    /// Block until counter reaches zero
    pub fn wait(self: *WaitGroup) void {
        _ = self;
        @compileError("sal.async.WaitGroup.wait requires platform implementation");
    }

    /// Spawn a task that automatically calls done() on completion
    ///
    /// This is the recommended way to use WaitGroup. The counter is
    /// automatically incremented when the task starts and decremented
    /// when it completes.
    pub fn go(
        self: *WaitGroup,
        allocator: std.mem.Allocator,
        name: [:0]const u8,
        func: TaskFn,
        ctx: ?*anyopaque,
        options: Options,
    ) !void {
        _ = self;
        _ = allocator;
        _ = name;
        _ = func;
        _ = ctx;
        _ = options;
        @compileError("sal.async.WaitGroup.go requires platform implementation");
    }
};
