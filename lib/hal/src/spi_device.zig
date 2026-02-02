//! SPI Device Adapter
//!
//! Wraps an SPI bus with a CS (chip select) GPIO to provide addr_io interface.
//! Handles the FM175XX-specific SPI protocol where:
//! - Read: addr << 1 | 0x80, then receive data
//! - Write: addr << 1, then send data
//!
//! Usage:
//! ```zig
//! const hal = @import("hal");
//!
//! // Create adapter type for your SPI and GPIO implementations
//! const SpiDev = hal.SpiDevice(hw.Spi, hw.Gpio);
//!
//! // Initialize with SPI bus and CS pin
//! var dev = SpiDev.init(&spi_bus, &cs_pin);
//!
//! // Use as addr_io interface
//! const val = try dev.readByte(0x01);
//! try dev.writeByte(0x01, 0x55);
//! ```

const std = @import("std");
const trait = @import("trait");

/// SPI error types (for interface validation)
pub const SpiError = error{
    Timeout,
    TransferFailed,
    InvalidParam,
    Busy,
};

/// GPIO error types (for interface validation)
pub const GpioError = error{
    InvalidPin,
    OperationFailed,
};

/// SPI Device Adapter - wraps SPI bus + CS GPIO into addr_io interface
/// FM175XX SPI Protocol:
/// - Read:  [addr << 1 | 0x80] [0x00...] -> receives data on MISO
/// - Write: [addr << 1] [data...]
pub fn SpiDevice(comptime SpiImpl: type, comptime GpioImpl: type) type {
    // Validate SPI interface at comptime
    comptime {
        const SpiBase = switch (@typeInfo(SpiImpl)) {
            .pointer => |p| p.child,
            else => SpiImpl,
        };
        // SPI needs transfer (full duplex) or write+read
        if (@hasDecl(SpiBase, "transfer")) {
            _ = @as(*const fn (*SpiBase, []const u8, []u8) SpiError!void, &SpiBase.transfer);
        } else {
            _ = @as(*const fn (*SpiBase, []const u8) SpiError!void, &SpiBase.write);
            _ = @as(*const fn (*SpiBase, []u8) SpiError!void, &SpiBase.read);
        }
    }

    // Validate GPIO interface at comptime
    comptime {
        const GpioBase = switch (@typeInfo(GpioImpl)) {
            .pointer => |p| p.child,
            else => GpioImpl,
        };
        // GPIO needs setLow/setHigh for CS control
        _ = @as(*const fn (*GpioBase) GpioError!void, &GpioBase.setLow);
        _ = @as(*const fn (*GpioBase) GpioError!void, &GpioBase.setHigh);
    }

    const SpiBase = switch (@typeInfo(SpiImpl)) {
        .pointer => |p| p.child,
        else => SpiImpl,
    };
    const has_transfer = @hasDecl(SpiBase, "transfer");

    return struct {
        const Self = @This();

        pub const Error = trait.addr_io.Error;

        spi: SpiImpl,
        cs: GpioImpl,

        /// Initialize with SPI bus and CS GPIO
        pub fn init(spi: SpiImpl, cs: GpioImpl) Self {
            return .{
                .spi = spi,
                .cs = cs,
            };
        }

        /// Assert CS (pull low)
        fn csLow(self: *Self) void {
            self.cs.setLow() catch {};
        }

        /// Deassert CS (pull high)
        fn csHigh(self: *Self) void {
            self.cs.setHigh() catch {};
        }

        /// Read a single byte from register
        pub fn readByte(self: *Self, reg: u8) Error!u8 {
            self.csLow();
            defer self.csHigh();

            // FM175XX: read address = (reg << 1) | 0x80
            const addr_byte = (reg << 1) | 0x80;

            if (has_transfer) {
                var tx: [2]u8 = .{ addr_byte, 0x00 };
                var rx: [2]u8 = undefined;
                self.spi.transfer(&tx, &rx) catch {
                    return error.TransportError;
                };
                return rx[1];
            } else {
                self.spi.write(&.{addr_byte}) catch {
                    return error.TransportError;
                };
                var rx: [1]u8 = undefined;
                self.spi.read(&rx) catch {
                    return error.TransportError;
                };
                return rx[0];
            }
        }

        /// Write a single byte to register
        pub fn writeByte(self: *Self, reg: u8, value: u8) Error!void {
            self.csLow();
            defer self.csHigh();

            // FM175XX: write address = (reg << 1) & 0x7E
            const addr_byte = (reg << 1) & 0x7E;

            if (has_transfer) {
                var tx: [2]u8 = .{ addr_byte, value };
                var rx: [2]u8 = undefined;
                self.spi.transfer(&tx, &rx) catch {
                    return error.TransportError;
                };
            } else {
                self.spi.write(&.{ addr_byte, value }) catch {
                    return error.TransportError;
                };
            }
        }

        /// Read multiple bytes from register
        pub fn read(self: *Self, reg: u8, buf: []u8) Error!void {
            if (buf.len == 0) return;

            self.csLow();
            defer self.csHigh();

            // FM175XX continuous read: keep sending read address
            const addr_byte = (reg << 1) | 0x80;

            if (has_transfer) {
                // Send address + dummy bytes, receive data
                var tx_buf: [64]u8 = undefined;
                var rx_buf: [64]u8 = undefined;

                // For continuous read, each byte needs address
                var offset: usize = 0;
                while (offset < buf.len) {
                    const chunk = @min(buf.len - offset, 63);
                    tx_buf[0] = addr_byte;
                    for (1..chunk + 1) |i| {
                        // Continue reading same register (FIFO auto-increment)
                        tx_buf[i] = if (i < chunk) addr_byte else 0x00;
                    }
                    self.spi.transfer(tx_buf[0 .. chunk + 1], rx_buf[0 .. chunk + 1]) catch {
                        return error.TransportError;
                    };
                    @memcpy(buf[offset..][0..chunk], rx_buf[1..][0..chunk]);
                    offset += chunk;
                }
            } else {
                // Send address first
                self.spi.write(&.{addr_byte}) catch {
                    return error.TransportError;
                };
                // Then read data
                self.spi.read(buf) catch {
                    return error.TransportError;
                };
            }
        }

        /// Write multiple bytes to register
        pub fn write(self: *Self, reg: u8, data: []const u8) Error!void {
            if (data.len == 0) return;

            self.csLow();
            defer self.csHigh();

            // FM175XX: write address = (reg << 1) & 0x7E
            const addr_byte = (reg << 1) & 0x7E;

            if (has_transfer) {
                // Send address + data
                var tx_buf: [65]u8 = undefined;
                var rx_buf: [65]u8 = undefined;

                var offset: usize = 0;
                while (offset < data.len) {
                    const chunk = @min(data.len - offset, 64);
                    tx_buf[0] = addr_byte;
                    @memcpy(tx_buf[1..][0..chunk], data[offset..][0..chunk]);
                    self.spi.transfer(tx_buf[0 .. chunk + 1], rx_buf[0 .. chunk + 1]) catch {
                        return error.TransportError;
                    };
                    offset += chunk;
                }
            } else {
                self.spi.write(&.{addr_byte}) catch {
                    return error.TransportError;
                };
                self.spi.write(data) catch {
                    return error.TransportError;
                };
            }
        }
    };
}

// =========== Tests ===========

test "SpiDevice implements addr_io interface" {
    // Mock SPI implementation (with transfer)
    const MockSpi = struct {
        last_tx: [16]u8 = undefined,
        last_tx_len: usize = 0,
        read_value: u8 = 0x42,

        pub fn transfer(self: *@This(), tx: []const u8, rx: []u8) SpiError!void {
            self.last_tx_len = @min(tx.len, self.last_tx.len);
            @memcpy(self.last_tx[0..self.last_tx_len], tx[0..self.last_tx_len]);
            @memset(rx, self.read_value);
        }
    };

    // Mock GPIO implementation
    const MockGpio = struct {
        level: bool = true,

        pub fn setLow(self: *@This()) GpioError!void {
            self.level = false;
        }

        pub fn setHigh(self: *@This()) GpioError!void {
            self.level = true;
        }
    };

    var mock_spi = MockSpi{};
    var mock_gpio = MockGpio{};

    const Device = SpiDevice(*MockSpi, *MockGpio);
    var dev = Device.init(&mock_spi, &mock_gpio);

    // Validate it implements addr_io
    _ = trait.addr_io.from(*Device);

    // Test readByte
    // Register 0x01 -> addr = (0x01 << 1) | 0x80 = 0x82
    const val = try dev.readByte(0x01);
    try std.testing.expectEqual(@as(u8, 0x42), val);
    try std.testing.expectEqual(@as(u8, 0x82), mock_spi.last_tx[0]);

    // Test writeByte
    // Register 0x02 -> addr = (0x02 << 1) & 0x7E = 0x04
    try dev.writeByte(0x02, 0x55);
    try std.testing.expectEqual(@as(u8, 0x04), mock_spi.last_tx[0]);
    try std.testing.expectEqual(@as(u8, 0x55), mock_spi.last_tx[1]);

    // CS should be high after operations
    try std.testing.expect(mock_gpio.level);
}

test "SpiDevice with separate read/write" {
    // Mock SPI implementation (with separate read/write)
    const MockSpi2 = struct {
        last_write: [16]u8 = undefined,
        last_write_len: usize = 0,
        read_value: u8 = 0x33,

        pub fn write(self: *@This(), data: []const u8) SpiError!void {
            self.last_write_len = @min(data.len, self.last_write.len);
            @memcpy(self.last_write[0..self.last_write_len], data[0..self.last_write_len]);
        }

        pub fn read(self: *@This(), buf: []u8) SpiError!void {
            @memset(buf, self.read_value);
        }
    };

    const MockGpio = struct {
        pub fn setLow(_: *@This()) GpioError!void {}
        pub fn setHigh(_: *@This()) GpioError!void {}
    };

    var mock_spi = MockSpi2{};
    var mock_gpio = MockGpio{};

    const Device = SpiDevice(*MockSpi2, *MockGpio);
    var dev = Device.init(&mock_spi, &mock_gpio);

    // Test readByte with separate write/read SPI
    const val = try dev.readByte(0x05);
    try std.testing.expectEqual(@as(u8, 0x33), val);
    // Register 0x05 -> addr = (0x05 << 1) | 0x80 = 0x8A
    try std.testing.expectEqual(@as(u8, 0x8A), mock_spi.last_write[0]);
}
