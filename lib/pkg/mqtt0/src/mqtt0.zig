//! mqtt0 — Async MQTT 5.0 & 3.1.1 Client and Broker
//!
//! A lightweight MQTT implementation for embedded systems and servers.
//!
//! Features:
//! - MQTT 3.1.1 (v4) and MQTT 5.0 (v5) support
//! - QoS 0 only (fire and forget)
//! - Topic Alias support (v5)
//! - Zero dynamic allocation (uses caller-provided buffers)
//! - Generic over socket, log, time types (freestanding compatible)
//! - Comptime Mux for zero-overhead topic routing
//! - Topic Trie with MQTT wildcard matching (+, #)
//!
//! ## Components
//!
//! - `packet` — Shared encoding primitives
//! - `v4` — MQTT 3.1.1 packet codec
//! - `v5` — MQTT 5.0 packet codec
//! - `trie` — Topic pattern trie (wildcard matching)
//! - `mux` — Topic→handler dispatch (comptime + runtime)
//! - `client` — Async MQTT client
//! - `broker` — Network MQTT broker

// Core types
pub const packet = @import("packet.zig");
pub const v4 = @import("v4.zig");
// pub const v5 = @import("v5.zig");
// pub const trie = @import("trie.zig");
// pub const mux = @import("mux.zig");
// pub const client = @import("client.zig");
// pub const broker = @import("broker.zig");

// Re-export common types
pub const PacketType = packet.PacketType;
pub const QoS = packet.QoS;
pub const ReasonCode = packet.ReasonCode;
pub const ConnectReturnCode = packet.ConnectReturnCode;
pub const ProtocolVersion = packet.ProtocolVersion;
pub const ConnectConfig = packet.ConnectConfig;
pub const PublishOptions = packet.PublishOptions;
pub const Message = packet.Message;
pub const Handler = packet.Handler;
pub const handlerFn = packet.handlerFn;
pub const Error = packet.Error;
pub const detectProtocolVersion = packet.detectProtocolVersion;

test {
    _ = packet;
    _ = v4;
}
