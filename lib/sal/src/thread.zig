//! Thread/Task Abstraction
//!
//! Provides cross-platform task/thread management.
//!
//! Platform implementations should provide:
//!   - Task creation with custom stack allocation
//!   - Go-style synchronous task execution
//!
//! Example:
//!   const psram = esp.heap.psram;  // or std.heap.page_allocator
//!
//!   // Spawn async task
//!   var handle = try sal.thread.spawn(psram, "worker", workerFn, null, .{});
//!   defer handle.deinit();
//!
//!   // Go-style: run and wait
//!   const result = try sal.thread.go(psram, "task", taskFn, &arg, .{
//!       .stack_size = 65536,
//!   });

const std = @import("std");

/// Task function signature (no return value)
pub const TaskFn = *const fn (?*anyopaque) callconv(.c) void;

/// Go-style task function signature (returns result code)
pub const GoFn = *const fn (?*anyopaque) callconv(.c) i32;

/// Task creation options
pub const Options = struct {
    /// Stack size in bytes
    stack_size: u32 = 8192,
    /// Task priority (platform-specific range)
    priority: u8 = 16,
    /// CPU core affinity (-1 = any core)
    core: i8 = -1,
    /// Task name (for debugging)
    name: ?[:0]const u8 = null,
};

/// Task handle - opaque, platform-specific
pub const Handle = struct {
    /// Platform-specific implementation data
    impl: *anyopaque,
    /// Allocator used for stack (needed for cleanup)
    allocator: std.mem.Allocator,
    /// Stack memory (needed for cleanup)
    stack: []u8,

    /// Release task resources
    pub fn deinit(self: *Handle) void {
        self.allocator.free(self.stack);
    }
};

/// Spawn a new task/thread
///
/// The task runs asynchronously. Use `handle.deinit()` to clean up
/// after the task completes.
///
/// Args:
///   - allocator: Used to allocate stack memory
///   - name: Task name for debugging
///   - func: Task entry function
///   - arg: Argument passed to func
///   - options: Task configuration
///
/// Returns: Task handle for management
///
/// Note: Implementation is platform-specific. This interface defines
/// the contract that platform implementations must fulfill.
pub fn spawn(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: TaskFn,
    arg: ?*anyopaque,
    options: Options,
) !Handle {
    _ = allocator;
    _ = name;
    _ = func;
    _ = arg;
    _ = options;
    // Platform implementation required
    @compileError("sal.thread.spawn requires platform implementation");
}

/// Run a function on a new task and wait for completion (Go-style)
///
/// This is useful for running code that needs a large stack without
/// affecting the main task's stack.
///
/// Args:
///   - allocator: Used to allocate stack memory
///   - name: Task name for debugging
///   - func: Function to execute (returns i32)
///   - arg: Argument passed to func
///   - options: Task configuration
///
/// Returns: The return value from func
///
/// Example:
///   const result = try sal.thread.go(psram, "download", downloadFn, &ctx, .{
///       .stack_size = 65536,  // 64KB stack
///   });
pub fn go(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: GoFn,
    arg: ?*anyopaque,
    options: Options,
) !i32 {
    _ = allocator;
    _ = name;
    _ = func;
    _ = arg;
    _ = options;
    // Platform implementation required
    @compileError("sal.thread.go requires platform implementation");
}

/// Get current task/thread handle
pub fn current() ?*anyopaque {
    @compileError("sal.thread.current requires platform implementation");
}

/// Yield execution to other tasks
pub fn yield() void {
    @compileError("sal.thread.yield requires platform implementation");
}
