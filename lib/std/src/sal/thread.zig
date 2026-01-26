//! SAL Thread Implementation - Zig std
//!
//! Implements sal.thread interface using std.Thread.

const std = @import("std");

/// Task function signature
pub const TaskFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

/// Task creation options
pub const Options = struct {
    /// Stack size in bytes (ignored on std, OS manages stack)
    stack_size: u32 = 8192,
    /// Task priority (ignored on std)
    priority: u8 = 16,
    /// CPU core affinity (ignored on std)
    core: i8 = -1,
};

/// Task handle
pub const Handle = struct {
    thread: std.Thread,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Handle) void {
        _ = self;
        // std.Thread is detached, nothing to clean up
    }

    /// Wait for thread to complete
    pub fn join(self: *Handle) void {
        self.thread.join();
    }
};

/// Context for thread wrapper
const ThreadContext = struct {
    func: TaskFn,
    ctx: ?*anyopaque,
};

/// Wrapper to convert std.Thread function signature
fn threadWrapper(context: *ThreadContext) void {
    context.func(context.ctx);
}

/// Spawn a new thread
pub fn spawn(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: TaskFn,
    ctx: ?*anyopaque,
    options: Options,
) !Handle {
    _ = name;
    _ = options;

    // Allocate context on heap so it lives past this function
    const thread_ctx = try allocator.create(ThreadContext);
    thread_ctx.* = .{
        .func = func,
        .ctx = ctx,
    };

    const thread = try std.Thread.spawn(.{}, threadWrapperOwned, .{ allocator, thread_ctx });

    return Handle{
        .thread = thread,
        .allocator = allocator,
    };
}

/// Spawn a detached thread (fire and forget, no need to join)
pub fn spawnDetached(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    func: TaskFn,
    ctx: ?*anyopaque,
    options: Options,
) !void {
    _ = name;
    _ = options;

    // Allocate context on heap so it lives past this function
    const thread_ctx = try allocator.create(ThreadContext);
    thread_ctx.* = .{
        .func = func,
        .ctx = ctx,
    };

    const thread = try std.Thread.spawn(.{}, threadWrapperOwned, .{ allocator, thread_ctx });
    thread.detach();
}

/// Wrapper that owns and frees the context
fn threadWrapperOwned(allocator: std.mem.Allocator, context: *ThreadContext) void {
    defer allocator.destroy(context);
    context.func(context.ctx);
}

/// Yield execution to other threads
pub fn yield() void {
    std.Thread.yield();
}

test "spawn and join" {
    const allocator = std.testing.allocator;

    var called: bool = false;

    const TestFn = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx));
            ptr.* = true;
        }
    };

    var handle = try spawn(allocator, "test", TestFn.run, &called, .{});
    handle.join();

    try std.testing.expect(called);
}
