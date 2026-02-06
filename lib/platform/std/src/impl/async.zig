//! SAL Async Implementation - Zig std
//!
//! Implements sal.async interface using std.Thread.

const std = @import("std");
const thread = @import("thread.zig");

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
    // Spawn detached thread - runs independently, no need to join
    try thread.spawnDetached(allocator, name, func, ctx, .{
        .stack_size = options.stack_size,
        .priority = options.priority,
        .core = options.core,
    });
}

/// WaitGroup - wait for a collection of tasks to complete
///
/// Similar to Go's sync.WaitGroup.
pub const WaitGroup = struct {
    threads: std.ArrayListUnmanaged(std.Thread),
    allocator: std.mem.Allocator,

    /// Initialize a new WaitGroup
    pub fn init(allocator: std.mem.Allocator) WaitGroup {
        return .{
            .threads = .{},
            .allocator = allocator,
        };
    }

    /// Release WaitGroup resources
    pub fn deinit(self: *WaitGroup) void {
        self.threads.deinit(self.allocator);
    }

    /// Add to the counter (for manual management, not used with go())
    pub fn add(self: *WaitGroup, delta: i32) void {
        _ = self;
        _ = delta;
        // No-op for thread-join based implementation
    }

    /// Decrement the counter (for manual management, not used with go())
    pub fn done(self: *WaitGroup) void {
        _ = self;
        // No-op for thread-join based implementation
    }

    /// Block until all tasks complete (joins all threads)
    pub fn wait(self: *WaitGroup) void {
        for (self.threads.items) |t| {
            t.join();
        }
        self.threads.clearRetainingCapacity();
    }

    /// Context for wrapped task
    const GoContext = struct {
        func: TaskFn,
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
    };

    /// Wrapper that runs user function
    fn goWrapper(allocator: std.mem.Allocator, go_ctx: *GoContext) void {
        defer allocator.destroy(go_ctx);
        go_ctx.func(go_ctx.ctx);
    }

    /// Spawn a task that will be joined in wait()
    pub fn go(
        self: *WaitGroup,
        allocator: std.mem.Allocator,
        name: [:0]const u8,
        func: TaskFn,
        ctx: ?*anyopaque,
        options: Options,
    ) !void {
        _ = name;
        _ = options;

        // Allocate context
        const go_ctx = try allocator.create(GoContext);
        go_ctx.* = .{
            .func = func,
            .ctx = ctx,
            .allocator = allocator,
        };

        // Spawn thread
        const t = try std.Thread.spawn(.{}, goWrapper, .{ allocator, go_ctx });

        // Track thread for join in wait()
        try self.threads.append(self.allocator, t);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WaitGroup empty wait" {
    const allocator = std.testing.allocator;
    var wg = WaitGroup.init(allocator);
    defer wg.deinit();

    // Test that wait returns immediately when no tasks
    wg.wait(); // Should not block
}

test "WaitGroup single task" {
    const allocator = std.testing.allocator;

    var result: i32 = 0;

    const TestFn = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const ptr: *i32 = @ptrCast(@alignCast(ctx));
            ptr.* = 42;
        }
    };

    var wg = WaitGroup.init(allocator);
    defer wg.deinit();

    try wg.go(allocator, "task1", TestFn.run, &result, .{});
    wg.wait();

    try std.testing.expectEqual(@as(i32, 42), result);
}

test "WaitGroup multiple tasks" {
    const allocator = std.testing.allocator;

    var results: [3]i32 = .{ 0, 0, 0 };

    const TestFn = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const ptr: *i32 = @ptrCast(@alignCast(ctx));
            ptr.* = 42;
        }
    };

    var wg = WaitGroup.init(allocator);
    defer wg.deinit();

    try wg.go(allocator, "task1", TestFn.run, &results[0], .{});
    try wg.go(allocator, "task2", TestFn.run, &results[1], .{});
    try wg.go(allocator, "task3", TestFn.run, &results[2], .{});
    wg.wait();

    try std.testing.expectEqual(@as(i32, 42), results[0]);
    try std.testing.expectEqual(@as(i32, 42), results[1]);
    try std.testing.expectEqual(@as(i32, 42), results[2]);
}

test "CancellationToken basic" {
    var token = CancellationToken.init();

    // Initially not cancelled
    try std.testing.expect(!token.isCancelled());

    // After cancel, should be cancelled
    token.cancel();
    try std.testing.expect(token.isCancelled());

    // After reset, should not be cancelled
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "CancellationToken with task" {
    const allocator = std.testing.allocator;
    const time = @import("time.zig");

    const TaskCtx = struct {
        token: *CancellationToken,
        iterations: u32,
    };

    const TestFn = struct {
        fn run(ctx_ptr: ?*anyopaque) callconv(.c) void {
            const ctx: *TaskCtx = @ptrCast(@alignCast(ctx_ptr));
            while (!ctx.token.isCancelled()) {
                ctx.iterations += 1;
                time.sleepMs(10);
            }
        }
    };

    var token = CancellationToken.init();
    var ctx = TaskCtx{
        .token = &token,
        .iterations = 0,
    };

    var wg = WaitGroup.init(allocator);
    defer wg.deinit();

    try wg.go(allocator, "loop", TestFn.run, &ctx, .{});

    // Let it run for a bit
    time.sleepMs(50);

    // Cancel and wait
    token.cancel();
    wg.wait();

    // Should have done some iterations
    try std.testing.expect(ctx.iterations > 0);
}
