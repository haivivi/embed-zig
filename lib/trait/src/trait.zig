//! SAL - System Abstraction Layer
//!
//! Defines interface contracts for platform-independent SDK modules.
//! Each module provides an `is()` function to validate implementations at comptime.
//!
//! ## Interface Categories (POSIX-style)
//!
//! | Category | Module    | Methods                              | Used by         |
//! |----------|-----------|--------------------------------------|-----------------|
//! | socket   | socket.zig| tcp, udp, connect, send, recv, ...   | http, dns       |
//! | i2c      | i2c.zig   | write, writeRead                     | drivers         |
//! | time     | time.zig  | sleepMs, getTimeMs                   | apps, SDK       |
//! | log      | log.zig   | info, err, warn, debug               | apps, SDK       |
//! | rng      | rng.zig   | fill                                 | tls, crypto     |
//!
//! ## Usage Pattern
//!
//! ```zig
//! // In SDK module
//! pub fn HttpClient(comptime SocketImpl: type) type {
//!     sal.socket.is(SocketImpl);  // Validate interface
//!     // ...use SocketImpl directly...
//! }
//!
//! // In board.zig
//! sal.time.is(@This());
//! sal.log.is(@This());
//! pub fn sleepMs(ms: u32) void { ... }
//! pub fn info(comptime fmt: []const u8, args: anytype) void { ... }
//! ```
//!
//! ## Platform Implementations
//!
//! - ESP32: lib/esp/src/sal/
//! - Zig std: lib/std/src/sal/

// Interface contracts
pub const socket = @import("socket.zig");
pub const i2c = @import("i2c.zig");
pub const time = @import("time.zig");
pub const log = @import("log.zig");
pub const rng = @import("rng.zig");
pub const crypto = @import("crypto.zig");
pub const net = @import("net.zig");
pub const sync = @import("sync.zig");
pub const spawner = @import("spawner.zig");
pub const codec = @import("codec.zig");
pub const io = @import("io.zig");
pub const timer = @import("timer.zig");

// Socket helpers
pub const Ipv4Address = socket.Ipv4Address;
pub const parseIpv4 = socket.parseIpv4;

// Default implementations
pub const StdLogger = log.StdLogger;

// Default implementations
pub const StdRng = rng.StdRng;

// Run all interface tests
test {
    _ = socket;
    _ = i2c;
    _ = time;
    _ = log;
    _ = rng;
    _ = crypto;
    _ = net;
    _ = sync;
    _ = spawner;
    _ = codec;
    _ = io;
    _ = timer;
}
