//! SAL - System Abstraction Layer
//!
//! Cross-platform abstractions for OS primitives:
//! - Thread/Task management
//! - Synchronization (Mutex, Semaphore, Event)
//! - Time and delays
//!
//! Usage:
//!   const sal = @import("sal");
//!
//!   // Thread
//!   const result = try sal.thread.go(allocator, "worker", myFn, null, .{});
//!
//!   // Sync
//!   var mutex = sal.Mutex.init();
//!   defer mutex.deinit();
//!
//! Platform implementations:
//!   - ESP32/FreeRTOS: use with esp.heap.psram, esp.heap.iram allocators
//!   - POSIX: use with std.heap.page_allocator
//!

pub const thread = @import("thread.zig");
pub const sync = @import("sync.zig");
pub const time = @import("time.zig");

// Re-exports for convenience
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;

pub const spawn = thread.spawn;
pub const go = thread.go;

pub const sleep = time.sleep;
pub const sleepMs = time.sleepMs;

test {
    @import("std").testing.refAllDecls(@This());
}
