//! SAL - System Abstraction Layer
//!
//! Cross-platform abstractions for OS primitives:
//! - Async tasks (go, WaitGroup)
//! - Thread/Task management (low-level)
//! - Synchronization (Mutex, Semaphore, Event)
//! - Time and delays
//!
//! Usage:
//!   const sal = @import("sal");
//!
//!   // Async - fire and forget
//!   try sal.async_.go(allocator, "worker", myFn, null, .{});
//!
//!   // Async - wait for multiple tasks
//!   var wg = sal.async_.WaitGroup.init();
//!   try wg.go(allocator, "task1", task1, &ctx, .{});
//!   wg.wait();
//!
//!   // Sync
//!   var mutex = sal.Mutex.init();
//!   defer mutex.deinit();
//!
//! Platform implementations:
//!   - ESP32/FreeRTOS: use with esp.heap.psram, esp.heap.iram allocators
//!   - std: use with std.heap.page_allocator
//!

pub const async_ = @import("async.zig");
pub const thread = @import("thread.zig");
pub const sync = @import("sync.zig");
pub const time = @import("time.zig");
pub const socket = @import("socket.zig");
pub const tls = @import("tls.zig");
pub const queue = @import("queue.zig");
pub const i2c = @import("i2c.zig");
pub const log = @import("log.zig");

// Re-exports for convenience
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;
pub const Queue = queue.Queue;

pub const spawn = thread.spawn;

pub const sleep = time.sleep;
pub const sleepMs = time.sleepMs;

// Socket exports
pub const Socket = socket.Socket;
pub const Address = socket.Address;
pub const Ipv4Address = socket.Ipv4Address;

test {
    @import("std").testing.refAllDecls(@This());
}
