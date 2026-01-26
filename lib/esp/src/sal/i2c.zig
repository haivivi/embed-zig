//! ESP-IDF I2C Implementation
//!
//! Uses ESP-IDF I2C master driver via C helper (to handle opaque types).
//!
//! Usage:
//!   const idf = @import("esp");
//!   const I2c = idf.sal.I2c;
//!
//!   var bus = try I2c.init(.{ .sda = 17, .scl = 18 });
//!   defer bus.deinit();
//!
//!   try bus.writeRead(0x20, &.{0x00}, &read_buf);

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
    InitFailed,
    NoAck,
    Timeout,
    ArbitrationLost,
    InvalidParam,
    Busy,
    I2cError,
};

// C helper functions (defined in i2c_helper.c)
extern fn i2c_helper_init(sda: c_int, scl: c_int, freq_hz: u32, port: c_int) c_int;
extern fn i2c_helper_deinit() void;
extern fn i2c_helper_write_read(addr: u8, write_buf: [*]const u8, write_len: usize, read_buf: [*]u8, read_len: usize, timeout_ms: u32) c_int;
extern fn i2c_helper_write(addr: u8, buf: [*]const u8, len: usize, timeout_ms: u32) c_int;
extern fn i2c_helper_read(addr: u8, buf: [*]u8, len: usize, timeout_ms: u32) c_int;

/// ESP-IDF I2C Master Bus
pub const I2c = struct {
    const Self = @This();

    config: Config,
    initialized: bool = false,

    /// Initialize I2C master bus
    pub fn init(config: Config) Error!Self {
        const ret = i2c_helper_init(
            @intCast(config.sda),
            @intCast(config.scl),
            config.freq_hz,
            @intCast(config.port),
        );

        if (ret != 0) {
            return Error.InitFailed;
        }

        return .{
            .config = config,
            .initialized = true,
        };
    }

    /// Deinitialize I2C bus
    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            i2c_helper_deinit();
            self.initialized = false;
        }
    }

    /// Write data then read response
    pub fn writeRead(self: *Self, addr: u7, write_buf: []const u8, read_buf: []u8) Error!void {
        if (!self.initialized) return Error.I2cError;

        const ret = i2c_helper_write_read(
            addr,
            write_buf.ptr,
            write_buf.len,
            read_buf.ptr,
            read_buf.len,
            self.config.timeout_ms,
        );

        if (ret != 0) {
            return Error.I2cError;
        }
    }

    /// Write data only
    pub fn write(self: *Self, addr: u7, buf: []const u8) Error!void {
        if (!self.initialized) return Error.I2cError;

        const ret = i2c_helper_write(
            addr,
            buf.ptr,
            buf.len,
            self.config.timeout_ms,
        );

        if (ret != 0) {
            return Error.I2cError;
        }
    }

    /// Read data only
    pub fn read(self: *Self, addr: u7, buf: []u8) Error!void {
        if (!self.initialized) return Error.I2cError;

        const ret = i2c_helper_read(
            addr,
            buf.ptr,
            buf.len,
            self.config.timeout_ms,
        );

        if (ret != 0) {
            return Error.I2cError;
        }
    }
};
