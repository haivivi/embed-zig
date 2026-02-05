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
const es7210 = @This();

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

// ============================================================================
// Register Bit Field Constants
// ============================================================================

/// Reset register (0x00) values
pub const ResetReg = struct {
    /// Software reset
    pub const SOFT_RESET: u8 = 0x41;
    /// Normal operation (after reset)
    pub const NORMAL: u8 = 0x00;
};

/// Clock Off register (0x01) bit fields
pub const ClockOff = struct {
    /// All clocks off for initialization
    pub const ALL_OFF: u8 = 0x3F;
    /// All clocks on
    pub const ALL_ON: u8 = 0x00;
    /// MIC12 ADC clock select bits
    pub const MIC12_CLK: u8 = 0x0B;
    /// MIC34 ADC clock select bits
    pub const MIC34_CLK: u8 = 0x15;
};

/// Mode Config register (0x08) bit fields
pub const ModeConfig = struct {
    /// Master mode
    pub const MASTER: u8 = 0x01;
    /// Slave mode
    pub const SLAVE: u8 = 0x00;
};

/// SDP Interface 1 register (0x11) bit fields
pub const SdpInterface1 = struct {
    /// Word length mask (bits 5-7)
    pub const WL_MASK: u8 = 0xE0;
    /// Word length shift
    pub const WL_SHIFT: u4 = 5;
    /// Data format mask
    pub const FMT_MASK: u8 = 0x03;
    /// MSB first
    pub const MSB_FIRST: u8 = 0x00;
    /// LSB first
    pub const LSB_FIRST: u8 = 0x01;
};

/// SDP Interface 2 register (0x12) bit fields
pub const SdpInterface2 = struct {
    /// TDM mode enable
    pub const TDM_EN: u8 = 0x02;
    /// TDM mode disable (normal mode)
    pub const TDM_DIS: u8 = 0x00;
};

/// Time Control 0 register (0x09) defaults
pub const TimeControl0 = struct {
    /// Default timing
    pub const DEFAULT: u8 = 0x30;
};

/// Analog register (0x40) values
pub const AnalogReg = struct {
    /// Analog power on
    pub const POWER_ON: u8 = 0x40;
    /// Analog power off
    pub const POWER_OFF: u8 = 0xFF;
    /// Low power mode (LP bit set)
    pub const LOW_POWER: u8 = 0xC0;
};

/// MIC Bias register values
pub const MicBias = struct {
    /// Normal bias
    pub const NORMAL: u8 = 0x77;
    /// Bias off
    pub const OFF: u8 = 0xFF;
    /// Low power bias
    pub const LOW_POWER: u8 = 0x66;
};

/// MIC Power register values
pub const MicPower = struct {
    /// Power on
    pub const ON: u8 = 0x3F;
    /// Power off
    pub const OFF: u8 = 0xFF;
    /// Low power
    pub const LOW_POWER: u8 = 0x00;
};

/// MIC Gain register bit fields
pub const GainReg = struct {
    /// PGA enable (+3dB)
    pub const PGA_ENABLE: u8 = 0x10;
    /// Gain value mask (0-14)
    pub const GAIN_MASK: u8 = 0x0F;
    /// Default gain value (MIC input gain)
    pub const DEFAULT: u8 = 0x00;
};

/// ADC HPF (High Pass Filter) register values
pub const HpfReg = struct {
    /// HPF coefficients for MIC34
    pub const MIC34_HPF1: u8 = 0x2A;
    pub const MIC34_HPF2: u8 = 0x0A;
    /// HPF coefficients for MIC12
    pub const MIC12_HPF1: u8 = 0x0A;
    pub const MIC12_HPF2: u8 = 0x2A;
};

/// Power Down register (0x06) values
pub const PowerDown = struct {
    /// All modules power on
    pub const ALL_ON: u8 = 0x00;
    /// All modules power down
    pub const ALL_OFF: u8 = 0xFF;
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
    i2s = 0b00, // I2S Philips
    left_justified = 0b01,
    dsp = 0b11, // DSP-A or DSP-B (determined by time control)
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

        /// Gain type alias for external access
        pub const Gain = es7210.Gain;

        /// Constants from parent module
        pub const channel_count: u8 = 4;
        pub const max_gain_db: i8 = 37;

        i2c: I2c,
        config: Config,
        is_open: bool = false,
        enabled: bool = false,
        gain: Self.Gain = .@"30dB",
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
        /// Note: Caller should add ~10ms delay after reset if needed
        pub fn open(self: *Self) !void {
            // Reset
            try self.writeRegister(.reset, 0xFF);
            // Note: C version has 10ms delay here, but we can't do that in generic driver
            // The ESP board code adds delay if needed
            try self.writeRegister(.reset, ResetReg.SOFT_RESET);

            // Clock setup - turn off all clocks during init
            try self.writeRegister(.clock_off, ClockOff.ALL_OFF);
            try self.writeRegister(.time_control0, TimeControl0.DEFAULT);
            try self.writeRegister(.time_control1, TimeControl0.DEFAULT);

            // HPF setup (matching C version exactly)
            try self.writeRegister(.adc12_hpf2, HpfReg.MIC34_HPF1);
            try self.writeRegister(.adc12_hpf1, HpfReg.MIC34_HPF2);
            try self.writeRegister(.adc34_hpf2, HpfReg.MIC34_HPF2);
            try self.writeRegister(.adc34_hpf1, HpfReg.MIC34_HPF1);

            // Unmute all ADCs (critical! missing in original)
            try self.writeRegister(.adc12_muterange, 0x00); // 0x15
            try self.writeRegister(.adc34_muterange, 0x00); // 0x14

            // Master/slave mode
            if (self.config.master_mode) {
                try self.updateRegister(.mode_config, 0x01, ModeConfig.MASTER);
                // MCLK source
                switch (self.config.mclk_src) {
                    .from_pad => try self.updateRegister(.master_clk, 0x80, 0x00),
                    .from_clock_doubler => try self.updateRegister(.master_clk, 0x80, 0x80),
                }
            } else {
                try self.updateRegister(.mode_config, 0x01, ModeConfig.SLAVE);
            }

            // Analog power and bias
            try self.writeRegister(.analog, 0x43);
            try self.writeRegister(.mic12_bias, 0x70); // 2.87V
            try self.writeRegister(.mic34_bias, 0x70); // 2.87V
            try self.writeRegister(.osr, 0x20);

            // Clock divider with DLL
            try self.writeRegister(.main_clk, 0xC1);

            // Select microphones (also enables TDM mode if 3+ mics)
            try self.selectMics(self.config.mic_select);

            // Force SDP_IF1 = 0x60 (16-bit I2S format)
            // This matches the C version exactly:
            //   bit 7:5 = 011 (16-bit word length)
            //   bit 4:2 = 000
            //   bit 1:0 = 00 (I2S Philips format)
            try self.writeRegister(.sdp_interface1, 0x60);

            // Set default gain
            try self.setGainAll(self.gain);

            // Final analog power setting (same as ESP-ADF)
            try self.writeRegister(.analog, 0x43);

            // Start the chip by writing to reset register (critical!)
            // This sequence from ESP-ADF is required to actually start the ADC
            try self.writeRegister(.reset, 0x71);
            try self.writeRegister(.reset, 0x41);

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
            adc_iface &= ~SdpInterface1.WL_MASK;
            adc_iface |= @as(u8, @intFromEnum(bits)) << 5;
            try self.writeRegister(.sdp_interface1, adc_iface);
        }

        /// Set I2S format
        pub fn setFormat(self: *Self, fmt: I2sFormat) !void {
            var adc_iface = try self.readRegister(.sdp_interface1);
            adc_iface &= ~SdpInterface1.FMT_MASK;
            adc_iface |= @intFromEnum(fmt);
            try self.writeRegister(.sdp_interface1, adc_iface);
        }

        /// Select which microphones to enable
        pub fn selectMics(self: *Self, mics: MicSelect) !void {
            self.config.mic_select = mics;

            // Disable all MIC gain first (clear PGA enable bit)
            for (0..4) |i| {
                const reg: Register = @enumFromInt(@intFromEnum(Register.mic1_gain) + i);
                try self.updateRegister(reg, GainReg.PGA_ENABLE, 0x00);
            }

            // Power down all mics
            try self.writeRegister(.mic12_power, MicPower.OFF);
            try self.writeRegister(.mic34_power, MicPower.OFF);

            // Enable selected mics
            if (mics.mic1) {
                try self.updateRegister(.clock_off, ClockOff.MIC12_CLK, 0x00);
                try self.writeRegister(.mic12_power, MicPower.LOW_POWER);
                try self.updateRegister(.mic1_gain, GainReg.PGA_ENABLE, GainReg.PGA_ENABLE);
                try self.updateRegister(.mic1_gain, GainReg.GAIN_MASK, @intFromEnum(self.gain));
            }
            if (mics.mic2) {
                try self.updateRegister(.clock_off, ClockOff.MIC12_CLK, 0x00);
                try self.writeRegister(.mic12_power, MicPower.LOW_POWER);
                try self.updateRegister(.mic2_gain, GainReg.PGA_ENABLE, GainReg.PGA_ENABLE);
                try self.updateRegister(.mic2_gain, GainReg.GAIN_MASK, @intFromEnum(self.gain));
            }
            if (mics.mic3) {
                try self.updateRegister(.clock_off, ClockOff.MIC34_CLK, 0x00);
                try self.writeRegister(.mic34_power, MicPower.LOW_POWER);
                try self.updateRegister(.mic3_gain, GainReg.PGA_ENABLE, GainReg.PGA_ENABLE);
                try self.updateRegister(.mic3_gain, GainReg.GAIN_MASK, @intFromEnum(self.gain));
            }
            if (mics.mic4) {
                try self.updateRegister(.clock_off, ClockOff.MIC34_CLK, 0x00);
                try self.writeRegister(.mic34_power, MicPower.LOW_POWER);
                try self.updateRegister(.mic4_gain, GainReg.PGA_ENABLE, GainReg.PGA_ENABLE);
                try self.updateRegister(.mic4_gain, GainReg.GAIN_MASK, @intFromEnum(self.gain));
            }

            // Enable TDM mode if 3+ mics selected
            if (mics.count() >= 3) {
                try self.writeRegister(.sdp_interface2, SdpInterface2.TDM_EN);
            } else {
                try self.writeRegister(.sdp_interface2, SdpInterface2.TDM_DIS);
            }
        }

        /// Set gain for all enabled microphones
        pub fn setGainAll(self: *Self, gain: Self.Gain) !void {
            self.gain = gain;
            const gain_val = @intFromEnum(gain);

            if (self.config.mic_select.mic1) {
                try self.updateRegister(.mic1_gain, GainReg.GAIN_MASK, gain_val);
            }
            if (self.config.mic_select.mic2) {
                try self.updateRegister(.mic2_gain, GainReg.GAIN_MASK, gain_val);
            }
            if (self.config.mic_select.mic3) {
                try self.updateRegister(.mic3_gain, GainReg.GAIN_MASK, gain_val);
            }
            if (self.config.mic_select.mic4) {
                try self.updateRegister(.mic4_gain, GainReg.GAIN_MASK, gain_val);
            }
        }

        /// Set gain for a specific microphone channel (0-3)
        pub fn setChannelGain(self: *Self, channel: u2, gain: Self.Gain) !void {
            const reg: Register = @enumFromInt(@intFromEnum(Register.mic1_gain) + channel);
            try self.updateRegister(reg, GainReg.GAIN_MASK, @intFromEnum(gain));
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

        /// Get current gain setting
        pub fn getGain(self: *Self) Self.Gain {
            return self.gain;
        }

        /// Get gain for a specific microphone channel (0-3)
        pub fn getChannelGain(self: *Self, channel: u2) !Self.Gain {
            const reg: Register = @enumFromInt(@intFromEnum(Register.mic1_gain) + channel);
            const val = try self.readRegister(reg);
            const gain_val: u4 = @truncate(val & GainReg.GAIN_MASK);
            return @enumFromInt(gain_val);
        }

        /// Enable or disable TDM mode
        pub fn setTdmMode(self: *Self, en: bool) !void {
            const val: u8 = if (en) SdpInterface2.TDM_EN else SdpInterface2.TDM_DIS;
            try self.writeRegister(.sdp_interface2, val);
        }

        /// Perform soft reset
        pub fn softReset(self: *Self) !void {
            try self.writeRegister(.reset, 0xFF);
            try self.writeRegister(.reset, ResetReg.SOFT_RESET);
        }

        /// Set power mode (normal or low power)
        pub fn setPowerMode(self: *Self, low_power: bool) !void {
            if (low_power) {
                try self.writeRegister(.analog, AnalogReg.LOW_POWER);
                try self.writeRegister(.mic12_bias, MicBias.LOW_POWER);
                try self.writeRegister(.mic34_bias, MicBias.LOW_POWER);
            } else {
                try self.writeRegister(.analog, AnalogReg.POWER_ON);
                try self.writeRegister(.mic12_bias, MicBias.NORMAL);
                try self.writeRegister(.mic34_bias, MicBias.NORMAL);
            }
        }

        /// Set mic bias voltage for MIC12 and MIC34
        pub fn setMicBias(self: *Self, bias12: u8, bias34: u8) !void {
            try self.writeRegister(.mic12_bias, bias12);
            try self.writeRegister(.mic34_bias, bias34);
        }

        /// Get current mic bias settings
        pub fn getMicBias(self: *Self) !struct { mic12: u8, mic34: u8 } {
            return .{
                .mic12 = try self.readRegister(.mic12_bias),
                .mic34 = try self.readRegister(.mic34_bias),
            };
        }

        /// Check if a specific mic channel is enabled
        pub fn isMicEnabled(self: *Self, channel: u2) bool {
            return switch (channel) {
                0 => self.config.mic_select.mic1,
                1 => self.config.mic_select.mic2,
                2 => self.config.mic_select.mic3,
                3 => self.config.mic_select.mic4,
            };
        }

        /// Get count of enabled microphones
        pub fn getEnabledMicCount(self: *Self) u8 {
            return self.config.mic_select.count();
        }

        // ====================================================================
        // Internal functions
        // ====================================================================

        fn start(self: *Self) !void {
            // Following ESP-ADF audio_hal/driver/es7210/es7210.c es7210_start
            try self.writeRegister(.clock_off, self.clock_off_reg);
            try self.writeRegister(.power_down, PowerDown.ALL_ON);
            try self.writeRegister(.analog, 0x43);
            try self.writeRegister(.mic1_power, 0x08);
            try self.writeRegister(.mic2_power, 0x08);
            try self.writeRegister(.mic3_power, 0x08);
            try self.writeRegister(.mic4_power, 0x08);
            try self.selectMics(self.config.mic_select);
            // Note: ESP-ADF audio_hal driver does NOT write reset registers here
            // The reset registers are only written in open()
        }

        fn stop(self: *Self) !void {
            try self.writeRegister(.mic1_power, MicPower.OFF);
            try self.writeRegister(.mic2_power, MicPower.OFF);
            try self.writeRegister(.mic3_power, MicPower.OFF);
            try self.writeRegister(.mic4_power, MicPower.OFF);
            try self.writeRegister(.mic12_power, MicPower.OFF);
            try self.writeRegister(.mic34_power, MicPower.OFF);
            try self.writeRegister(.analog, AnalogReg.LOW_POWER);
            try self.writeRegister(.clock_off, 0x7F);
            try self.writeRegister(.power_down, PowerDown.ALL_OFF);
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
