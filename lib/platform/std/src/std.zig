//! std_impl - Trait implementations using Zig Standard Library
//!
//! Platform-independent implementation of trait interfaces using
//! std.Thread and std.posix.
//!
//! Usage:
//!   const std_impl = @import("std_impl");
//!   const Rt = std_impl.runtime;  // Runtime for async packages
//!
//!   // Socket
//!   var sock = try std_impl.socket.tcp();
//!   defer sock.close();
//!
//!   // Sync
//!   var mutex = std_impl.sync.Mutex.init();
//!   mutex.lock();
//!   mutex.unlock();

// impl modules
pub const thread = @import("impl/thread.zig");
pub const time = @import("impl/time.zig");
pub const sync = @import("impl/sync.zig");
pub const socket = @import("impl/socket.zig");
pub const runtime = @import("impl/runtime.zig");
pub const codec = @import("impl/codec.zig");

// Convenience type re-exports
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;
pub const Socket = socket.Socket;

test {
    @import("std").testing.refAllDecls(@This());
}
