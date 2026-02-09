//! zgrnet - Noise Protocol based networking library.
//!
//! This module provides:
//! - `noise`: Pure Noise Protocol Framework implementation (generic over Crypto)
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
//!
//! NOTE: Higher-level modules (net, kcp, relay, host, dns, proxy) are not yet
//! genericized over Crypto. They will be updated incrementally.

const std = @import("std");

// Core module (fully genericized over Crypto)
pub const noise = @import("noise/mod.zig");

// Re-export noise non-generic types for convenience
pub const Key = noise.Key;
pub const key_size = noise.key_size;
pub const tag_size = noise.tag_size;
pub const hash_size = noise.hash_size;
pub const Pattern = noise.Pattern;

// TODO(zgrnet-mirror): Higher-level modules need Crypto genericization.
// Once done, uncomment and update these imports:
// pub const net = @import("net/mod.zig");
// pub const async_mod = @import("async/mod.zig");
// pub const kcp_mod = @import("kcp/mod.zig");
// pub const relay_mod = @import("relay/mod.zig");
// pub const host = @import("host/mod.zig");
// pub const proxy_mod = @import("proxy/mod.zig");
// pub const dns_mod = @import("dns/mod.zig");
// pub const dnsmgr_mod = @import("dnsmgr/mod.zig");

test {
    std.testing.refAllDecls(@This());
    _ = noise;
}
