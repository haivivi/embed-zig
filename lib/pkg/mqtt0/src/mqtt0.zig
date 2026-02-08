//! mqtt0 — MQTT 3.1.1 & 5.0 Client and Broker
//!
//! A lightweight, QoS 0 MQTT implementation with ServeMux pattern.
//! Supports both MQTT 3.1.1 (v4) and MQTT 5.0 (v5) protocols.
//! Generic over transport — works with TCP, TLS, or any read/write interface.
//!
//! ## Client Example
//!
//! ```zig
//! const mqtt0 = @import("mqtt0");
//!
//! var mux = try mqtt0.Mux.init(allocator);
//! defer mux.deinit();
//! try mux.handleFn("device/+/state", handleState);
//!
//! var client = try mqtt0.Client(Socket).init(&socket, &mux, .{
//!     .client_id = "device-001",
//!     .protocol_version = .v5,
//! });
//! defer client.deinit();
//!
//! try client.subscribe(&.{"device/+/state"});
//! try client.publish("device/001/online", "1");
//! try client.readLoop();
//! ```
//!
//! ## Broker Example
//!
//! ```zig
//! var mux = try mqtt0.Mux.init(allocator);
//! try mux.handleFn("device/#", handleAll);
//!
//! var broker = try mqtt0.Broker(Socket).init(allocator, mux.handler(), .{});
//! defer broker.deinit();
//!
//! // User controls accept loop:
//! while (try listener.accept()) |conn| {
//!     spawn(broker.serveConn, .{conn});
//! }
//! ```

// Re-export core types
pub const packet = @import("packet.zig");
pub const Message = packet.Message;
pub const ProtocolVersion = packet.ProtocolVersion;
pub const PacketType = packet.PacketType;
pub const QoS = packet.QoS;
pub const ReasonCode = packet.ReasonCode;
pub const ConnectReturnCode = packet.ConnectReturnCode;
pub const PacketBuffer = packet.PacketBuffer;

// Protocol versions
pub const v4 = @import("v4.zig");
pub const v5 = @import("v5.zig");

// ServeMux and Handler
pub const mux = @import("mux.zig");
pub const Mux = mux.Mux;
pub const Handler = mux.Handler;

// Topic trie
pub const trie = @import("trie.zig");
pub const topicMatches = trie.topicMatches;

// Client
pub const client = @import("client.zig");
pub fn Client(comptime Transport: type) type {
    return client.Client(Transport);
}

// Broker
pub const broker = @import("broker.zig");
pub fn Broker(comptime Transport: type) type {
    return broker.Broker(Transport);
}
pub const Authenticator = broker.Authenticator;
pub const AllowAll = broker.AllowAll;
pub const ConnectCallback = broker.ConnectCallback;
pub const DisconnectCallback = broker.DisconnectCallback;

// Run all tests
test {
    _ = packet;
    _ = v4;
    _ = v5;
    _ = trie;
    _ = mux;
}
