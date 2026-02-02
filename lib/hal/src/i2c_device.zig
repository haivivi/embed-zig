//! I2C Device Adapter
//!
//! Wraps an I2C bus with a device address to provide addr_io interface.
//! This adapter bridges the gap between bus-level I2C and device-level
//! register operations.
//!
//! Usage:
//! ```zig
//! const hal = @import("hal");
//!
//! // Create adapter type for your I2C implementation
//! const I2cDev = hal.I2cDevice(hw.I2c);
//!
//! // Initialize with bus and device address
//! var dev = I2cDev.init(&i2c_bus, 0x28);
//!
//! // Use as addr_io interface
//! const val = try dev.readByte(0x01);
//! try dev.writeByte(0x01, 0x55);
//! ```

const std = @import("std");
const trait = @import("trait");

/// I2C Device Adapter - wraps I2C bus + device address into addr_io interface
pub fn I2cDevice(comptime I2cImpl: type) type {
    // Validate I2C interface at comptime
    _ = trait.i2c.from(I2cImpl);

    return struct {
        const Self = @This();

        pub const Error = trait.addr_io.Error;

        i2c: I2cImpl,
        addr: u7,

        /// Initialize with I2C bus and device address
        pub fn init(i2c: I2cImpl, device_addr: u7) Self {
            return .{
                .i2c = i2c,
                .addr = device_addr,
            };
        }

        /// Read a single byte from register
        pub fn readByte(self: *Self, reg: u8) Error!u8 {
            var buf: [1]u8 = undefined;
            self.i2c.writeRead(self.addr, &.{reg}, &buf) catch |err| {
                return mapError(err);
            };
            return buf[0];
        }

        /// Write a single byte to register
        pub fn writeByte(self: *Self, reg: u8, value: u8) Error!void {
            self.i2c.write(self.addr, &.{ reg, value }) catch |err| {
                return mapError(err);
            };
        }

        /// Read multiple bytes from register
        pub fn read(self: *Self, reg: u8, buf: []u8) Error!void {
            self.i2c.writeRead(self.addr, &.{reg}, buf) catch |err| {
                return mapError(err);
            };
        }

        /// Write multiple bytes to register
        pub fn write(self: *Self, reg: u8, data: []const u8) Error!void {
            // Need to prepend register address to data
            if (data.len == 0) {
                self.i2c.write(self.addr, &.{reg}) catch |err| {
                    return mapError(err);
                };
                return;
            }

            // For small writes, use stack buffer
            if (data.len <= 32) {
                var buf: [33]u8 = undefined;
                buf[0] = reg;
                @memcpy(buf[1..][0..data.len], data);
                self.i2c.write(self.addr, buf[0 .. data.len + 1]) catch |err| {
                    return mapError(err);
                };
                return;
            }

            // For larger writes, write register first then data
            // Note: This may not work for all I2C devices that require
            // contiguous write. In that case, use a heap allocator.
            self.i2c.write(self.addr, &.{reg}) catch |err| {
                return mapError(err);
            };
            self.i2c.write(self.addr, data) catch |err| {
                return mapError(err);
            };
        }

        fn mapError(err: trait.i2c.Error) Error {
            return switch (err) {
                error.Timeout => error.Timeout,
                error.NoAck => error.NoAck,
                error.InvalidParam => error.InvalidParam,
                error.Busy => error.Busy,
                else => error.TransportError,
            };
        }
    };
}

// =========== Tests ===========

test "I2cDevice implements addr_io interface" {
    // Mock I2C implementation
    const MockI2c = struct {
        last_addr: u7 = 0,
        last_write: [16]u8 = undefined,
        last_write_len: usize = 0,
        read_value: u8 = 0x42,

        pub fn write(self: *@This(), addr: u7, data: []const u8) trait.i2c.Error!void {
            self.last_addr = addr;
            self.last_write_len = @min(data.len, self.last_write.len);
            @memcpy(self.last_write[0..self.last_write_len], data[0..self.last_write_len]);
        }

        pub fn writeRead(self: *@This(), addr: u7, write_data: []const u8, read_buf: []u8) trait.i2c.Error!void {
            self.last_addr = addr;
            self.last_write_len = @min(write_data.len, self.last_write.len);
            @memcpy(self.last_write[0..self.last_write_len], write_data[0..self.last_write_len]);
            @memset(read_buf, self.read_value);
        }
    };

    var mock_i2c = MockI2c{};
    const Device = I2cDevice(*MockI2c);
    var dev = Device.init(&mock_i2c, 0x28);

    // Validate it implements addr_io
    _ = trait.addr_io.from(*Device);

    // Test readByte
    const val = try dev.readByte(0x01);
    try std.testing.expectEqual(@as(u8, 0x42), val);
    try std.testing.expectEqual(@as(u7, 0x28), mock_i2c.last_addr);
    try std.testing.expectEqual(@as(u8, 0x01), mock_i2c.last_write[0]);

    // Test writeByte
    try dev.writeByte(0x02, 0x55);
    try std.testing.expectEqual(@as(u8, 0x02), mock_i2c.last_write[0]);
    try std.testing.expectEqual(@as(u8, 0x55), mock_i2c.last_write[1]);

    // Test read
    var buf: [4]u8 = undefined;
    try dev.read(0x03, &buf);
    try std.testing.expectEqual(@as(u8, 0x03), mock_i2c.last_write[0]);
    try std.testing.expectEqual(@as(u8, 0x42), buf[0]);

    // Test write
    try dev.write(0x04, &[_]u8{ 0xAA, 0xBB, 0xCC });
    try std.testing.expectEqual(@as(u8, 0x04), mock_i2c.last_write[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), mock_i2c.last_write[1]);
    try std.testing.expectEqual(@as(u8, 0xBB), mock_i2c.last_write[2]);
    try std.testing.expectEqual(@as(u8, 0xCC), mock_i2c.last_write[3]);
}
