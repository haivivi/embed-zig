//! WaitGroup — Wait for a collection of tasks to complete
//!
//! Go-style sync.WaitGroup with integrated `go()` for spawning tracked tasks.
//! Generic over Runtime Rt for cross-platform operation.
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("std_sal").runtime;
//! const WaitGroup = waitgroup.WaitGroup(Rt);
//!
//! var wg = WaitGroup.init(allocator);
//! defer wg.deinit();
//!
//! // Spawn tracked tasks
//! try wg.go("worker-1", myFn, &ctx1, .{});
//! try wg.go("worker-2", myFn, &ctx2, .{});
//!
//! // Wait for all to complete
//! wg.wait();
//! ```
//!
//! ## Manual add/done
//!
//! ```zig
//! wg.add(1);
//! defer wg.done();
//! // ... work ...
//! ```

const std = @import("std");
const trait = @import("trait");

/// Task function signature (matches spawner.TaskFn)
pub const TaskFn = trait.spawner.TaskFn;

/// WaitGroup — counter-based task completion tracker
///
/// - `Rt`: Runtime type providing Mutex, Condition, Options, spawn
pub fn WaitGroup(comptime Rt: type) type {
    // Validate Runtime at comptime
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
        trait.spawner.from(Rt);
    }

    return struct {
        const Self = @This();

        mutex: Rt.Mutex,
        cond: Rt.Condition,
        counter: i32,
        allocator: std.mem.Allocator,

        /// Initialize a new WaitGroup with counter = 0.
        /// The allocator is used internally by go() to allocate task context.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .mutex = Rt.Mutex.init(),
                .cond = Rt.Condition.init(),
                .counter = 0,
                .allocator = allocator,
            };
        }

        /// Release resources
        pub fn deinit(self: *Self) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        /// Add delta to the counter.
        /// Typically called before spawning a task.
        pub fn add(self: *Self, delta: i32) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.counter += delta;

            if (self.counter <= 0) {
                self.cond.broadcast();
            }
        }

        /// Decrement the counter by 1.
        /// Typically called at the end of a task (often via defer).
        pub fn done(self: *Self) void {
            self.add(-1);
        }

        /// Block until the counter reaches 0.
        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.counter > 0) {
                self.cond.wait(&self.mutex);
            }
        }

        /// Spawn a tracked task. Equivalent to:
        ///   wg.add(1)
        ///   Rt.spawn(name, wrappedFunc, ctx, opts)
        ///
        /// The task will automatically call wg.done() when it returns.
        /// GoContext is heap-allocated via the WaitGroup's allocator and
        /// freed by the wrapper after the user function completes.
        pub fn go(self: *Self, name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Rt.Options) !void {
            self.add(1);
            errdefer self.done(); // rollback counter if spawn fails

            const go_ctx = try self.allocator.create(GoContext);
            errdefer self.allocator.destroy(go_ctx); // free if spawn fails

            go_ctx.* = .{
                .wg = self,
                .func = func,
                .ctx = ctx,
                .allocator = self.allocator,
            };

            try Rt.spawn(name, goWrapper, @ptrCast(go_ctx), opts);
        }

        /// Context for go() wrapper. Heap-allocated, freed by goWrapper.
        const GoContext = struct {
            wg: *Self,
            func: TaskFn,
            ctx: ?*anyopaque,
            allocator: std.mem.Allocator,
        };

        fn goWrapper(raw_ctx: ?*anyopaque) void {
            const go_ctx: *GoContext = @ptrCast(@alignCast(raw_ctx));
            const wg = go_ctx.wg;
            const func = go_ctx.func;
            const ctx = go_ctx.ctx;
            const allocator = go_ctx.allocator;
            allocator.destroy(go_ctx);

            func(ctx);
            wg.done();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestRt = @import("runtime");

test "WaitGroup empty wait" {
    const WG = WaitGroup(TestRt);
    var wg = WG.init(std.testing.allocator);
    defer wg.deinit();

    // Should not block
    wg.wait();
}

test "WaitGroup manual add/done" {
    const WG = WaitGroup(TestRt);
    var wg = WG.init(std.testing.allocator);
    defer wg.deinit();

    var result: i32 = 0;

    wg.add(1);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(r: *i32, w: *WG) void {
            r.* = 42;
            w.done();
        }
    }.run, .{ &result, &wg });

    wg.wait();
    thread.detach();

    try std.testing.expectEqual(@as(i32, 42), result);
}

test "WaitGroup go single task" {
    const WG = WaitGroup(TestRt);
    var wg = WG.init(std.testing.allocator);
    defer wg.deinit();

    var result = std.atomic.Value(i32).init(0);

    try wg.go("task", struct {
        fn run(ctx: ?*anyopaque) void {
            const r: *std.atomic.Value(i32) = @ptrCast(@alignCast(ctx));
            r.store(42, .release);
        }
    }.run, &result, .{});

    wg.wait();

    try std.testing.expectEqual(@as(i32, 42), result.load(.acquire));
}

test "WaitGroup go multiple tasks" {
    const WG = WaitGroup(TestRt);
    var wg = WG.init(std.testing.allocator);
    defer wg.deinit();

    var counter = std.atomic.Value(u32).init(0);
    const num_tasks = 10;

    for (0..num_tasks) |_| {
        try wg.go("worker", struct {
            fn run(ctx: ?*anyopaque) void {
                const c: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
                _ = c.fetchAdd(1, .acq_rel);
            }
        }.run, &counter, .{});
    }

    wg.wait();

    try std.testing.expectEqual(@as(u32, num_tasks), counter.load(.acquire));
}
