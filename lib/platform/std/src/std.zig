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
pub const time = @import("impl/time.zig");
pub const sync = @import("impl/sync.zig");
pub const socket = @import("impl/socket.zig");
pub const runtime = @import("impl/runtime.zig");
const builtin = @import("builtin");
const is_kqueue = builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd;
const is_epoll = builtin.os.tag == .linux;

/// Platform-specific I/O backend (kqueue on macOS/BSD, epoll on Linux).
/// Access the IOService type via `std_impl.kqueue_io.KqueueIO` or
/// `std_impl.epoll_io.EpollIO`, or use the unified `std_impl.IOService`.
pub const kqueue_io = if (is_kqueue) @import("impl/kqueue_io.zig") else struct {};
pub const epoll_io = if (is_epoll) @import("impl/epoll_io.zig") else struct {};

/// Unified IOService — resolves to the platform's native backend.
pub const IOService = if (is_kqueue)
    @import("impl/kqueue_io.zig").KqueueIO
else if (is_epoll)
    @import("impl/epoll_io.zig").EpollIO
else
    void;
pub const codec = struct {
    pub const opus = @import("impl/codec/opus.zig");
};

// Convenience type re-exports
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Event = sync.Event;
pub const Socket = socket.Socket;

test {
    @import("std").testing.refAllDecls(@This());
}
