//! Thread/Task Abstraction (Low-level)
//!
//! Provides low-level cross-platform task/thread management.
//! For most use cases, prefer `sal.async_` which provides higher-level
//! `go()` and `WaitGroup` primitives.
//!
//! Platform implementations should provide:
//!   - Task creation with custom stack allocation
//!
//! Example:
//!   const psram = esp.heap.psram;  // or std.heap.page_allocator
//!
//!   // Spawn async task
//!   var handle = try sal.thread.spawn(psram, "worker", workerFn, null, .{});
//!   defer handle.deinit();

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

/// Get current task/thread handle
pub fn current() ?*anyopaque {
    @compileError("sal.thread.current requires platform implementation");
}

/// Yield execution to other tasks
pub fn yield() void {
    @compileError("sal.thread.yield requires platform implementation");
}
