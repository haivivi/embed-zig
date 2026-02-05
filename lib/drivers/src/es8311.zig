//! ES8311 Low Power Mono Audio Codec Driver
//!
//! Platform-independent driver for Everest Semiconductor ES8311
//! audio codec with DAC and ADC.
//!
//! Features:
//! - Single-channel ADC/DAC
//! - Configurable sample rates (8k-96k)
//! - Microphone gain control (0-42dB)
//! - DAC volume control
//! - I2S master/slave mode
//!
//! Usage:
//!   const Es8311 = drivers.Es8311(MyI2cBus);
//!   var codec = Es8311.init(i2c_bus, .{});
//!   try codec.open();
//!   try codec.setSampleRate(16000);
//!   try codec.setMicGain(.@"24dB");

const std = @import("std");
const trait = @import("trait");

/// ES8311 I2C address (7-bit)
pub const DEFAULT_ADDRESS: u7 = 0x18;

/// ES8311 register addresses
pub const Register = enum(u8) {
    // Reset
    reset = 0x00,

    // Clock Manager
    clk_manager_01 = 0x01,
    clk_manager_02 = 0x02,
    clk_manager_03 = 0x03,
    clk_manager_04 = 0x04,
    clk_manager_05 = 0x05,
    clk_manager_06 = 0x06,
    clk_manager_07 = 0x07,
    clk_manager_08 = 0x08,

    // Serial Data Port
    sdp_in = 0x09,
    sdp_out = 0x0A,

    // System
    system_0b = 0x0B,
    system_0c = 0x0C,
    system_0d = 0x0D,
    system_0e = 0x0E,
    system_0f = 0x0F,
    system_10 = 0x10,
    system_11 = 0x11,
    system_12 = 0x12,
    system_13 = 0x13,
    system_14 = 0x14,

    // ADC
    adc_15 = 0x15,
    adc_16 = 0x16, // MIC gain
    adc_17 = 0x17, // ADC volume
    adc_18 = 0x18,
    adc_19 = 0x19,
    adc_1a = 0x1A,
    adc_1b = 0x1B,
    adc_1c = 0x1C,

    // DAC
    dac_31 = 0x31, // DAC mute
    dac_32 = 0x32, // DAC volume
    dac_33 = 0x33,
    dac_34 = 0x34,
    dac_35 = 0x35,
    dac_37 = 0x37,

    // GPIO
    gpio_44 = 0x44,
    gp_45 = 0x45,

    // Chip ID
    chip_id1 = 0xFD,
    chip_id2 = 0xFE,
    chip_ver = 0xFF,
};

// ============================================================================
// Register Bit Field Constants
// ============================================================================

/// Reset register (0x00) bit fields
pub const ResetReg = struct {
    /// Chip state machine on
    pub const CSM_ON: u8 = 0x80;
    /// Master/slave mode control (1 = master)
    pub const MSC: u8 = 0x40;
    /// Slave mode value
    pub const SLAVE_MODE: u8 = 0xBF;
    /// All modules off
    pub const ALL_OFF: u8 = 0x1F;
    /// Soft reset sequence values
    pub const SOFT_RESET_1: u8 = 0x00;
    pub const SOFT_RESET_2: u8 = 0x1F;
};

/// Clock Manager 01 register (0x01) bit fields
pub const ClkManager01 = struct {
    /// All clocks on
    pub const MCLK_ON: u8 = 0x3F;
    /// All clocks off completely (used in stop/power-down)
    pub const ALL_OFF: u8 = 0x00;
    /// MCLK select internal (from BCLK)
    pub const MCLK_SEL_INTERNAL: u8 = 0x80;
    /// MCLK select external (from pad)
    pub const MCLK_SEL_EXTERNAL: u8 = 0x7F;
    /// MCLK invert
    pub const MCLK_INV: u8 = 0x40;
    /// Initial value (clocks off)
    pub const INIT_OFF: u8 = 0x30;
};

/// Clock Manager 06 register (0x06) bit fields
pub const ClkManager06 = struct {
    /// SCLK invert
    pub const SCLK_INV: u8 = 0x20;
    /// BCLK divider mask
    pub const BCLK_DIV_MASK: u8 = 0x1F;
};

/// SDP (Serial Data Port) register bit fields
pub const SdpReg = struct {
    /// Word length mask
    pub const WL_MASK: u8 = 0x1C;
    /// Word length shift
    pub const WL_SHIFT: u4 = 2;
    /// Format mask
    pub const FMT_MASK: u8 = 0x03;
    /// Left/right swap
    pub const LRP: u8 = 0x40;
};

/// GPIO 44 register (0x44) values
pub const Gpio44 = struct {
    /// I2C noise filter enabled (default)
    pub const I2C_FILTER: u8 = 0x08;
    /// DAC reference enabled for AEC (ADC right = DAC output)
    pub const DAC_REF_ENABLED: u8 = 0x58;
    /// DAC reference disabled (normal mode)
    pub const DAC_REF_DISABLED: u8 = 0x08;
};

/// DAC register (0x31) bit fields
pub const DacReg = struct {
    /// Mute mask
    pub const MUTE_MASK: u8 = 0x60;
    /// Mute value
    pub const MUTE: u8 = 0x60;
};

/// System register default values
pub const SystemDefaults = struct {
    /// System 0B initial value
    pub const SYS_0B_INIT: u8 = 0x00;
    /// System 0C initial value
    pub const SYS_0C_INIT: u8 = 0x00;
    /// System 0D startup value
    pub const SYS_0D_STARTUP: u8 = 0x01;
    /// System 0D init value
    pub const SYS_0D_INIT: u8 = 0x10;
    /// System 0E startup value
    pub const SYS_0E_STARTUP: u8 = 0x02;
    /// System 10 initial value
    pub const SYS_10_INIT: u8 = 0x1F;
    /// System 11 initial value
    pub const SYS_11_INIT: u8 = 0x7F;
    /// System 12 DAC enable
    pub const SYS_12_DAC_EN: u8 = 0x00;
    /// System 13 init
    pub const SYS_13_INIT: u8 = 0x10;
    /// System 14 startup
    pub const SYS_14_STARTUP: u8 = 0x1A;
    /// Digital mic enable
    pub const DMIC_ENABLE: u8 = 0x40;
};

/// ADC register defaults
pub const AdcDefaults = struct {
    /// ADC 15 startup
    pub const ADC_15_STARTUP: u8 = 0x40;
    /// ADC 16 default gain (24dB)
    pub const ADC_16_DEFAULT: u8 = 0x24;
    /// ADC 17 startup (volume)
    pub const ADC_17_STARTUP: u8 = 0xBF;
    /// ADC 1B init
    pub const ADC_1B_INIT: u8 = 0x0A;
    /// ADC 1C init
    pub const ADC_1C_INIT: u8 = 0x6A;
};

/// DAC register defaults
pub const DacDefaults = struct {
    /// DAC 37 startup
    pub const DAC_37_STARTUP: u8 = 0x08;
};

/// Microphone gain settings
pub const MicGain = enum(u8) {
    @"0dB" = 0,
    @"6dB" = 1,
    @"12dB" = 2,
    @"18dB" = 3,
    @"24dB" = 4,
    @"30dB" = 5,
    @"36dB" = 6,
    @"42dB" = 7,

    pub fn fromDb(db: i8) MicGain {
        if (db < 6) return .@"0dB";
        if (db < 12) return .@"6dB";
        if (db < 18) return .@"12dB";
        if (db < 24) return .@"18dB";
        if (db < 30) return .@"24dB";
        if (db < 36) return .@"30dB";
        if (db < 42) return .@"36dB";
        return .@"42dB";
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
    @"16bit" = 0b0011,
    @"24bit" = 0b0000,
    @"32bit" = 0b0100,
};

/// Codec working mode
pub const CodecMode = enum {
    adc_only,
    dac_only,
    both,
};

/// Clock coefficient structure for sample rate configuration
const ClockCoeff = struct {
    mclk: u32,
    rate: u32,
    pre_div: u8,
    pre_multi: u8,
    adc_div: u8,
    dac_div: u8,
    fs_mode: u8,
    lrck_h: u8,
    lrck_l: u8,
    bclk_div: u8,
    adc_osr: u8,
    dac_osr: u8,
};

/// Clock coefficient table for common sample rates
const clock_coeffs = [_]ClockCoeff{
    // 8kHz
    .{ .mclk = 12288000, .rate = 8000, .pre_div = 0x06, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x20 },
    .{ .mclk = 4096000, .rate = 8000, .pre_div = 0x02, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x20 },
    .{ .mclk = 2048000, .rate = 8000, .pre_div = 0x01, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x20 },
    // 16kHz
    .{ .mclk = 12288000, .rate = 16000, .pre_div = 0x03, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x20 },
    .{ .mclk = 4096000, .rate = 16000, .pre_div = 0x01, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x20 },
    .{ .mclk = 2048000, .rate = 16000, .pre_div = 0x01, .pre_multi = 0x02, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x20 },
    // 32kHz
    .{ .mclk = 12288000, .rate = 32000, .pre_div = 0x03, .pre_multi = 0x02, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x10 },
    .{ .mclk = 8192000, .rate = 32000, .pre_div = 0x01, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x10 },
    // 44.1kHz
    .{ .mclk = 11289600, .rate = 44100, .pre_div = 0x01, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x10 },
    // 48kHz
    .{ .mclk = 12288000, .rate = 48000, .pre_div = 0x01, .pre_multi = 0x01, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x10 },
    .{ .mclk = 6144000, .rate = 48000, .pre_div = 0x01, .pre_multi = 0x02, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x10 },
    // 96kHz
    .{ .mclk = 12288000, .rate = 96000, .pre_div = 0x01, .pre_multi = 0x02, .adc_div = 0x01, .dac_div = 0x01, .fs_mode = 0x00, .lrck_h = 0x00, .lrck_l = 0xff, .bclk_div = 0x04, .adc_osr = 0x10, .dac_osr = 0x10 },
};

/// Configuration for ES8311
pub const Config = struct {
    /// I2C address (default 0x18)
    address: u7 = DEFAULT_ADDRESS,
    /// Work as I2S master or slave
    master_mode: bool = false,
    /// Use external MCLK
    use_mclk: bool = true,
    /// Invert MCLK signal
    invert_mclk: bool = false,
    /// Invert SCLK signal
    invert_sclk: bool = false,
    /// Use digital microphone
    digital_mic: bool = false,
    /// Codec working mode
    codec_mode: CodecMode = .both,
    /// MCLK/LRCK ratio (default 256)
    mclk_div: u16 = 256,
    /// When recording 2-channel data:
    /// false: right channel filled with DAC output (for AEC reference)
    /// true: right channel is empty
    no_dac_ref: bool = false,
};

/// ES8311 Audio Codec Driver
/// Generic over I2C bus type for platform independence
pub fn Es8311(comptime I2cImpl: type) type {
    const I2c = trait.i2c.from(I2cImpl);

    return struct {
        const Self = @This();

        i2c: I2c,
        config: Config,
        is_open: bool = false,
        enabled: bool = false,

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

        /// Open and initialize the codec
        pub fn open(self: *Self) !void {
            // Enhance I2C noise immunity (write twice for reliability)
            try self.writeRegister(.gpio_44, Gpio44.I2C_FILTER);
            try self.writeRegister(.gpio_44, Gpio44.I2C_FILTER);

            // Initial register setup
            try self.writeRegister(.clk_manager_01, ClkManager01.INIT_OFF);
            try self.writeRegister(.clk_manager_02, 0x00);
            try self.writeRegister(.clk_manager_03, 0x10);
            try self.writeRegister(.adc_16, AdcDefaults.ADC_16_DEFAULT);
            try self.writeRegister(.clk_manager_04, 0x10);
            try self.writeRegister(.clk_manager_05, 0x00);
            try self.writeRegister(.system_0b, SystemDefaults.SYS_0B_INIT);
            try self.writeRegister(.system_0c, SystemDefaults.SYS_0C_INIT);
            try self.writeRegister(.system_10, SystemDefaults.SYS_10_INIT);
            try self.writeRegister(.system_11, SystemDefaults.SYS_11_INIT);
            try self.writeRegister(.reset, ResetReg.CSM_ON);

            // Set master/slave mode
            var regv = try self.readRegister(.reset);
            if (self.config.master_mode) {
                regv |= ResetReg.MSC;
            } else {
                regv &= ResetReg.SLAVE_MODE;
            }
            try self.writeRegister(.reset, regv);

            // Configure MCLK source
            regv = ClkManager01.MCLK_ON;
            if (self.config.use_mclk) {
                regv &= ClkManager01.MCLK_SEL_EXTERNAL;
            } else {
                regv |= ClkManager01.MCLK_SEL_INTERNAL;
            }
            if (self.config.invert_mclk) {
                regv |= ClkManager01.MCLK_INV;
            } else {
                regv &= ~ClkManager01.MCLK_INV;
            }
            try self.writeRegister(.clk_manager_01, regv);

            // Configure SCLK inversion
            regv = try self.readRegister(.clk_manager_06);
            if (self.config.invert_sclk) {
                regv |= ClkManager06.SCLK_INV;
            } else {
                regv &= ~ClkManager06.SCLK_INV;
            }
            try self.writeRegister(.clk_manager_06, regv);

            // Additional initialization
            try self.writeRegister(.system_13, SystemDefaults.SYS_13_INIT);
            try self.writeRegister(.adc_1b, AdcDefaults.ADC_1B_INIT);
            try self.writeRegister(.adc_1c, AdcDefaults.ADC_1C_INIT);

            // Configure DAC reference for AEC
            if (!self.config.no_dac_ref) {
                // Set internal reference signal (ADCL + DACR)
                try self.writeRegister(.gpio_44, Gpio44.DAC_REF_ENABLED);
            } else {
                try self.writeRegister(.gpio_44, Gpio44.DAC_REF_DISABLED);
            }

            self.is_open = true;
        }

        /// Close the codec
        pub fn close(self: *Self) !void {
            if (self.is_open) {
                try self.standby();
                self.is_open = false;
            }
        }

        /// Enable or disable the codec
        pub fn enable(self: *Self, en: bool) !void {
            if (!self.is_open) return error.NotOpen;
            if (en == self.enabled) return;

            if (en) {
                try self.start();
            } else {
                try self.standby();
            }
            self.enabled = en;
        }

        /// Configure sample rate
        pub fn setSampleRate(self: *Self, sample_rate: u32) !void {
            const mclk_freq = sample_rate * self.config.mclk_div;
            const coeff = getClockCoeff(mclk_freq, sample_rate) orelse return error.UnsupportedSampleRate;

            var regv = try self.readRegister(.clk_manager_02);
            regv &= 0x07;
            regv |= (coeff.pre_div - 1) << 5;

            const pre_multi_bits: u8 = switch (coeff.pre_multi) {
                1 => 0,
                2 => 1,
                4 => 2,
                8 => 3,
                else => 0,
            };

            if (!self.config.use_mclk) {
                // Use BCLK as clock source
                regv |= 3 << 3;
            } else {
                regv |= pre_multi_bits << 3;
            }
            try self.writeRegister(.clk_manager_02, regv);

            // Set ADC/DAC divider
            regv = 0x00;
            regv |= (coeff.adc_div - 1) << 4;
            regv |= (coeff.dac_div - 1);
            try self.writeRegister(.clk_manager_05, regv);

            // Set ADC OSR
            regv = try self.readRegister(.clk_manager_03);
            regv &= 0x80;
            regv |= coeff.fs_mode << 6;
            regv |= coeff.adc_osr;
            try self.writeRegister(.clk_manager_03, regv);

            // Set DAC OSR
            regv = try self.readRegister(.clk_manager_04);
            regv &= 0x80;
            regv |= coeff.dac_osr;
            try self.writeRegister(.clk_manager_04, regv);

            // Set LRCK divider
            regv = try self.readRegister(.clk_manager_07);
            regv &= 0xC0;
            regv |= coeff.lrck_h;
            try self.writeRegister(.clk_manager_07, regv);
            try self.writeRegister(.clk_manager_08, coeff.lrck_l);

            // Set BCLK divider
            regv = try self.readRegister(.clk_manager_06);
            regv &= 0xE0;
            if (coeff.bclk_div < 19) {
                regv |= coeff.bclk_div - 1;
            } else {
                regv |= coeff.bclk_div;
            }
            try self.writeRegister(.clk_manager_06, regv);
        }

        /// Set bits per sample
        pub fn setBitsPerSample(self: *Self, bits: BitsPerSample) !void {
            var dac_iface = try self.readRegister(.sdp_in);
            var adc_iface = try self.readRegister(.sdp_out);

            dac_iface &= ~SdpReg.WL_MASK;
            adc_iface &= ~SdpReg.WL_MASK;

            const bits_val = @intFromEnum(bits);
            dac_iface |= bits_val << SdpReg.WL_SHIFT;
            adc_iface |= bits_val << SdpReg.WL_SHIFT;

            try self.writeRegister(.sdp_in, dac_iface);
            try self.writeRegister(.sdp_out, adc_iface);
        }

        /// Set I2S format
        pub fn setFormat(self: *Self, fmt: I2sFormat) !void {
            var dac_iface = try self.readRegister(.sdp_in);
            var adc_iface = try self.readRegister(.sdp_out);

            dac_iface &= ~SdpReg.FMT_MASK;
            adc_iface &= ~SdpReg.FMT_MASK;
            dac_iface |= @intFromEnum(fmt);
            adc_iface |= @intFromEnum(fmt);

            try self.writeRegister(.sdp_in, dac_iface);
            try self.writeRegister(.sdp_out, adc_iface);
        }

        /// Set microphone gain (0-42dB in 6dB steps)
        pub fn setMicGain(self: *Self, gain: MicGain) !void {
            try self.writeRegister(.adc_16, @intFromEnum(gain));
        }

        /// Set microphone gain from dB value
        pub fn setMicGainDb(self: *Self, db: i8) !void {
            try self.setMicGain(MicGain.fromDb(db));
        }

        /// Set DAC volume (0-255, where 0 = -95.5dB, 255 = +32dB)
        pub fn setVolume(self: *Self, volume: u8) !void {
            try self.writeRegister(.dac_32, volume);
        }

        /// Get current DAC volume
        pub fn getVolume(self: *Self) !u8 {
            return self.readRegister(.dac_32);
        }

        /// Mute or unmute DAC output
        pub fn setMute(self: *Self, mute: bool) !void {
            var regv = try self.readRegister(.dac_31);
            regv &= ~DacReg.MUTE_MASK;
            if (mute) {
                regv |= DacReg.MUTE;
            }
            try self.writeRegister(.dac_31, regv);
        }

        /// Read chip ID
        pub fn readChipId(self: *Self) !u16 {
            const id1 = try self.readRegister(.chip_id1);
            const id2 = try self.readRegister(.chip_id2);
            return (@as(u16, id1) << 8) | id2;
        }

        /// Enable/disable DAC reference signal for AEC
        /// When enabled, ADC right channel contains DAC output for echo cancellation
        pub fn setDacReference(self: *Self, en: bool) !void {
            const val: u8 = if (en) Gpio44.DAC_REF_ENABLED else Gpio44.DAC_REF_DISABLED;
            try self.writeRegister(.gpio_44, val);
        }

        /// Get current ADC volume
        pub fn getAdcVolume(self: *Self) !u8 {
            return self.readRegister(.adc_17);
        }

        /// Set ADC volume (0-255)
        pub fn setAdcVolume(self: *Self, volume: u8) !void {
            try self.writeRegister(.adc_17, volume);
        }

        // ====================================================================
        // Internal functions
        // ====================================================================

        fn start(self: *Self) !void {
            var regv: u8 = ResetReg.CSM_ON;
            if (self.config.master_mode) {
                regv |= ResetReg.MSC;
            }
            try self.writeRegister(.reset, regv);

            regv = ClkManager01.MCLK_ON;
            if (self.config.use_mclk) {
                regv &= ClkManager01.MCLK_SEL_EXTERNAL;
            } else {
                regv |= ClkManager01.MCLK_SEL_INTERNAL;
            }
            if (self.config.invert_mclk) {
                regv |= ClkManager01.MCLK_INV;
            }
            try self.writeRegister(.clk_manager_01, regv);

            // Configure SDP interfaces based on codec mode
            var dac_iface = try self.readRegister(.sdp_in);
            var adc_iface = try self.readRegister(.sdp_out);
            dac_iface &= ~SdpReg.LRP;
            adc_iface &= ~SdpReg.LRP;

            switch (self.config.codec_mode) {
                .adc_only => adc_iface &= ~SdpReg.LRP,
                .dac_only => dac_iface &= ~SdpReg.LRP,
                .both => {
                    adc_iface &= ~SdpReg.LRP;
                    dac_iface &= ~SdpReg.LRP;
                },
            }

            try self.writeRegister(.sdp_in, dac_iface);
            try self.writeRegister(.sdp_out, adc_iface);

            try self.writeRegister(.adc_17, AdcDefaults.ADC_17_STARTUP);
            try self.writeRegister(.system_0e, SystemDefaults.SYS_0E_STARTUP);

            if (self.config.codec_mode == .dac_only or self.config.codec_mode == .both) {
                try self.writeRegister(.system_12, SystemDefaults.SYS_12_DAC_EN);
            }

            try self.writeRegister(.system_14, SystemDefaults.SYS_14_STARTUP);

            // Configure digital mic
            regv = try self.readRegister(.system_14);
            if (self.config.digital_mic) {
                regv |= SystemDefaults.DMIC_ENABLE;
            } else {
                regv &= ~SystemDefaults.DMIC_ENABLE;
            }
            try self.writeRegister(.system_14, regv);

            try self.writeRegister(.system_0d, SystemDefaults.SYS_0D_STARTUP);
            try self.writeRegister(.adc_15, AdcDefaults.ADC_15_STARTUP);
            try self.writeRegister(.dac_37, DacDefaults.DAC_37_STARTUP);
            try self.writeRegister(.gp_45, 0x00);
        }

        fn standby(self: *Self) !void {
            try self.writeRegister(.dac_32, 0x00);
            try self.writeRegister(.adc_17, 0x00);
            try self.writeRegister(.system_0e, 0xFF);
            try self.writeRegister(.system_12, 0x02);
            try self.writeRegister(.system_14, 0x00);
            try self.writeRegister(.system_0d, 0xFA);
            try self.writeRegister(.adc_15, 0x00);
            try self.writeRegister(.clk_manager_02, 0x10);
            try self.writeRegister(.reset, ResetReg.SOFT_RESET_1);
            try self.writeRegister(.reset, ResetReg.ALL_OFF);
            try self.writeRegister(.clk_manager_01, ClkManager01.INIT_OFF);
            try self.writeRegister(.clk_manager_01, ClkManager01.ALL_OFF);
            try self.writeRegister(.gp_45, 0x00);
            try self.writeRegister(.system_0d, 0xFC);
            try self.writeRegister(.clk_manager_02, 0x00);
        }

        fn getClockCoeff(mclk: u32, rate: u32) ?ClockCoeff {
            for (clock_coeffs) |coeff| {
                if (coeff.mclk == mclk and coeff.rate == rate) {
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

test "Es8311 basic operations" {
    var mock = MockI2c{};
    var codec = Es8311(*MockI2c).init(&mock, .{});

    // Test open
    try codec.open();
    try std.testing.expect(codec.is_open);

    // Test set mic gain
    try codec.setMicGain(.@"24dB");
    try std.testing.expectEqual(@as(u8, 4), mock.registers[@intFromEnum(Register.adc_16)]);

    // Test set volume
    try codec.setVolume(128);
    try std.testing.expectEqual(@as(u8, 128), mock.registers[@intFromEnum(Register.dac_32)]);
}

test "MicGain fromDb" {
    try std.testing.expectEqual(MicGain.@"0dB", MicGain.fromDb(0));
    try std.testing.expectEqual(MicGain.@"6dB", MicGain.fromDb(6));
    try std.testing.expectEqual(MicGain.@"24dB", MicGain.fromDb(24));
    try std.testing.expectEqual(MicGain.@"42dB", MicGain.fromDb(50));
}
