//! WebSocket Client — RFC 6455
//!
//! Cross-platform WebSocket client with TLS support via generic Socket parameter.
//! Designed for embedded (ESP32, BK7258) and server (macOS, Linux) environments.
//!
//! ## Example
//!
//! ```zig
//! const ws = @import("ws");
//!
//! var client = try ws.Client(Socket).init(allocator, &socket, .{
//!     .host = "echo.websocket.org",
//!     .path = "/",
//! });
//! defer client.deinit();
//!
//! try client.sendText("hello");
//! while (try client.recv()) |msg| {
//!     switch (msg.type) {
//!         .text => handleText(msg.payload),
//!         .binary => handleBinary(msg.payload),
//!         .ping => {},  // auto-pong
//!         .close => break,
//!     }
//! }
//! ```

pub const frame = @import("frame.zig");
pub const handshake = @import("handshake.zig");
pub const client = @import("client.zig");
pub const sha1 = @import("sha1.zig");
pub const base64 = @import("base64.zig");

pub const Frame = frame.Frame;
pub const FrameHeader = frame.FrameHeader;
pub const Opcode = frame.Opcode;
pub const Message = client.Message;
pub const MessageType = client.MessageType;

pub fn Client(comptime Socket: type) type {
    return client.Client(Socket);
}

test {
    _ = frame;
    _ = handshake;
    _ = client;
    _ = sha1;
    _ = base64;
}
