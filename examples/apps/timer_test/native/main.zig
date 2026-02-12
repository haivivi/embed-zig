//! Timer Test — std platform (software timer)
//!
//! Demonstrates lib/pkg/timer with software backend on desktop.
//! Run: cd examples/apps/timer_test/native && zig build run

const std = @import("std");
const timer_pkg = @import("async/timer");

const StdRt = @import("runtime");
const Timer = timer_pkg.TimerService(StdRt);
const TimerHandle = timer_pkg.TimerHandle;

fn printLog(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

// ============================================================================
// Test 1: Basic schedule + advance
// ============================================================================

fn testBasicSchedule(ts: *Timer) void {
    printLog("=== Test 1: Basic schedule + advance ===", .{});

    var fired: bool = false;

    _ = ts.schedule(100, struct {
        fn cb(ctx: ?*anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = true;
        }
    }.cb, &fired);

    // Advance 50ms — should not fire
    _ = ts.advance(50);
    std.debug.assert(!fired);
    printLog("  50ms: not fired (correct)", .{});

    // Advance another 50ms — should fire
    const count = ts.advance(50);
    std.debug.assert(fired);
    std.debug.assert(count == 1);
    printLog("  100ms: fired! count={d} (correct)", .{count});
}

// ============================================================================
// Test 2: Cancel before fire
// ============================================================================

fn testCancel(ts: *Timer) void {
    printLog("=== Test 2: Cancel before fire ===", .{});

    var fired: bool = false;

    const handle = ts.schedule(100, struct {
        fn cb(ctx: ?*anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = true;
        }
    }.cb, &fired);

    std.debug.assert(handle.isValid());
    printLog("  scheduled, handle.id={d}", .{handle.id});

    ts.cancel(handle);
    printLog("  cancelled", .{});

    _ = ts.advance(200);
    std.debug.assert(!fired);
    printLog("  200ms: not fired (correct, was cancelled)", .{});
}

// ============================================================================
// Test 3: Multiple timers with ordering
// ============================================================================

fn testOrdering(ts: *Timer) void {
    printLog("=== Test 3: Multiple timers with ordering ===", .{});

    var order: [3]u8 = .{ 0, 0, 0 };
    var idx: u8 = 0;

    const Ctx = struct {
        order: *[3]u8,
        idx: *u8,
        label: u8,

        fn cb(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.order[self.idx.*] = self.label;
            self.idx.* += 1;
        }
    };

    var ctx_c = Ctx{ .order = &order, .idx = &idx, .label = 'C' };
    var ctx_a = Ctx{ .order = &order, .idx = &idx, .label = 'A' };
    var ctx_b = Ctx{ .order = &order, .idx = &idx, .label = 'B' };

    _ = ts.schedule(30, Ctx.cb, @ptrCast(&ctx_c));
    _ = ts.schedule(10, Ctx.cb, @ptrCast(&ctx_a));
    _ = ts.schedule(20, Ctx.cb, @ptrCast(&ctx_b));

    printLog("  scheduled: A@10ms, B@20ms, C@30ms", .{});

    // Advance 1ms at a time to get precise ordering
    var total: u64 = 0;
    while (total < 35) : (total += 1) {
        _ = ts.advance(1);
    }

    std.debug.assert(std.mem.eql(u8, &order, "ABC"));
    printLog("  fired order: {s} (correct)", .{&order});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("==========================================\n", .{});
    std.debug.print("  Timer Test (std platform, software)\n", .{});
    std.debug.print("==========================================\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ts = Timer.init(gpa.allocator());
    defer ts.deinit();

    testBasicSchedule(&ts);
    printLog("", .{});

    testCancel(&ts);
    printLog("", .{});

    testOrdering(&ts);
    printLog("", .{});

    std.debug.print("==========================================\n", .{});
    std.debug.print("  All tests passed!\n", .{});
    std.debug.print("==========================================\n", .{});
}
