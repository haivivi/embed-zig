//! I2C Interface Definition
//!
//! Provides compile-time validation for I2C interface.
//!
//! Platform implementations:
//! - ESP32: lib/esp/src/sal/i2c.zig
//! - Zig std: lib/std/src/sal/i2c.zig
//!
//! Usage:
//! ```zig
//! const I2c = trait.i2c.from(hw.I2c);
//! var i2c: I2c = ...;
//! try i2c.write(0x50, &[_]u8{0x00});
//! ```

const std = @import("std");

/// I2C error types
pub const Error = error{
    InitFailed,
    NoAck,
    Timeout,
    ArbitrationLost,
    InvalidParam,
    Busy,
    I2cError,
};

/// I2C configuration
pub const Config = struct {
    sda: u8,
    scl: u8,
    freq_hz: u32 = 400_000,
    port: u8 = 0,
    pullup_en: bool = true,
    timeout_ms: u32 = 1000,
};

/// I2C Interface - comptime validates and returns wrapper type
pub fn from(comptime Impl: type) type {
    comptime {
        // Handle pointer types to avoid shallow copy
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };
        _ = @as(*const fn (*BaseType, u7, []const u8) Error!void, &BaseType.write);
        _ = @as(*const fn (*BaseType, u7, []const u8, []u8) Error!void, &BaseType.writeRead);
    }

    return struct {
        const Self = @This();
        impl: Impl,

        /// Wrap an I2C implementation
        pub fn wrap(impl: Impl) Self {
            return .{ .impl = impl };
        }

        /// Write data to device
        pub fn write(self: *Self, address: u7, data: []const u8) Error!void {
            return self.impl.write(address, data);
        }

        /// Write then read (for register reads)
        pub fn writeRead(self: *Self, address: u7, write_data: []const u8, read_buf: []u8) Error!void {
            return self.impl.writeRead(address, write_data, read_buf);
        }
    };
}

// =========== Tests ===========

test "I2c() returns interface type" {
    const MockImpl = struct {
        pub fn write(_: *@This(), _: u7, _: []const u8) Error!void {}
        pub fn writeRead(_: *@This(), _: u7, _: []const u8, _: []u8) Error!void {}
    };

    // Validate interface and get wrapper type
    const I2c = from(*MockImpl);

    // Wrap an instance
    var mock = MockImpl{};
    var i2c = I2c.wrap(&mock);
    try i2c.write(0x50, &[_]u8{0x00});
}
