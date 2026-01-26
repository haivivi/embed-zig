//! I2C Interface Definition
//!
//! Platform-independent I2C bus abstraction.
//!
//! Usage:
//!   const sal = @import("sal");
//!   const I2c = sal.I2c;
//!
//!   var bus = try I2c.init(.{ .sda = 17, .scl = 18, .freq_hz = 400_000 });
//!   defer bus.deinit();
//!
//!   // Write then read
//!   try bus.writeRead(0x20, &.{0x00}, &read_buf);
//!
//!   // Write only
//!   try bus.write(0x20, &.{0x01, 0xFF});

const std = @import("std");

/// I2C configuration
pub const Config = struct {
    /// SDA GPIO pin
    sda: u8,
    /// SCL GPIO pin
    scl: u8,
    /// Clock frequency in Hz (typical: 100_000 or 400_000)
    freq_hz: u32 = 400_000,
    /// I2C port number (for chips with multiple I2C peripherals)
    port: u8 = 0,
    /// Internal pull-up resistors
    pullup_en: bool = true,
    /// Timeout in milliseconds
    timeout_ms: u32 = 1000,
};

/// I2C Error types
pub const Error = error{
    /// Bus initialization failed
    InitFailed,
    /// No ACK received from device
    NoAck,
    /// Bus timeout
    Timeout,
    /// Bus arbitration lost
    ArbitrationLost,
    /// Invalid parameter
    InvalidParam,
    /// Bus busy
    Busy,
    /// Generic I2C error
    I2cError,
};

/// I2C Bus Interface
/// This is a type definition that platform implementations must conform to.
/// 
/// Required methods:
/// - init(Config) -> I2c or Error
/// - deinit(*I2c) -> void
/// - writeRead(*I2c, addr, write_buf, read_buf) -> Error or void
/// - write(*I2c, addr, buf) -> Error or void
/// - read(*I2c, addr, buf) -> Error or void
pub const I2cInterface = struct {
    /// Write data then read response (common I2C pattern)
    writeReadFn: *const fn (ctx: *anyopaque, addr: u7, write_buf: []const u8, read_buf: []u8) Error!void,
    /// Write data only
    writeFn: *const fn (ctx: *anyopaque, addr: u7, buf: []const u8) Error!void,
    /// Read data only
    readFn: *const fn (ctx: *anyopaque, addr: u7, buf: []u8) Error!void,
    /// Context pointer
    ctx: *anyopaque,

    pub fn writeRead(self: I2cInterface, addr: u7, write_buf: []const u8, read_buf: []u8) Error!void {
        return self.writeReadFn(self.ctx, addr, write_buf, read_buf);
    }

    pub fn write(self: I2cInterface, addr: u7, buf: []const u8) Error!void {
        return self.writeFn(self.ctx, addr, buf);
    }

    pub fn read(self: I2cInterface, addr: u7, buf: []u8) Error!void {
        return self.readFn(self.ctx, addr, buf);
    }
};
