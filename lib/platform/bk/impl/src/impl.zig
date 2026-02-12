//! BK7258 Implementations of trait and hal interfaces

// ============================================================================
// trait implementations
// ============================================================================

pub const socket = @import("socket.zig");
pub const Socket = socket.Socket;

pub const log = @import("log.zig");
pub const Log = log.Log;
pub const stdLogFn = log.stdLogFn;

pub const time = @import("time.zig");
pub const Time = time.Time;

pub const crypto = @import("crypto/suite.zig");

// ============================================================================
// hal implementations (Drivers)
// ============================================================================

pub const wifi = @import("wifi.zig");
pub const WifiDriver = wifi.WifiDriver;

pub const net = @import("net.zig");
pub const NetDriver = net.NetDriver;

pub const kvs = @import("kvs.zig");
pub const KvsDriver = kvs.KvsDriver;

pub const audio_system = @import("audio_system.zig");
