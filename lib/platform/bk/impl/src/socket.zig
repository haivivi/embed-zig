//! Socket Implementation for BK7258
//!
//! Re-exports armino socket which already matches the trait.socket interface.

const armino = @import("../../armino/src/armino.zig");

pub const Socket = armino.socket.Socket;
