//! macOS Implementation Module
//!
//! Provides trait/hal implementations for macOS using std.
//! Note: For crypto, use lib/crypto directly (std.crypto based).

pub const socket = @import("socket.zig");
pub const time = @import("time.zig");

pub const Socket = socket.Socket;
