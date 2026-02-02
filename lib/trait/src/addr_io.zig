//! Address-based IO Interface Definition
//!
//! Unified interface for register-based communication (I2C, SPI, etc.)
//! Used by devices that communicate via address-based register read/write.
//!
//! Both I2C and SPI share this pattern for NFC readers like FM175XX:
//! - Read/write single byte at address
//! - Read/write multiple bytes at address
//!
//! Platform implementations:
//! - ESP32 I2C: lib/esp/impl/src/i2c.zig
//! - ESP32 SPI: lib/esp/impl/src/spi.zig
//!
//! Usage:
//! ```zig
//! const Transport = trait.addr_io.from(hw.I2cTransport);
//! var transport: Transport = ...;
//! const val = try transport.readByte(0x01);
//! try transport.writeByte(0x01, 0x55);
//! ```

const std = @import("std");

/// Transport error types
pub const Error = error{
    Timeout,
    NoAck,
    InvalidParam,
    Busy,
    TransportError,
};

/// Addressable Transport Interface - comptime validates and returns Impl
pub fn from(comptime Impl: type) type {
    comptime {
        // Handle pointer types
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        // Validate required methods with exact signatures
        // readByte(addr) -> u8
        _ = @as(*const fn (*BaseType, u8) Error!u8, &BaseType.readByte);

        // writeByte(addr, data) -> void
        _ = @as(*const fn (*BaseType, u8, u8) Error!void, &BaseType.writeByte);

        // read(addr, buf) -> void (fills buf)
        _ = @as(*const fn (*BaseType, u8, []u8) Error!void, &BaseType.read);

        // write(addr, data) -> void
        _ = @as(*const fn (*BaseType, u8, []const u8) Error!void, &BaseType.write);
    }

    return Impl;
}

/// Check if type implements AddressableTransport interface
pub fn is(comptime T: type) bool {
    const BaseType = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };

    return @hasDecl(BaseType, "readByte") and
        @hasDecl(BaseType, "writeByte") and
        @hasDecl(BaseType, "read") and
        @hasDecl(BaseType, "write");
}

// =========== Tests ===========

test "from() validates interface type" {
    const MockTransport = struct {
        pub fn readByte(_: *@This(), _: u8) Error!u8 {
            return 0x42;
        }
        pub fn writeByte(_: *@This(), _: u8, _: u8) Error!void {}
        pub fn read(_: *@This(), _: u8, buf: []u8) Error!void {
            @memset(buf, 0);
        }
        pub fn write(_: *@This(), _: u8, _: []const u8) Error!void {}
    };

    // Validate interface and get type
    const Transport = from(*MockTransport);

    // Wrap an instance
    var mock = MockTransport{};
    var transport: Transport = &mock;

    const val = try transport.readByte(0x01);
    try std.testing.expectEqual(@as(u8, 0x42), val);

    try transport.writeByte(0x01, 0x55);

    var buf: [4]u8 = undefined;
    try transport.read(0x09, &buf);
}

test "is() checks interface compliance" {
    const ValidTransport = struct {
        pub fn readByte(_: *@This(), _: u8) Error!u8 {
            return 0;
        }
        pub fn writeByte(_: *@This(), _: u8, _: u8) Error!void {}
        pub fn read(_: *@This(), _: u8, _: []u8) Error!void {}
        pub fn write(_: *@This(), _: u8, _: []const u8) Error!void {}
    };

    const InvalidTransport = struct {
        pub fn readByte(_: *@This(), _: u8) Error!u8 {
            return 0;
        }
        // Missing other methods
    };

    try std.testing.expect(is(ValidTransport));
    try std.testing.expect(is(*ValidTransport));
    try std.testing.expect(!is(InvalidTransport));
}
