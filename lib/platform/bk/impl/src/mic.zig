//! Microphone Implementation for BK7258
//!
//! Implements hal.mic Driver interface using armino audio ADC + DMA.

const armino = @import("../../armino/src/armino.zig");

/// Mic Driver — onboard audio ADC
pub const MicDriver = struct {
    const Self = @This();

    mic: armino.mic.Mic = .{},
    initialized: bool = false,

    pub fn init(sample_rate: u32, channels: u8, dig_gain: u8, ana_gain: u8) !Self {
        var self = Self{};
        self.mic = armino.mic.Mic.init(sample_rate, channels, dig_gain, ana_gain) catch
            return error.InitFailed;
        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.mic.deinit();
            self.initialized = false;
        }
    }

    pub fn read(self: *Self, buffer: []i16) !usize {
        return self.mic.read(buffer) catch return error.ReadFailed;
    }
};
