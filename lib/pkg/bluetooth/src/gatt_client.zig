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

pub const DiscoveredDescriptor = struct {
    handle: u16,
    uuid: att.UUID,
};

// ============================================================================
// ATT Response Parsers
// ============================================================================

/// Parse Read By Group Type Response (0x11) → list of services.
/// Response data (after opcode): [length(1)][data...]
/// Each entry: [start_handle(2)][end_handle(2)][uuid(length-4 bytes)]
pub fn parseServicesFromResponse(resp: *const AttResponse, out: []DiscoveredService) usize {
    if (resp.len < 1) return 0;
    const entry_len = resp.data[0];
    if (entry_len < 6) return 0; // at least 2+2+2

    const data = resp.data[1..resp.len];
    var count: usize = 0;
    var offset: usize = 0;

    while (offset + entry_len <= data.len and count < out.len) {
        const start = std.mem.readInt(u16, data[offset..][0..2], .little);
        const end_h = std.mem.readInt(u16, data[offset + 2 ..][0..2], .little);
        const uuid_len = entry_len - 4;

        const uuid = if (uuid_len == 2)
            att.UUID.from16(std.mem.readInt(u16, data[offset + 4 ..][0..2], .little))
        else if (uuid_len == 16)
            att.UUID.from128(data[offset + 4 ..][0..16].*)
        else
            att.UUID.from16(0);

        out[count] = .{ .start_handle = start, .end_handle = end_h, .uuid = uuid };
        count += 1;
        offset += entry_len;
    }
    return count;
}

/// Parse Read By Type Response (0x09) → list of characteristics.
/// Response data (after opcode): [length(1)][data...]
/// Each entry: [handle(2)][properties(1)][value_handle(2)][uuid(length-5 bytes)]
pub fn parseCharsFromResponse(resp: *const AttResponse, out: []DiscoveredCharacteristic) usize {
    if (resp.len < 1) return 0;
    const entry_len = resp.data[0];
    if (entry_len < 7) return 0; // at least 2+1+2+2

    const data = resp.data[1..resp.len];
    var count: usize = 0;
    var offset: usize = 0;

    while (offset + entry_len <= data.len and count < out.len) {
        const decl_handle = std.mem.readInt(u16, data[offset..][0..2], .little);
        // Characteristic declaration value: [properties(1)][value_handle(2)][uuid...]
        const properties: att.CharProps = @bitCast(data[offset + 2]);
        const value_handle = std.mem.readInt(u16, data[offset + 3 ..][0..2], .little);
        const uuid_len = entry_len - 5;

        const uuid = if (uuid_len == 2)
            att.UUID.from16(std.mem.readInt(u16, data[offset + 5 ..][0..2], .little))
        else if (uuid_len == 16)
            att.UUID.from128(data[offset + 5 ..][0..16].*)
        else
            att.UUID.from16(0);

        out[count] = .{
            .decl_handle = decl_handle,
            .value_handle = value_handle,
            .properties = properties,
            .uuid = uuid,
        };
        count += 1;
        offset += entry_len;
    }
    return count;
}

/// Parse Find Information Response (0x05) → list of descriptors.
/// Response data (after opcode): [format(1)][data...]
/// Format 1: [handle(2)][uuid16(2)] pairs
/// Format 2: [handle(2)][uuid128(16)] pairs
pub fn parseDescriptorsFromResponse(resp: *const AttResponse, out: []DiscoveredDescriptor) usize {
    if (resp.len < 1) return 0;
    const format = resp.data[0];

    const data = resp.data[1..resp.len];
    var count: usize = 0;
    var offset: usize = 0;

    if (format == 1) {
        // 16-bit UUIDs: [handle(2)][uuid16(2)]
        while (offset + 4 <= data.len and count < out.len) {
            const handle = std.mem.readInt(u16, data[offset..][0..2], .little);
            const uuid = att.UUID.from16(std.mem.readInt(u16, data[offset + 2 ..][0..2], .little));
            out[count] = .{ .handle = handle, .uuid = uuid };
            count += 1;
            offset += 4;
        }
    } else if (format == 2) {
        // 128-bit UUIDs: [handle(2)][uuid128(16)]
        while (offset + 18 <= data.len and count < out.len) {
            const handle = std.mem.readInt(u16, data[offset..][0..2], .little);
            const uuid = att.UUID.from128(data[offset + 2 ..][0..16].*);
            out[count] = .{ .handle = handle, .uuid = uuid };
            count += 1;
            offset += 18;
        }
    }
    return count;
}

// ============================================================================
// Errors
// Errors
// ============================================================================

pub const Error = error{
    AttError,
    Timeout,
    Disconnected,
    ChannelClosed,
    InvalidResponse,
    SendFailed,
};
