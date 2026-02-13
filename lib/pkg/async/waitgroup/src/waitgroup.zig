//! WaitGroup — Wait for a collection of tasks to complete
//!
//! Go-style sync.WaitGroup with integrated `go()` for spawning tracked tasks.
//! Generic over Runtime Rt for cross-platform operation.
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("std_impl").runtime;
//! const WaitGroup = waitgroup.WaitGroup(Rt);
//!
//! var wg = WaitGroup.init(allocator);
//! defer wg.deinit();
//!
//! // Spawn tracked tasks
//! try wg.go(worker, .{ctx1});
//! try wg.go(worker, .{ctx2});
//!
//! // Wait for all to complete
//! wg.wait();
//! ```

const std = @import("std");
const trait = @import("trait");

/// WaitGroup — counter-based task completion tracker
///
/// - `Rt`: Runtime type providing Thread, Mutex, Condition
pub fn WaitGroup(comptime Rt: type) type {
    // Validate Runtime at comptime
    comptime {
        trait.spawner.from(Rt);
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
    }

    return struct {
        const Self = @This();

        mutex: Rt.Mutex,
        cond: Rt.Condition,
        counter: i32,
        allocator: std.mem.Allocator,

        /// Initialize a new WaitGroup
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

        /// Add delta to counter (internal)
        fn add(self: *Self, delta: i32) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.counter += delta;
        }

        /// Decrement counter and signal if zero (internal)
        fn done(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.counter -= 1;
            if (self.counter == 0) {
                self.cond.broadcast();
            }
        }

        /// Spawn a tracked task
        pub fn go(self: *Self, comptime func: anytype, args: anytype) !void {
            self.add(1);
            
            const ArgsType = @TypeOf(args);
            const Wrapper = struct {
                fn run(wg: *Self, user_args: ArgsType) void {
                    defer wg.done();
                    @call(.auto, func, user_args);
                }
            };
            
            const thread = try Rt.Thread.spawn(.{}, Wrapper.run, .{self, args});
            thread.detach();  // detach immediately, threadWrapper cleans up sem
        }

        /// Spawn a tracked task with custom config
        pub fn goWithConfig(self: *Self, config: Rt.Thread.SpawnConfig, comptime func: anytype, args: anytype) !void {
            self.add(1);
            
            const ArgsType = @TypeOf(args);
            const Wrapper = struct {
                fn run(wg: *Self, user_args: ArgsType) void {
                    defer wg.done();
                    @call(.auto, func, user_args);
                }
            };
            
            const thread = try Rt.Thread.spawn(config, Wrapper.run, .{self, args});
            thread.detach();  // detach immediately, threadWrapper cleans up sem
        }

        /// Block until all spawned tasks complete
        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            while (self.counter > 0) {
                self.cond.wait(&self.mutex);
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestRt = @import("std_impl").runtime;

test "WaitGroup empty wait" {
    const WG = WaitGroup(TestRt);
    var wg = WG.init(std.testing.allocator);
    defer wg.deinit();

    // Should not block (no threads spawned)
    wg.wait();
}

test "WaitGroup go single task" {
    const WG = WaitGroup(TestRt);
    var wg = WG.init(std.testing.allocator);
    defer wg.deinit();

    var result = std.atomic.Value(i32).init(0);

    try wg.go(struct {
        fn run(r: *std.atomic.Value(i32)) void {
            r.store(42, .release);
        }
    }.run, .{&result});

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
        try wg.go(struct {
            fn run(c: *std.atomic.Value(u32)) void {
                _ = c.fetchAdd(1, .acq_rel);
            }
        }.run, .{&counter});
    }

    wg.wait();

    try std.testing.expectEqual(@as(u32, num_tasks), counter.load(.acquire));
}
