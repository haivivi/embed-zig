//! Zig Async Runtime Benchmarks
//!
//! Compares performance of different async runtime implementations:
//! - Thread-based (EventLoop)
//! - IO-based (kqueue/epoll)
//!
//! Run with: zig build async_bench

const std = @import("std");
const builtin = @import("builtin");

const thread_bench = @import("thread.zig");
const io_bench = if (builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd)
    @import("io.zig")
else
    struct {
        pub fn runAll(_: std.mem.Allocator) void {}
    };

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("Async Runtime Benchmarks (Zig)\n", .{});
    std.debug.print("==============================\n\n", .{});

    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run thread-based benchmarks
    thread_bench.runAll(allocator);

    // Run IO benchmarks (kqueue platforms only)
    io_bench.runAll(allocator);

    std.debug.print("\n", .{});
}
