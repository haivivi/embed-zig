//! HCI — Host Controller Interface Packet Codec
//!
//! Encode HCI commands, decode HCI events, and parse/build ACL data packets.
//! Pure data transformation — no I/O, no state.
//!
//! ## Packet Types (BT Core Spec Vol 4, Part A)
//!
//! | Indicator | Direction         | Module   |
//! |-----------|-------------------|----------|
//! | 0x01      | Host → Controller | commands |
//! | 0x02      | Bidirectional     | acl      |
//! | 0x04      | Controller → Host | events   |

pub const commands = @import("commands.zig");
pub const events = @import("events.zig");
pub const acl = @import("acl.zig");

// ============================================================================
// Common Types
// ============================================================================

/// HCI packet indicator (first byte on transport)
pub const PacketType = enum(u8) {
    command = 0x01,
    acl_data = 0x02,
    sync_data = 0x03,
    event = 0x04,
    iso_data = 0x05,
};

/// BLE address (6 bytes, little-endian)
pub const BdAddr = [6]u8;

/// BLE address type
pub const AddrType = enum(u8) {
    public = 0x00,
    random = 0x01,
    public_identity = 0x02,
    random_identity = 0x03,
};

/// HCI Status codes (BT Core Spec Vol 2, Part D)
pub const Status = enum(u8) {
    success = 0x00,
    unknown_command = 0x01,
    unknown_connection = 0x02,
    hardware_failure = 0x03,
    authentication_failure = 0x05,
    pin_or_key_missing = 0x06,
    memory_exceeded = 0x07,
    connection_timeout = 0x08,
    connection_limit = 0x09,
    command_disallowed = 0x0C,
    rejected_resources = 0x0D,
    unsupported_feature = 0x11,
    invalid_parameters = 0x12,
    remote_terminated = 0x13,
    local_terminated = 0x16,
    repeated_attempts = 0x17,
    pairing_not_allowed = 0x18,
    unknown_advertising = 0x42,
    _,

    pub fn isSuccess(self: Status) bool {
        return self == .success;
    }
};

// ============================================================================
// Tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
