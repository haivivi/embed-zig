//! Task — A type-erased callable unit of work
//!
//! Task wraps a pointer and a callback function, allowing any context
//! to be executed through a uniform interface. Used by TimerService
//! for delayed execution and by other scheduling primitives.
//!
//! ## Design
//!
//! - Zero allocation: Task itself doesn't allocate
//! - Type-safe: Uses comptime to create type-safe callbacks
//! - Platform agnostic: No OS dependencies
//!
//! ## Usage
//!
//! ```zig
//! const MyContext = struct {
//!     value: u32,
//!     pub fn execute(self: *MyContext) void {
//!         // Do work with self.value
//!     }
//! };
//!
//! var ctx = MyContext{ .value = 42 };
//! const task = Task.init(MyContext, &ctx, MyContext.execute);
//! task.run();
//! ```

/// A type-erased callable unit of work.
pub const Task = struct {
    /// Opaque pointer to the context
    ptr: *anyopaque,
    /// Callback function invoked with the context pointer
    callback: *const fn (ptr: *anyopaque) void,

    /// Create a task from a typed context and method.
    pub fn init(
        comptime T: type,
        context: *T,
        comptime method: fn (*T) void,
    ) Task {
        return .{
            .ptr = @ptrCast(context),
            .callback = struct {
                fn wrapper(ptr: *anyopaque) void {
                    const ctx: *T = @ptrCast(@alignCast(ptr));
                    method(ctx);
                }
            }.wrapper,
        };
    }

    /// Create a task from a raw pointer and callback.
    pub fn initRaw(
        ptr: *anyopaque,
        callback: *const fn (ptr: *anyopaque) void,
    ) Task {
        return .{
            .ptr = ptr,
            .callback = callback,
        };
    }

    /// Execute the task.
    pub fn run(self: Task) void {
        self.callback(self.ptr);
    }

    /// A no-op task that does nothing when run.
    pub const noop: Task = .{
        .ptr = undefined,
        .callback = struct {
            fn noopCallback(_: *anyopaque) void {}
        }.noopCallback,
    };
};

/// Handle to a scheduled timer, used for cancellation.
pub const TimerHandle = struct {
    id: u64,

    /// A null handle representing no timer.
    pub const null_handle: TimerHandle = .{ .id = 0 };

    /// Check if this is a valid (non-null) handle.
    pub fn isValid(self: TimerHandle) bool {
        return self.id != 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "Task.init creates callable task" {
    const Context = struct {
        called: bool = false,
        value: u32 = 0,

        fn execute(self: *@This()) void {
            self.called = true;
            self.value = 42;
        }
    };

    var ctx = Context{};
    const task = Task.init(Context, &ctx, Context.execute);

    try std.testing.expect(!ctx.called);
    task.run();
    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(@as(u32, 42), ctx.value);
}

test "Task.noop does nothing" {
    Task.noop.run();
    Task.noop.run();
}

test "TimerHandle validity" {
    try std.testing.expect(!TimerHandle.null_handle.isValid());
    const valid = TimerHandle{ .id = 1 };
    try std.testing.expect(valid.isValid());
}
