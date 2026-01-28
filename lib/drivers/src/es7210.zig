//! ES7210 4-Channel ADC Driver
//!
//! Platform-independent driver for Everest Semiconductor ES7210
//! high-performance 4-channel audio ADC.
//!
//! Features:
//! - 4 independent ADC channels (MIC1-MIC4)
//! - Configurable sample rates (8k-96k)
//! - Per-channel gain control (0-37.5dB)
//! - TDM mode for multi-channel capture
//! - I2S master/slave mode
//!
//! Usage:
//!   const Es7210 = drivers.Es7210(MyI2cBus);
//!   var adc = Es7210.init(i2c_bus, .{ .mic_select = .{ .mic1 = true, .mic2 = true } });
//!   try adc.open();
//!   try adc.setSampleRate(16000);
//!   try adc.setGain(.@"30dB");

const std = @import("std");
const trait = @import("trait");

/// ES7210 I2C address (7-bit, depends on AD1/AD0 pins)
pub const Address = enum(u7) {
    ad1_ad0_00 = 0x40, // AD1=0, AD0=0
    ad1_ad0_01 = 0x41, // AD1=0, AD0=1
    ad1_ad0_10 = 0x42, // AD1=1, AD0=0
    ad1_ad0_11 = 0x43, // AD1=1, AD0=1
};

pub const DEFAULT_ADDRESS: u7 = @intFromEnum(Address.ad1_ad0_00);

/// ES7210 register addresses
pub const Register = enum(u8) {
    reset = 0x00,
    clock_off = 0x01,
    main_clk = 0x02,
    master_clk = 0x03,
    lrck_div_h = 0x04,
    lrck_div_l = 0x05,
    power_down = 0x06,
    osr = 0x07,
    mode_config = 0x08,
    time_control0 = 0x09,
    time_control1 = 0x0A,
    sdp_interface1 = 0x11,
    sdp_interface2 = 0x12,
    adc_automute = 0x13,
    adc34_muterange = 0x14,
    adc12_muterange = 0x15,
    adc34_hpf2 = 0x20,
    adc34_hpf1 = 0x21,
    adc12_hpf1 = 0x22,
    adc12_hpf2 = 0x23,
    analog = 0x40,
    mic12_bias = 0x41,
    mic34_bias = 0x42,
    mic1_gain = 0x43,
    mic2_gain = 0x44,
    mic3_gain = 0x45,
    mic4_gain = 0x46,
    mic1_power = 0x47,
    mic2_power = 0x48,
    mic3_power = 0x49,
    mic4_power = 0x4A,
    mic12_power = 0x4B,
    mic34_power = 0x4C,
};

/// Microphone input selection
pub const MicSelect = packed struct {
    mic1: bool = false,
    mic2: bool = false,
    mic3: bool = false,
    mic4: bool = false,
    _padding: u4 = 0,

    pub fn toU8(self: MicSelect) u8 {
        return @bitCast(self);
    }

    pub fn count(self: MicSelect) u8 {
        var n: u8 = 0;
        if (self.mic1) n += 1;
        if (self.mic2) n += 1;
        if (self.mic3) n += 1;
        if (self.mic4) n += 1;
        return n;
    }
};

/// Gain values (0dB to 37.5dB)
pub const Gain = enum(u8) {
    @"0dB" = 0,
    @"3dB" = 1,
    @"6dB" = 2,
    @"9dB" = 3,
    @"12dB" = 4,
    @"15dB" = 5,
    @"18dB" = 6,
    @"21dB" = 7,
    @"24dB" = 8,
    @"27dB" = 9,
    @"30dB" = 10,
    @"33dB" = 11,
    @"34.5dB" = 12,
    @"36dB" = 13,
    @"37.5dB" = 14,

    pub fn fromDb(db: f32) Gain {
        const db_int: i32 = @intFromFloat(db + 0.5);
        if (db_int < 3) return .@"0dB";
        if (db_int < 6) return .@"3dB";
        if (db_int < 9) return .@"6dB";
        if (db_int < 12) return .@"9dB";
        if (db_int < 15) return .@"12dB";
        if (db_int < 18) return .@"15dB";
        if (db_int < 21) return .@"18dB";
        if (db_int < 24) return .@"21dB";
        if (db_int < 27) return .@"24dB";
        if (db_int < 30) return .@"27dB";
        if (db_int < 33) return .@"30dB";
        if (db_int < 34) return .@"33dB";
        if (db_int < 36) return .@"34.5dB";
        if (db_int < 37) return .@"36dB";
        return .@"37.5dB";
    }
};

/// I2S data format
pub const I2sFormat = enum(u2) {
    i2s = 0b00,
    left_justified = 0b01,
    dsp_a = 0b11,
    dsp_b = 0b11,
};

/// Bits per sample
pub const BitsPerSample = enum(u8) {
    @"16bit" = 0b011,
    @"24bit" = 0b000,
    @"32bit" = 0b100,
};

/// MCLK source selection
pub const MclkSource = enum {
    from_pad,
    from_clock_doubler,
};

/// Clock coefficient structure
const ClockCoeff = struct {
    mclk: u32,
    lrck: u32,
    ss_ds: u8,
    adc_div: u8,
    dll: u8,
    doubler: u8,
    osr: u8,
    mclk_src: u8,
    lrck_h: u8,
    lrck_l: u8,
};

/// Clock coefficient table
const clock_coeffs = [_]ClockCoeff{
    // 8kHz
    .{ .mclk = 12288000, .lrck = 8000, .ss_ds = 0x00, .adc_div = 0x03, .dll = 0x01, .doubler = 0x00, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x06, .lrck_l = 0x00 },
    .{ .mclk = 4096000, .lrck = 8000, .ss_ds = 0x00, .adc_div = 0x01, .dll = 0x01, .doubler = 0x00, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x02, .lrck_l = 0x00 },
    // 16kHz
    .{ .mclk = 12288000, .lrck = 16000, .ss_ds = 0x00, .adc_div = 0x03, .dll = 0x01, .doubler = 0x01, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x03, .lrck_l = 0x00 },
    .{ .mclk = 4096000, .lrck = 16000, .ss_ds = 0x00, .adc_div = 0x01, .dll = 0x01, .doubler = 0x01, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x01, .lrck_l = 0x00 },
    // 32kHz
    .{ .mclk = 12288000, .lrck = 32000, .ss_ds = 0x00, .adc_div = 0x03, .dll = 0x00, .doubler = 0x00, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x01, .lrck_l = 0x80 },
    .{ .mclk = 8192000, .lrck = 32000, .ss_ds = 0x00, .adc_div = 0x01, .dll = 0x01, .doubler = 0x01, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x01, .lrck_l = 0x00 },
    // 44.1kHz
    .{ .mclk = 11289600, .lrck = 44100, .ss_ds = 0x00, .adc_div = 0x01, .dll = 0x01, .doubler = 0x01, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x01, .lrck_l = 0x00 },
    // 48kHz
    .{ .mclk = 12288000, .lrck = 48000, .ss_ds = 0x00, .adc_div = 0x01, .dll = 0x01, .doubler = 0x01, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x01, .lrck_l = 0x00 },
    // 96kHz
    .{ .mclk = 12288000, .lrck = 96000, .ss_ds = 0x01, .adc_div = 0x01, .dll = 0x01, .doubler = 0x01, .osr = 0x20, .mclk_src = 0x00, .lrck_h = 0x00, .lrck_l = 0x80 },
};

/// Configuration for ES7210
pub const Config = struct {
    /// I2C address
    address: u7 = DEFAULT_ADDRESS,
    /// Work as I2S master or slave
    master_mode: bool = false,
    /// Selected microphones
    mic_select: MicSelect = .{ .mic1 = true, .mic2 = true },
    /// MCLK source in master mode
    mclk_src: MclkSource = .from_pad,
    /// MCLK/LRCK ratio (default 256)
    mclk_div: u16 = 256,
};

/// ES7210 4-Channel ADC Driver
/// Generic over I2C bus type for platform independence
pub fn Es7210(comptime I2cImpl: type) type {
    const I2c = trait.i2c.from(I2cImpl);

    return struct {
        const Self = @This();

        i2c: I2c,
        config: Config,
        is_open: bool = false,
        enabled: bool = false,
        gain: Gain = .@"30dB",
        clock_off_reg: u8 = 0,

        /// Initialize driver with I2C bus and configuration
        pub fn init(i2c_impl: I2cImpl, config: Config) Self {
            return .{
                .i2c = I2c.wrap(i2c_impl),
                .config = config,
            };
        }

        /// Read a register value
        pub fn readRegister(self: *Self, reg: Register) !u8 {
            var buf: [1]u8 = undefined;
            try self.i2c.writeRead(self.config.address, &.{@intFromEnum(reg)}, &buf);
            return buf[0];
        }

        /// Write a register value
        pub fn writeRegister(self: *Self, reg: Register, value: u8) !void {
            try self.i2c.write(self.config.address, &.{ @intFromEnum(reg), value });
        }

        /// Update specific bits in a register
        pub fn updateRegister(self: *Self, reg: Register, mask: u8, value: u8) !void {
            var regv = try self.readRegister(reg);
            regv = (regv & ~mask) | (value & mask);
            try self.writeRegister(reg, regv);
        }

        // ====================================================================
        // High-level API
        // ====================================================================

        /// Open and initialize the ADC
        pub fn open(self: *Self) !void {
            // Reset
            try self.writeRegister(.reset, 0xFF);
            try self.writeRegister(.reset, 0x41);

            // Clock setup
            try self.writeRegister(.clock_off, 0x3F);
            try self.writeRegister(.time_control0, 0x30);
            try self.writeRegister(.time_control1, 0x30);

            // HPF setup
            try self.writeRegister(.adc12_hpf2, 0x2A);
            try self.writeRegister(.adc12_hpf1, 0x0A);
            try self.writeRegister(.adc34_hpf2, 0x0A);
            try self.writeRegister(.adc34_hpf1, 0x2A);

            // Master/slave mode
            if (self.config.master_mode) {
                try self.updateRegister(.mode_config, 0x01, 0x01);
                // MCLK source
                switch (self.config.mclk_src) {
                    .from_pad => try self.updateRegister(.master_clk, 0x80, 0x00),
                    .from_clock_doubler => try self.updateRegister(.master_clk, 0x80, 0x80),
                }
            } else {
                try self.updateRegister(.mode_config, 0x01, 0x00);
            }

            // Analog power and bias
            try self.writeRegister(.analog, 0x43);
            try self.writeRegister(.mic12_bias, 0x70); // 2.87V
            try self.writeRegister(.mic34_bias, 0x70); // 2.87V
            try self.writeRegister(.osr, 0x20);

            // Clock divider with DLL
            try self.writeRegister(.main_clk, 0xC1);

            // Select microphones
            try self.selectMics(self.config.mic_select);

            // Set default gain
            try self.setGainAll(self.gain);

            // Save clock off register value
            self.clock_off_reg = try self.readRegister(.clock_off);

            self.is_open = true;
        }

        /// Close the ADC
        pub fn close(self: *Self) !void {
            if (self.is_open) {
                try self.enable(false);
                self.is_open = false;
            }
        }

        /// Enable or disable the ADC
        pub fn enable(self: *Self, en: bool) !void {
            if (!self.is_open) return error.NotOpen;
            if (en == self.enabled) return;

            if (en) {
                try self.start();
            } else {
                try self.stop();
            }
            self.enabled = en;
        }

        /// Configure sample rate (only effective in master mode)
        pub fn setSampleRate(self: *Self, sample_rate: u32) !void {
            if (!self.config.master_mode) return;

            const mclk_freq = sample_rate * self.config.mclk_div;
            const coeff = getClockCoeff(mclk_freq, sample_rate) orelse return error.UnsupportedSampleRate;

            // Set ADC divider, doubler, and DLL
            var regv = try self.readRegister(.main_clk);
            regv &= 0x00;
            regv |= coeff.adc_div;
            regv |= coeff.doubler << 6;
            regv |= coeff.dll << 7;
            try self.writeRegister(.main_clk, regv);

            // Set OSR
            try self.writeRegister(.osr, coeff.osr);

            // Set LRCK divider
            try self.writeRegister(.lrck_div_h, coeff.lrck_h);
            try self.writeRegister(.lrck_div_l, coeff.lrck_l);
        }

        /// Set bits per sample
        pub fn setBitsPerSample(self: *Self, bits: BitsPerSample) !void {
            var adc_iface = try self.readRegister(.sdp_interface1);
            adc_iface &= 0x1F;
            adc_iface |= @as(u8, @intFromEnum(bits)) << 5;
            try self.writeRegister(.sdp_interface1, adc_iface);
        }

        /// Set I2S format
        pub fn setFormat(self: *Self, fmt: I2sFormat) !void {
            var adc_iface = try self.readRegister(.sdp_interface1);
            adc_iface &= 0xFC;
            adc_iface |= @intFromEnum(fmt);
            try self.writeRegister(.sdp_interface1, adc_iface);
        }

        /// Select which microphones to enable
        pub fn selectMics(self: *Self, mics: MicSelect) !void {
            self.config.mic_select = mics;

            // Disable all MIC gain first
            for (0..4) |i| {
                const reg: Register = @enumFromInt(@intFromEnum(Register.mic1_gain) + i);
                try self.updateRegister(reg, 0x10, 0x00);
            }

            // Power down all mics
            try self.writeRegister(.mic12_power, 0xFF);
            try self.writeRegister(.mic34_power, 0xFF);

            // Enable selected mics
            if (mics.mic1) {
                try self.updateRegister(.clock_off, 0x0B, 0x00);
                try self.writeRegister(.mic12_power, 0x00);
                try self.updateRegister(.mic1_gain, 0x10, 0x10);
                try self.updateRegister(.mic1_gain, 0x0F, @intFromEnum(self.gain));
            }
            if (mics.mic2) {
                try self.updateRegister(.clock_off, 0x0B, 0x00);
                try self.writeRegister(.mic12_power, 0x00);
                try self.updateRegister(.mic2_gain, 0x10, 0x10);
                try self.updateRegister(.mic2_gain, 0x0F, @intFromEnum(self.gain));
            }
            if (mics.mic3) {
                try self.updateRegister(.clock_off, 0x15, 0x00);
                try self.writeRegister(.mic34_power, 0x00);
                try self.updateRegister(.mic3_gain, 0x10, 0x10);
                try self.updateRegister(.mic3_gain, 0x0F, @intFromEnum(self.gain));
            }
            if (mics.mic4) {
                try self.updateRegister(.clock_off, 0x15, 0x00);
                try self.writeRegister(.mic34_power, 0x00);
                try self.updateRegister(.mic4_gain, 0x10, 0x10);
                try self.updateRegister(.mic4_gain, 0x0F, @intFromEnum(self.gain));
            }

            // Enable TDM mode if 3+ mics selected
            if (mics.count() >= 3) {
                try self.writeRegister(.sdp_interface2, 0x02);
            } else {
                try self.writeRegister(.sdp_interface2, 0x00);
            }
        }

        /// Set gain for all enabled microphones
        pub fn setGainAll(self: *Self, gain: Gain) !void {
            self.gain = gain;
            const gain_val = @intFromEnum(gain);

            if (self.config.mic_select.mic1) {
                try self.updateRegister(.mic1_gain, 0x0F, gain_val);
            }
            if (self.config.mic_select.mic2) {
                try self.updateRegister(.mic2_gain, 0x0F, gain_val);
            }
            if (self.config.mic_select.mic3) {
                try self.updateRegister(.mic3_gain, 0x0F, gain_val);
            }
            if (self.config.mic_select.mic4) {
                try self.updateRegister(.mic4_gain, 0x0F, gain_val);
            }
        }

        /// Set gain for a specific microphone channel (0-3)
        pub fn setChannelGain(self: *Self, channel: u2, gain: Gain) !void {
            const reg: Register = @enumFromInt(@intFromEnum(Register.mic1_gain) + channel);
            try self.updateRegister(reg, 0x0F, @intFromEnum(gain));
        }

        /// Mute or unmute all channels
        pub fn setMute(self: *Self, mute: bool) !void {
            const val: u8 = if (mute) 0x03 else 0x00;
            try self.updateRegister(.adc34_muterange, 0x03, val);
            try self.updateRegister(.adc12_muterange, 0x03, val);
        }

        /// Check if TDM mode is active (3+ mics enabled)
        pub fn isTdmMode(self: *Self) bool {
            return self.config.mic_select.count() >= 3;
        }

        // ====================================================================
        // Internal functions
        // ====================================================================

        fn start(self: *Self) !void {
            try self.writeRegister(.clock_off, self.clock_off_reg);
            try self.writeRegister(.power_down, 0x00);
            try self.writeRegister(.analog, 0x43);
            try self.writeRegister(.mic1_power, 0x08);
            try self.writeRegister(.mic2_power, 0x08);
            try self.writeRegister(.mic3_power, 0x08);
            try self.writeRegister(.mic4_power, 0x08);
            try self.selectMics(self.config.mic_select);
            try self.writeRegister(.analog, 0x43);
            try self.writeRegister(.reset, 0x71);
            try self.writeRegister(.reset, 0x41);
        }

        fn stop(self: *Self) !void {
            try self.writeRegister(.mic1_power, 0xFF);
            try self.writeRegister(.mic2_power, 0xFF);
            try self.writeRegister(.mic3_power, 0xFF);
            try self.writeRegister(.mic4_power, 0xFF);
            try self.writeRegister(.mic12_power, 0xFF);
            try self.writeRegister(.mic34_power, 0xFF);
            try self.writeRegister(.analog, 0xC0);
            try self.writeRegister(.clock_off, 0x7F);
            try self.writeRegister(.power_down, 0x07);
        }

        fn getClockCoeff(mclk: u32, lrck: u32) ?ClockCoeff {
            for (clock_coeffs) |coeff| {
                if (coeff.mclk == mclk and coeff.lrck == lrck) {
                    return coeff;
                }
            }
            return null;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0 and read_buf.len > 0) {
            const reg = write_buf[0];
            read_buf[0] = self.registers[reg];
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

test "Es7210 basic operations" {
    var mock = MockI2c{};
    var adc = Es7210(*MockI2c).init(&mock, .{
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true },
    });

    // Test open
    try adc.open();
    try std.testing.expect(adc.is_open);

    // Test TDM mode (3 mics)
    try std.testing.expect(adc.isTdmMode());

    // Test set gain
    try adc.setGainAll(.@"24dB");
    try std.testing.expectEqual(Gain.@"24dB", adc.gain);
}

test "MicSelect operations" {
    const mics = MicSelect{ .mic1 = true, .mic2 = true, .mic3 = false, .mic4 = false };
    try std.testing.expectEqual(@as(u8, 2), mics.count());
    try std.testing.expectEqual(@as(u8, 0b0011), mics.toU8());
}

test "Gain fromDb" {
    try std.testing.expectEqual(Gain.@"0dB", Gain.fromDb(0));
    try std.testing.expectEqual(Gain.@"30dB", Gain.fromDb(30));
    try std.testing.expectEqual(Gain.@"37.5dB", Gain.fromDb(40));
}
