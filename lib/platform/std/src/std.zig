//! std-sal - SAL Implementation using Zig Standard Library
//!
//! Platform-independent implementation of the SAL interface using
//! std.Thread, std.posix, and std.crypto.tls.
//!
//! Usage:
//!   const std_sal = @import("std_sal");
//!   const Rt = std_sal.runtime;  // Runtime for async packages
//!
//!   // Socket
//!   var sock = try std_sal.socket.tcp();
//!   defer sock.close();
//!
//!   // Sync
//!   var mutex = std_sal.sync.Mutex.init();
//!   mutex.lock();
//!   mutex.unlock();

// impl modules
pub const thread = @import("impl/thread.zig");
pub const time = @import("impl/time.zig");
pub const sync = @import("impl/sync.zig");
pub const socket = @import("impl/socket.zig");
pub const tls = @import("impl/tls.zig");
pub const runtime = @import("impl/runtime.zig");

// Convenience type re-exports
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;
pub const Socket = socket.Socket;

test {
    @import("std").testing.refAllDecls(@This());
}
