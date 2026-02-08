//! GATT Client — Service Discovery + Read/Write/Subscribe
//!
//! Provides async APIs for interacting with a remote GATT server.
//! Each operation sends an ATT Request and blocks until the Response arrives.
//!
//! ## Design
//!
//! ```
//! App thread:           Host readLoop:
//!   client.read()         ATT Response arrives
//!     → send Request        → match to pending request
//!     → block on signal     → put response in channel
//!     ← wake + return       ← channel.send()
//! ```
//!
//! ATT serialization: only one Request in-flight per connection.
//! The client's Mutex ensures sequential access.
//!
//! ## Usage
//!
//! ```zig
//! var client = host.gattClient(conn_handle);
//!
//! // Read a characteristic
//! const data = try client.read(value_handle);
//!
//! // Write a characteristic (with response)
//! try client.write(value_handle, &payload);
//!
//! // Enable notifications (write CCCD)
//! try client.subscribe(cccd_handle);
//!
//! // Service discovery
//! var iter = try client.discoverServices();
//! while (iter.next()) |svc| { ... }
//! ```

const std = @import("std");
const att = @import("host/att/att.zig");
const l2cap = @import("host/l2cap/l2cap.zig");

// ============================================================================
// ATT Response (passed through completion channel)
// ============================================================================

/// Decoded ATT response for the pending request.
pub const AttResponse = struct {
    opcode: att.Opcode,
    data: [att.MAX_PDU_LEN]u8,
    len: usize,
    /// ATT error code (if error response)
    err: ?att.ErrorCode,

    pub fn payload(self: *const AttResponse) []const u8 {
        return self.data[0..self.len];
    }

    pub fn isError(self: *const AttResponse) bool {
        return self.err != null;
    }

    pub fn fromPdu(pdu: []const u8) AttResponse {
        var resp = AttResponse{
            .opcode = if (pdu.len > 0) @enumFromInt(pdu[0]) else .error_response,
            .data = undefined,
            .len = 0,
            .err = null,
        };

        if (pdu.len > 0) {
            // Check if it's an error response
            if (pdu[0] == @intFromEnum(att.Opcode.error_response) and pdu.len >= 5) {
                resp.err = @enumFromInt(pdu[4]);
            }

            // Copy response data (skip opcode for read/write responses)
            if (pdu.len > 1) {
                const payload_data = pdu[1..];
                const n = @min(payload_data.len, resp.data.len);
                @memcpy(resp.data[0..n], payload_data[0..n]);
                resp.len = n;
            }
        }

        return resp;
    }
};

// ============================================================================
// Service / Characteristic discovery results
// ============================================================================

pub const DiscoveredService = struct {
    start_handle: u16,
    end_handle: u16,
    uuid: att.UUID,
};

pub const DiscoveredCharacteristic = struct {
    decl_handle: u16,
    value_handle: u16,
    properties: att.CharProps,
    uuid: att.UUID,
};

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    /// ATT error response received
    AttError,
    /// Request timeout
    Timeout,
    /// Connection lost
    Disconnected,
    /// Channel closed
    ChannelClosed,
    /// Invalid response format
    InvalidResponse,
    /// Send failed
    SendFailed,
};
