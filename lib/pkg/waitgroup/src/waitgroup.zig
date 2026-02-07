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
//! var wg = WaitGroup.init();
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

        /// Initialize a new WaitGroup with counter = 0
        pub fn init() Self {
            return .{
                .mutex = Rt.Mutex.init(),
                .cond = Rt.Condition.init(),
                .counter = 0,
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
        pub fn go(self: *Self, name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Rt.Options) !void {
            self.add(1);
            errdefer self.done(); // rollback if spawn fails

            // We need to pass both the user func/ctx and the WaitGroup pointer.
            // Use a small wrapper struct allocated... but we can't use allocator here.
            // Instead, use a comptime closure trick with a static wrapper.
            //
            // For the wrapper, we store func+ctx+wg in a GoContext.
            // Since spawn is fire-and-forget (detached), we need the context to live
            // until the task runs. We use a pool of contexts.
            //
            // Simpler approach: use a single packed context via @ptrCast tricks.
            // But that's fragile. Let's use a static pool.
            //
            // Actually, the cleanest approach for freestanding: encode the WaitGroup
            // pointer and user ctx into a GoContext stored on the WaitGroup itself
            // using a bounded pool.

            // For now, use a simple approach: allocate GoContext on a global page allocator.
            // This works for both std and ESP (FreeRTOS has malloc).
            const go_ctx = GoContext.alloc() orelse {
                self.done(); // rollback
                return error.OutOfMemory;
            };
            go_ctx.* = .{
                .wg = self,
                .func = func,
                .ctx = ctx,
            };

            try Rt.spawn(name, goWrapper, @ptrCast(go_ctx), opts);
        }

        /// Context for go() wrapper
        const GoContext = struct {
            wg: *Self,
            func: TaskFn,
            ctx: ?*anyopaque,

            // Simple pool: fixed-size array of contexts.
            // Max concurrent go() calls = pool_size.
            const pool_size = 64;
            var pool: [pool_size]GoContext = undefined;
            var pool_used: [pool_size]std.atomic.Value(bool) = init: {
                var arr: [pool_size]std.atomic.Value(bool) = undefined;
                for (&arr) |*v| {
                    v.* = std.atomic.Value(bool).init(false);
                }
                break :init arr;
            };

            fn alloc() ?*GoContext {
                for (0..pool_size) |i| {
                    if (pool_used[i].cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                        return &pool[i];
                    }
                }
                return null;
            }

            fn free(self_ctx: *GoContext) void {
                const idx = (@intFromPtr(self_ctx) - @intFromPtr(&pool)) / @sizeOf(GoContext);
                pool_used[idx].store(false, .release);
            }
        };

        fn goWrapper(raw_ctx: ?*anyopaque) void {
            const go_ctx: *GoContext = @ptrCast(@alignCast(raw_ctx));
            const wg = go_ctx.wg;
            const func = go_ctx.func;
            const ctx = go_ctx.ctx;
            GoContext.free(go_ctx);

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
    var wg = WG.init();
    defer wg.deinit();

    // Should not block
    wg.wait();
}

test "WaitGroup manual add/done" {
    const WG = WaitGroup(TestRt);
    var wg = WG.init();
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
    var wg = WG.init();
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
    var wg = WG.init();
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
