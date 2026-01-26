//! ESP SAL - System Abstraction Layer Implementation
//!
//! FreeRTOS-based implementation of the SAL interface.
//!
//! Usage:
//!   const esp = @import("esp");
//!   const sal = esp.sal;
//!   const heap = esp.heap;
//!
//!   // Async - fire and forget
//!   try sal.async_.go(heap.psram, "worker", myFn, null, .{});
//!
//!   // Async - wait for multiple tasks
//!   var wg = sal.async_.WaitGroup.init(heap.psram);
//!   try wg.go(heap.psram, "task1", task1, &ctx, .{ .stack_size = 65536 });
//!   wg.wait();
//!
//!   // Mutex
//!   var mutex = sal.Mutex.init();
//!   defer mutex.deinit();
//!   {
//!       const held = mutex.acquire();
//!       defer held.release();
//!       // critical section
//!   }
//!
//!   // Semaphore
//!   var sem = sal.Semaphore.initBinary();
//!   sem.signal();
//!   sem.wait();

pub const async_ = @import("sal/async.zig");
pub const socket = @import("sal/socket.zig");
pub const Socket = socket.Socket;
pub const Address = socket.Address;
pub const Ipv4Address = socket.Ipv4Address;
pub const sync = @import("sal/sync.zig");
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;
pub const thread = @import("sal/thread.zig");
pub const time = @import("sal/time.zig");
pub const sleepMs = time.sleepMs;
pub const nowUs = time.nowUs;
pub const nowMs = time.nowMs;
pub const Deadline = time.Deadline;
pub const Stopwatch = time.Stopwatch;
pub const tls = @import("sal/tls.zig");
pub const queue = @import("sal/queue.zig");
pub const Queue = queue.Queue;
pub const i2c = @import("sal/i2c.zig");
pub const I2c = i2c.I2c;
pub const pwm = @import("sal/pwm.zig");
pub const Pwm = pwm.Pwm;

// Log - wrapper around std.log (needs std_options.logFn in main.zig)
pub const log = struct {
    const std = @import("std");

    pub fn err(comptime fmt: []const u8, args: anytype) void {
        std.log.scoped(.app).err(fmt, args);
    }

    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        std.log.scoped(.app).warn(fmt, args);
    }

    pub fn info(comptime fmt: []const u8, args: anytype) void {
        std.log.scoped(.app).info(fmt, args);
    }

    pub fn debug(comptime fmt: []const u8, args: anytype) void {
        std.log.scoped(.app).debug(fmt, args);
    }
};

// Re-exports for convenience
// Socket exports
test {
    @import("std").testing.refAllDecls(@This());
}
