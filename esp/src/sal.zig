//! ESP SAL - System Abstraction Layer Implementation
//!
//! FreeRTOS-based implementation of the SAL interface.
//!
//! Usage:
//!   const esp = @import("esp");
//!   const sal = esp.sal;
//!   const heap = esp.heap;
//!
//!   // Thread with PSRAM stack
//!   const result = try sal.thread.go(heap.psram, "worker", myFn, null, .{
//!       .stack_size = 65536,
//!   });
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

pub const thread = @import("sal/thread.zig");
pub const sync = @import("sal/sync.zig");
pub const time = @import("sal/time.zig");

// Re-exports for convenience
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;

pub const sleepMs = time.sleepMs;
pub const nowUs = time.nowUs;
pub const nowMs = time.nowMs;
pub const Deadline = time.Deadline;
pub const Stopwatch = time.Stopwatch;

test {
    @import("std").testing.refAllDecls(@This());
}
