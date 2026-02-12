//! SPI Interface Definition
//!
//! Provides compile-time validation for SPI bus interface.
//!
//! Platform implementations:
//! - ESP32: lib/platform/esp/impl/src/spi.zig (future)
//! - WebSim: lib/platform/websim/impl/spi.zig (simulated)
//!
//! Usage:
//! ```zig
//! const Spi = trait.spi.from(hw.Spi);
//! var spi: Spi = ...;
//! try spi.write(&[_]u8{ 0x2A, 0x00, 0x00 });
//! ```

const std = @import("std");

/// SPI error types
pub const Error = error{
    TransferFailed,
    Busy,
    Timeout,
    SpiError,
};

/// SPI Interface - comptime validates and returns wrapper type
///
/// Required methods on Impl:
/// - `fn write(self: *Impl, data: []const u8) Error!void`
///
/// Optional methods:
/// - `fn transfer(self: *Impl, tx: []const u8, rx: []u8) Error!void` (full duplex)
/// - `fn read(self: *Impl, buf: []u8) Error!void` (read-only)
pub fn from(comptime Impl: type) type {
    comptime {
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };
        // Required: write
        _ = @as(*const fn (*BaseType, []const u8) Error!void, &BaseType.write);
    }

    return struct {
        const Self = @This();
        impl: Impl,

        /// Wrap an SPI implementation
        pub fn wrap(impl: Impl) Self {
            return .{ .impl = impl };
        }

        /// Write data (MOSI only)
        pub fn write(self: *Self, data: []const u8) Error!void {
            return self.impl.write(data);
        }

        /// Full-duplex transfer (write tx, read rx simultaneously).
        /// Available only if the underlying implementation supports it.
        pub fn transfer(self: *Self, tx: []const u8, rx: []u8) Error!void {
            if (@hasDecl(@TypeOf(self.impl.*), "transfer")) {
                return self.impl.transfer(tx, rx);
            } else {
                @compileError("SPI implementation does not support full-duplex transfer");
            }
        }

        /// Read data (MISO only).
        /// Available only if the underlying implementation supports it.
        pub fn read(self: *Self, buf: []u8) Error!void {
            if (@hasDecl(@TypeOf(self.impl.*), "read")) {
                return self.impl.read(buf);
            } else {
                @compileError("SPI implementation does not support read");
            }
        }
    };
}

// =========== Tests ===========

test "spi.from() returns interface type" {
    const MockImpl = struct {
        write_count: u32 = 0,
        last_len: usize = 0,

        pub fn write(self: *@This(), data: []const u8) Error!void {
            self.write_count += 1;
            self.last_len = data.len;
        }
    };

    const Spi = from(*MockImpl);

    var mock = MockImpl{};
    var spi = Spi.wrap(&mock);
    try spi.write(&[_]u8{ 0x2A, 0x00, 0xEF });

    try std.testing.expectEqual(@as(u32, 1), mock.write_count);
    try std.testing.expectEqual(@as(usize, 3), mock.last_len);
}

test "spi.from() with full duplex" {
    const FullDuplexImpl = struct {
        pub fn write(_: *@This(), _: []const u8) Error!void {}
        pub fn transfer(_: *@This(), tx: []const u8, rx: []u8) Error!void {
            // Echo back tx to rx
            const len = @min(tx.len, rx.len);
            @memcpy(rx[0..len], tx[0..len]);
        }
    };

    const Spi = from(*FullDuplexImpl);

    var mock = FullDuplexImpl{};
    var spi = Spi.wrap(&mock);

    var rx: [3]u8 = undefined;
    try spi.transfer(&[_]u8{ 0xAA, 0xBB, 0xCC }, &rx);

    try std.testing.expectEqual(@as(u8, 0xAA), rx[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), rx[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), rx[2]);
}
