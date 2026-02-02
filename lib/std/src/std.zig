//! std-sal - SAL Implementation using Zig Standard Library
//!
//! Platform-independent implementation of the SAL interface using
//! std.Thread, std.posix, and std.crypto.tls.
//!
//! Usage:
//!   const sal = @import("std_sal").sal;
//!
//!   // Async - fire and forget
//!   try sal.async_.go(allocator, "worker", myFn, null, .{});
//!
//!   // Async - wait for multiple tasks
//!   var wg = sal.async_.WaitGroup.init(allocator);
//!   try wg.go(allocator, "task1", task1, &ctx, .{});
//!   wg.wait();
//!
//!   // Socket
//!   var sock = try sal.socket.tcp();
//!   defer sock.close();
//!   try sock.connect(.{ .ipv4 = .{ 93, 184, 216, 34 } }, 80);
//!
//!   // Sync
//!   var mutex = sal.sync.Mutex.init();
//!   mutex.lock();
//!   mutex.unlock();

// SAL modules
pub const async_ = @import("sal/async.zig");
pub const thread = @import("sal/thread.zig");
pub const time = @import("sal/time.zig");
pub const sync = @import("sal/sync.zig");
pub const socket = @import("sal/socket.zig");
pub const tls = @import("sal/tls.zig");
pub const queue = @import("sal/queue.zig");

// Convenience type re-exports
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;
pub const Socket = socket.Socket;
pub const WaitGroup = async_.WaitGroup;
pub const Queue = queue.Queue;

// Legacy sal namespace for backwards compatibility
pub const sal = struct {
    pub const async_ = @import("sal/async.zig");
    pub const thread = @import("sal/thread.zig");
    pub const time = @import("sal/time.zig");
    pub const sync = @import("sal/sync.zig");
    pub const socket = @import("sal/socket.zig");
    pub const tls = @import("sal/tls.zig");
    pub const queue = @import("sal/queue.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
}
