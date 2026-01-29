//! Button Group Implementation for ESP32
//!
//! Implements ADC-based button group using idf.adc.
//! Multiple buttons share a single ADC channel with resistor ladder.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const btn_group_spec = struct {
//!       pub const Driver = impl.ButtonGroupDriver;
//!       pub const ButtonId = enum { vol_up, vol_down, play };
//!       pub const meta = .{ .id = "btns.main" };
//!       pub const ranges = &.{
//!           .{ .id = .vol_up, .min = 2000, .max = 2300 },
//!           .{ .id = .vol_down, .min = 1500, .max = 1800 },
//!           .{ .id = .play, .min = 1000, .max = 1300 },
//!       };
//!   };

const std = @import("std");
const idf = @import("idf");

/// ADC Button Range configuration
pub const Range = struct {
    min: u16,
    max: u16,
};

/// Button Group Driver for ADC-based buttons
pub fn ButtonGroupDriver(comptime ButtonId: type, comptime ranges: []const struct { id: ButtonId, min: u16, max: u16 }) type {
    return struct {
        const Self = @This();

        adc: idf.AdcOneshot,
        channel: idf.adc.AdcChannel,

        /// Initialize ADC button group
        pub fn init(unit: idf.adc.AdcUnit, channel: idf.adc.AdcChannel) !Self {
            var adc = try idf.AdcOneshot.init(unit);
            try adc.configChannel(channel, .{ .atten = .db_12 });
            return .{
                .adc = adc,
                .channel = channel,
            };
        }

        /// Deinitialize
        pub fn deinit(self: *Self) void {
            self.adc.deinit();
        }

        /// Read ADC and return which button (if any) is pressed
        pub fn readButton(self: *Self) ?ButtonId {
            const raw = self.adc.read(self.channel) catch return null;
            const value: u16 = @intCast(@max(0, raw));

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
            const raw = self.adc.read(self.channel) catch return null;
            return @intCast(@max(0, raw));
        }
    };
}
