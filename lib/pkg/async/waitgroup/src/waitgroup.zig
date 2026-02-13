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

/// WaitGroup — thread-based task completion tracker
///
/// - `Rt`: Runtime type providing Thread, getCpuCount
pub fn WaitGroup(comptime Rt: type) type {
    // Validate Runtime at comptime
    comptime {
        trait.spawner.from(Rt);
    }

    return struct {
        const Self = @This();

        threads: std.ArrayListUnmanaged(Rt.Thread),
        allocator: std.mem.Allocator,

        /// Initialize a new WaitGroup
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .threads = .{},
                .allocator = allocator,
            };
        }

        /// Release resources. Must call wait() first to ensure all threads complete.
        pub fn deinit(self: *Self) void {
            self.threads.deinit(self.allocator);
        }

        /// Spawn a tracked task
        pub fn go(self: *Self, comptime func: anytype, args: anytype) !void {
            const thread = try Rt.Thread.spawn(.{}, func, args);
            try self.threads.append(self.allocator, thread);
        }

        /// Spawn a tracked task with custom config
        pub fn goWithConfig(self: *Self, config: Rt.Thread.SpawnConfig, comptime func: anytype, args: anytype) !void {
            const thread = try Rt.Thread.spawn(config, func, args);
            try self.threads.append(self.allocator, thread);
        }

        /// Block until all spawned tasks complete
        pub fn wait(self: *Self) void {
            for (self.threads.items) |thread| {
                thread.join();
            }
            self.threads.clearRetainingCapacity();
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
