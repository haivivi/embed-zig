//! ESP-IDF I2S TDM (Time Division Multiplexing) Driver
//!
//! Provides I2S input for multi-channel audio codecs like ES7210.
//! Uses C helper functions to handle ESP-IDF's complex struct types.
//!
//! Usage:
//!   const idf = @import("esp");
//!   var i2s = try idf.I2sTdm.init(.{
//!       .port = 0,
//!       .sample_rate = 16000,
//!       .channels = 4,
//!       .bclk_pin = 9,
//!       .ws_pin = 45,
//!       .din_pin = 10,
//!       .mclk_pin = 16,
//!   });
//!   defer i2s.deinit();
//!
//!   try i2s.enable();
//!   const samples = try i2s.read(&buffer);

const std = @import("std");
const sys = @import("sys.zig");
const log = std.log.scoped(.i2s_tdm);

const c = @cImport({
    @cInclude("sdkconfig.h");
    @cInclude("driver/i2s_common.h");
});

// C helper functions (defined in i2s/tdm_helper.c)
extern fn i2s_tdm_helper_init_rx(
    port: c_int,
    sample_rate: u32,
    channels: c_int,
    bits_per_sample: c_int,
    bclk_pin: c_int,
    ws_pin: c_int,
    din_pin: c_int,
    mclk_pin: c_int,
    rx_handle: *c.i2s_chan_handle_t,
) c.esp_err_t;

extern fn i2s_tdm_helper_deinit(handle: c.i2s_chan_handle_t) c.esp_err_t;
extern fn i2s_tdm_helper_enable(handle: c.i2s_chan_handle_t) c.esp_err_t;
extern fn i2s_tdm_helper_disable(handle: c.i2s_chan_handle_t) c.esp_err_t;
extern fn i2s_tdm_helper_read(
    handle: c.i2s_chan_handle_t,
    buffer: [*]u8,
    buffer_size: usize,
    bytes_read: *usize,
    timeout_ms: u32,
) c.esp_err_t;

/// I2S TDM configuration
pub const Config = struct {
    /// I2S port number (0 or 1)
    port: u8 = 0,
    /// Sample rate in Hz
    sample_rate: u32 = 16000,
    /// Number of channels (slots)
    channels: u8 = 4,
    /// Bits per sample
    bits_per_sample: u8 = 16,
    /// Bit clock pin
    bclk_pin: u8,
    /// Word select (LRCK) pin
    ws_pin: u8,
    /// Data input pin (for RX)
    din_pin: u8,
    /// Master clock pin (optional)
    mclk_pin: ?u8 = null,
    /// MCLK multiple (256 or 384)
    mclk_multiple: u16 = 256,
};

/// I2S TDM driver (RX only for microphone input)
pub const I2sTdm = struct {
    const Self = @This();

    rx_handle: c.i2s_chan_handle_t,
    config: Config,
    enabled: bool = false,

    /// Initialize I2S TDM driver (RX only for microphone)
    pub fn init(config: Config) !Self {
        var self = Self{
            .rx_handle = null,
            .config = config,
        };

        const mclk_pin: c_int = if (config.mclk_pin) |pin| @intCast(pin) else -1;

        const result = i2s_tdm_helper_init_rx(
            @intCast(config.port),
            config.sample_rate,
            @intCast(config.channels),
            @intCast(config.bits_per_sample),
            @intCast(config.bclk_pin),
            @intCast(config.ws_pin),
            @intCast(config.din_pin),
            mclk_pin,
            &self.rx_handle,
        );

        try sys.espErrToZig(result);

        log.info("I2S TDM: Initialized port {} with {} channels at {}Hz", .{
            config.port,
            config.channels,
            config.sample_rate,
        });

        return self;
    }

    /// Deinitialize I2S TDM driver
    pub fn deinit(self: *Self) void {
        if (self.enabled) {
            self.disable() catch {};
        }

        if (self.rx_handle != null) {
            _ = i2s_tdm_helper_deinit(self.rx_handle);
            self.rx_handle = null;
        }

        log.info("I2S TDM: Deinitialized", .{});
    }

    /// Enable I2S channel
    pub fn enable(self: *Self) !void {
        if (self.enabled) return;

        if (self.rx_handle != null) {
            try sys.espErrToZig(i2s_tdm_helper_enable(self.rx_handle));
        }

        self.enabled = true;
        log.info("I2S TDM: Enabled", .{});
    }

    /// Disable I2S channel
    pub fn disable(self: *Self) !void {
        if (!self.enabled) return;

        if (self.rx_handle != null) {
            try sys.espErrToZig(i2s_tdm_helper_disable(self.rx_handle));
        }

        self.enabled = false;
        log.info("I2S TDM: Disabled", .{});
    }

    /// Read audio samples (blocking)
    ///
    /// Returns the number of samples read per channel.
    /// Buffer receives interleaved multi-channel data.
    /// For 4 channels: [ch0_s0, ch1_s0, ch2_s0, ch3_s0, ch0_s1, ch1_s1, ...]
    pub fn read(self: *Self, buffer: []i16) !usize {
        if (!self.enabled) return error.NotEnabled;
        if (self.rx_handle == null) return error.NoRxChannel;

        var bytes_read: usize = 0;
        const buffer_bytes = std.mem.sliceAsBytes(buffer);
        const timeout_ms: u32 = 1000;

        const result = i2s_tdm_helper_read(
            self.rx_handle,
            buffer_bytes.ptr,
            buffer_bytes.len,
            &bytes_read,
            timeout_ms,
        );

        try sys.espErrToZig(result);

        // Return number of samples (not bytes)
        return bytes_read / @sizeOf(i16);
    }

    /// Get samples per frame based on sample rate
    /// Returns samples for given duration in milliseconds
    pub fn samplesForMs(self: *const Self, duration_ms: u32) u32 {
        return self.config.sample_rate * duration_ms / 1000 * self.config.channels;
    }

    /// Check if RX channel is available
    pub fn hasRx(self: *const Self) bool {
        return self.rx_handle != null;
    }
};

/// Errors specific to I2S TDM
pub const I2sError = error{
    NotEnabled,
    NoRxChannel,
};
