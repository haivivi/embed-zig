//! TCA9554 / TCA9554A I2C GPIO Expander Driver
//!
//! Platform-independent driver for Texas Instruments TCA9554/TCA9554A
//! 8-bit I2C I/O expander with interrupt output.
//!
//! Features:
//! - 8 GPIO pins (directly addressable or as bitmask)
//! - Configurable as input or output
//! - Polarity inversion for inputs
//! - Optional interrupt on input change
//!
//! Usage:
//!   const Tca9554 = drivers.Tca9554(MyI2cBus);
//!   var gpio = Tca9554.init(i2c_bus, 0x20);
//!   try gpio.setDirection(.pin6, .output);
//!   try gpio.write(.pin6, .high);

const std = @import("std");
const trait = @import("trait");

/// TCA9554 register addresses
pub const Register = enum(u8) {
    /// Input port register (read-only)
    input = 0x00,
    /// Output port register
    output = 0x01,
    /// Polarity inversion register
    polarity = 0x02,
    /// Configuration register (0=output, 1=input)
    config = 0x03,
};

// ============================================================================
// Register Bit Field Constants
// ============================================================================

/// Default register values after power-on reset
pub const Defaults = struct {
    /// Input register default (depends on pins)
    pub const INPUT: u8 = 0xFF;
    /// Output register default (all high)
    pub const OUTPUT: u8 = 0xFF;
    /// Polarity register default (no inversion)
    pub const POLARITY: u8 = 0x00;
    /// Config register default (all inputs)
    pub const CONFIG: u8 = 0xFF;
};

/// Common I2C addresses
pub const Address = struct {
    /// TCA9554 base address (A2=0, A1=0, A0=0)
    pub const TCA9554_BASE: u7 = 0x20;
    /// TCA9554A base address (A2=0, A1=0, A0=0)
    pub const TCA9554A_BASE: u7 = 0x38;
};

/// Pin masks for common use cases
pub const PinMask = struct {
    pub const NONE: u8 = 0x00;
    pub const ALL: u8 = 0xFF;
    pub const LOW_NIBBLE: u8 = 0x0F;
    pub const HIGH_NIBBLE: u8 = 0xF0;
};

/// GPIO pin identifiers
pub const Pin = enum(u3) {
    pin0 = 0,
    pin1 = 1,
    pin2 = 2,
    pin3 = 3,
    pin4 = 4,
    pin5 = 5,
    pin6 = 6,
    pin7 = 7,

    pub fn mask(self: Pin) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

/// Pin direction
pub const Direction = enum(u1) {
    output = 0,
    input = 1,
};

/// Pin level
pub const Level = enum(u1) {
    low = 0,
    high = 1,
};

/// TCA9554 GPIO Expander Driver
/// Generic over I2C bus type for platform independence
pub fn Tca9554(comptime I2cImpl: type) type {
    const I2c = trait.i2c.from(I2cImpl);
    return struct {
        const Self = @This();

        /// I2C bus instance
        i2c: I2c,
        /// Device I2C address (typically 0x20-0x27 for TCA9554, 0x38-0x3F for TCA9554A)
        address: u7,

        // Cached register values (to avoid read-modify-write)
        output_cache: u8 = 0xFF,
        config_cache: u8 = 0xFF, // All inputs by default

        /// Initialize driver with I2C bus and device address
        pub fn init(i2c_impl: I2cImpl, address: u7) Self {
            return .{
                .i2c = I2c.wrap(i2c_impl),
                .address = address,
            };
        }

        /// Read a register value
        pub fn readRegister(self: *Self, reg: Register) !u8 {
            var buf: [1]u8 = undefined;
            try self.i2c.writeRead(self.address, &.{@intFromEnum(reg)}, &buf);
            return buf[0];
        }

        /// Write a register value
        pub fn writeRegister(self: *Self, reg: Register, value: u8) !void {
            try self.i2c.write(self.address, &.{ @intFromEnum(reg), value });
        }

        // ====================================================================
        // High-level API
        // ====================================================================

        /// Set pin direction (input or output)
        pub fn setDirection(self: *Self, pin: Pin, dir: Direction) !void {
            const mask = pin.mask();
            if (dir == .output) {
                self.config_cache &= ~mask;
            } else {
                self.config_cache |= mask;
            }
            try self.writeRegister(.config, self.config_cache);
        }

        /// Set multiple pins direction at once using bitmask
        pub fn setDirectionMask(self: *Self, output_mask: u8) !void {
            self.config_cache = ~output_mask; // 0 = output in TCA9554
            try self.writeRegister(.config, self.config_cache);
        }

        /// Write output level to a pin
        pub fn write(self: *Self, pin: Pin, level: Level) !void {
            const mask = pin.mask();
            if (level == .high) {
                self.output_cache |= mask;
            } else {
                self.output_cache &= ~mask;
            }
            try self.writeRegister(.output, self.output_cache);
        }

        /// Write output levels using bitmask
        pub fn writeMask(self: *Self, mask: u8, levels: u8) !void {
            self.output_cache = (self.output_cache & ~mask) | (levels & mask);
            try self.writeRegister(.output, self.output_cache);
        }

        /// Write all outputs at once
        pub fn writeAll(self: *Self, value: u8) !void {
            self.output_cache = value;
            try self.writeRegister(.output, value);
        }

        /// Read input level from a pin
        pub fn read(self: *Self, pin: Pin) !Level {
            const value = try self.readRegister(.input);
            return if ((value & pin.mask()) != 0) .high else .low;
        }

        /// Read all inputs
        pub fn readAll(self: *Self) !u8 {
            return try self.readRegister(.input);
        }

        /// Toggle an output pin
        pub fn toggle(self: *Self, pin: Pin) !void {
            self.output_cache ^= pin.mask();
            try self.writeRegister(.output, self.output_cache);
        }

        /// Set polarity inversion for input pin
        pub fn setPolarity(self: *Self, pin: Pin, inverted: bool) !void {
            var polarity = try self.readRegister(.polarity);
            const mask = pin.mask();
            if (inverted) {
                polarity |= mask;
            } else {
                polarity &= ~mask;
            }
            try self.writeRegister(.polarity, polarity);
        }

        // ====================================================================
        // Convenience functions
        // ====================================================================

        /// Configure pin as output and set initial level
        pub fn configureOutput(self: *Self, pin: Pin, initial: Level) !void {
            try self.write(pin, initial);
            try self.setDirection(pin, .output);
        }

        /// Configure pin as input
        pub fn configureInput(self: *Self, pin: Pin) !void {
            try self.setDirection(pin, .input);
        }

        /// Reset all registers to default values
        pub fn reset(self: *Self) !void {
            self.output_cache = Defaults.OUTPUT;
            self.config_cache = Defaults.CONFIG;
            try self.writeRegister(.output, Defaults.OUTPUT);
            try self.writeRegister(.polarity, Defaults.POLARITY);
            try self.writeRegister(.config, Defaults.CONFIG);
        }

        /// Sync cache from device (read actual register values)
        pub fn syncFromDevice(self: *Self) !void {
            self.config_cache = try self.readRegister(.config);
            self.output_cache = try self.readRegister(.output);
        }

        /// Get current direction of a pin (from cache)
        pub fn getDirection(self: *Self, pin: Pin) Direction {
            const mask = pin.mask();
            return if ((self.config_cache & mask) != 0) .input else .output;
        }

        /// Get current output level of a pin (from cache)
        pub fn getOutput(self: *Self, pin: Pin) Level {
            const mask = pin.mask();
            return if ((self.output_cache & mask) != 0) .high else .low;
        }

        /// Get all output values (from cache)
        pub fn getOutputAll(self: *Self) u8 {
            return self.output_cache;
        }

        /// Get all direction config (from cache)
        pub fn getConfigAll(self: *Self) u8 {
            return self.config_cache;
        }

        /// Check if pin is configured as output
        pub fn isOutput(self: *Self, pin: Pin) bool {
            return self.getDirection(pin) == .output;
        }

        /// Check if pin is configured as input
        pub fn isInput(self: *Self, pin: Pin) bool {
            return self.getDirection(pin) == .input;
        }

        /// Set all pins as outputs
        pub fn setAllOutputs(self: *Self) !void {
            self.config_cache = PinMask.NONE;
            try self.writeRegister(.config, self.config_cache);
        }

        /// Set all pins as inputs
        pub fn setAllInputs(self: *Self) !void {
            self.config_cache = PinMask.ALL;
            try self.writeRegister(.config, self.config_cache);
        }

        /// Set all outputs high
        pub fn setAllHigh(self: *Self) !void {
            self.output_cache = PinMask.ALL;
            try self.writeRegister(.output, self.output_cache);
        }

        /// Set all outputs low
        pub fn setAllLow(self: *Self) !void {
            self.output_cache = PinMask.NONE;
            try self.writeRegister(.output, self.output_cache);
        }

        /// Set polarity inversion for multiple pins
        pub fn setPolarityMask(self: *Self, invert_mask: u8) !void {
            try self.writeRegister(.polarity, invert_mask);
        }

        /// Get current polarity inversion settings
        pub fn getPolarity(self: *Self) !u8 {
            return try self.readRegister(.polarity);
        }

        /// Configure multiple pins at once
        /// output_pins: bitmask of pins to configure as output (others as input)
        /// initial_levels: initial output levels for output pins
        pub fn configureMultiple(self: *Self, output_pins: u8, initial_levels: u8) !void {
            self.output_cache = initial_levels;
            self.config_cache = ~output_pins;
            try self.writeRegister(.output, self.output_cache);
            try self.writeRegister(.config, self.config_cache);
        }

        /// Pulse a pin (set high, then low, or vice versa)
        /// Returns to original state
        pub fn pulse(self: *Self, pin: Pin) !void {
            try self.toggle(pin);
            try self.toggle(pin);
        }

        /// Set pin high
        pub fn setHigh(self: *Self, pin: Pin) !void {
            try self.write(pin, .high);
        }

        /// Set pin low
        pub fn setLow(self: *Self, pin: Pin) !void {
            try self.write(pin, .low);
        }

        /// Check if input pin is high
        pub fn isHigh(self: *Self, pin: Pin) !bool {
            return (try self.read(pin)) == .high;
        }

        /// Check if input pin is low
        pub fn isLow(self: *Self, pin: Pin) !bool {
            return (try self.read(pin)) == .low;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [4]u8 = .{ 0xFF, 0xFF, 0x00, 0xFF },
    last_write_addr: ?u8 = null,
    last_write_data: ?u8 = null,

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0 and read_buf.len > 0) {
            const reg = write_buf[0];
            if (reg < 4) {
                read_buf[0] = self.registers[reg];
            }
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            if (reg < 4) {
                self.registers[reg] = buf[1];
                self.last_write_addr = reg;
                self.last_write_data = buf[1];
            }
        }
    }
};

test "Tca9554 basic operations" {
    var mock = MockI2c{};
    var gpio = Tca9554(*MockI2c).init(&mock, 0x20);

    // Test set direction
    try gpio.setDirection(.pin6, .output);
    try std.testing.expectEqual(@as(u8, 0xBF), mock.registers[@intFromEnum(Register.config)]);

    // Test write
    try gpio.write(.pin6, .high);
    try std.testing.expectEqual(@as(u8, 0xFF), mock.registers[@intFromEnum(Register.output)]);

    try gpio.write(.pin6, .low);
    try std.testing.expectEqual(@as(u8, 0xBF), mock.registers[@intFromEnum(Register.output)]);
}

test "Tca9554 configure output" {
    var mock = MockI2c{};
    var gpio = Tca9554(*MockI2c).init(&mock, 0x20);

    try gpio.configureOutput(.pin7, .low);
    // Output should be low
    try std.testing.expectEqual(@as(u8, 0x7F), mock.registers[@intFromEnum(Register.output)]);
    // Pin should be configured as output
    try std.testing.expectEqual(@as(u8, 0x7F), mock.registers[@intFromEnum(Register.config)]);
}

test "Pin mask" {
    try std.testing.expectEqual(@as(u8, 0x01), Pin.pin0.mask());
    try std.testing.expectEqual(@as(u8, 0x40), Pin.pin6.mask());
    try std.testing.expectEqual(@as(u8, 0x80), Pin.pin7.mask());
}
