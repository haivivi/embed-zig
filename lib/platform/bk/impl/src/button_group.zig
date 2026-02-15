//! Button Group Implementation for BK7258
//!
//! ADC-based button group using SARADC.
//! Multiple buttons share a single ADC channel with resistor ladder.
//! Same interface as ESP's button_group.

const armino = @import("../../armino/src/armino.zig");

/// Button Group Driver for ADC-based buttons
pub fn ButtonGroupDriver(comptime ButtonId: type, comptime ranges: []const struct { id: ButtonId, min: u16, max: u16 }) type {
    return struct {
        const Self = @This();

        channel: u32,

        /// Initialize ADC button group on a SARADC channel
        pub fn init(channel: u32) !Self {
            return .{ .channel = channel };
        }

        pub fn deinit(_: *Self) void {}

        /// Read ADC and return which button (if any) is pressed
        pub fn readButton(self: *Self) ?ButtonId {
            const value = armino.adc.read(self.channel) catch return null;

            inline for (ranges) |r| {
                if (value >= r.min and value <= r.max) {
                    return r.id;
                }
            }
            return null;
        }

        /// Check if a specific button is pressed
        pub fn isPressed(self: *Self, id: ButtonId) bool {
            return self.readButton() == id;
        }

        /// Get raw ADC value (for debugging/calibration)
        pub fn readRaw(self: *Self) ?u16 {
            return armino.adc.read(self.channel) catch null;
        }
    };
}
