//! zgrnet - Noise Protocol based networking library.
//!
//! This module provides:
//! - `noise`: Pure Noise Protocol Framework implementation (generic over Crypto)
//! - `net`: Network layer with WireGuard-style connection management
//!
//! The Noise module is parameterized by a Crypto type that must provide:
//! - `Blake2s256`: BLAKE2s-256 hash
//! - `ChaCha20Poly1305`: ChaCha20-Poly1305 AEAD
//! - `X25519`: Curve25519 DH
//!
//! Usage:
//!   const zgrnet = @import("zgrnet");
//!   const Noise = zgrnet.noise.Protocol(MyCrypto);
//!   var hs = try Noise.HandshakeState.init(.{ ... });

const std = @import("std");

// Submodules
pub const noise = @import("noise/mod.zig");
pub const async_mod = @import("async/mod.zig");
pub const kcp_mod = @import("kcp/mod.zig");
pub const net = @import("net/mod.zig");
pub const relay_mod = @import("relay/mod.zig");
pub const host = @import("host/mod.zig");
pub const proxy_mod = @import("proxy/mod.zig");
pub const dns_mod = @import("dns/mod.zig");
pub const dnsmgr_mod = @import("dnsmgr/mod.zig");

// Re-export noise non-generic types for convenience
pub const Key = noise.Key;
pub const key_size = noise.key_size;
pub const tag_size = noise.tag_size;
pub const hash_size = noise.hash_size;
pub const Pattern = noise.Pattern;

// KCP multiplexing (re-export submodules)
pub const kcp = kcp_mod.kcp;
pub const stream = kcp_mod.stream;

// IO backend types (for UDP generic parameter)
pub const IOService = async_mod.IOService;
pub const KqueueIO = async_mod.KqueueIO;

// KCP types
pub const Kcp = kcp.Kcp;
pub const Frame = kcp.Frame;
pub const Cmd = kcp.Cmd;

// Stream/Mux types
pub const Stream = stream.Stream;
pub const StreamState = stream.StreamState;
pub const StreamError = stream.StreamError;
pub const Mux = stream.Mux;
pub const MuxConfig = stream.MuxConfig;

// Relay types
pub const relay = relay_mod;

// Host types
pub const Host = host.Host;
pub const TunDevice = host.TunDevice;
pub const IPAllocator = host.IPAllocator;
pub const HostError = host.HostError;
pub const HostConfig = host.Config;
pub const PeerConfig = host.PeerConfig;

test {
    std.testing.refAllDecls(@This());
    _ = noise;
    _ = net;
    _ = kcp_mod;
    _ = relay_mod;
    _ = host;
    _ = proxy_mod;
    _ = dns_mod;
    _ = dnsmgr_mod;
}
