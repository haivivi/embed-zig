//! ESP-IDF I2S Bus Abstraction
//!
//! Provides I2S bus initialization and access for audio devices.
//! Supports full-duplex operation (simultaneous TX and RX on same port).
//!
//! Usage:
//!   const idf = @import("esp");
//!
//!   // Initialize I2S bus with full-duplex (mic + speaker)
//!   var i2s = try idf.I2s.init(.{
//!       .port = 0,
//!       .sample_rate = 16000,
//!       .rx_channels = 4,  // 4-ch TDM for mic
//!       .bclk_pin = 9,
//!       .ws_pin = 45,
//!       .din_pin = 10,     // mic input
//!       .dout_pin = 8,     // speaker output
//!       .mclk_pin = 16,
//!   });
//!   defer i2s.deinit();
//!
//!   // Enable channels
//!   try i2s.enableRx();
//!   try i2s.enableTx();
//!
//!   // Read/write audio
//!   const n = try i2s.read(&buffer);
//!   const m = try i2s.write(&data);

const std = @import("std");
const log = std.log.scoped(.i2s);
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("sdkconfig.h");
    @cInclude("driver/i2s_common.h");
});

// C helper functions
extern fn i2s_helper_init_std_duplex(
    port: c_int,
    sample_rate: u32,
    bits_per_sample: c_int,
    bclk_pin: c_int,
    ws_pin: c_int,
    din_pin: c_int,
    dout_pin: c_int,
    mclk_pin: c_int,
) c.esp_err_t;

extern fn i2s_helper_init_full_duplex(
    port: c_int,
    sample_rate: u32,
    rx_channels: c_int,
    bits_per_sample: c_int,
    bclk_pin: c_int,
    ws_pin: c_int,
    din_pin: c_int,
    dout_pin: c_int,
    mclk_pin: c_int,
) c.esp_err_t;

extern fn i2s_helper_deinit(port: c_int) c.esp_err_t;
extern fn i2s_helper_get_rx_handle(port: c_int) c.i2s_chan_handle_t;
extern fn i2s_helper_get_tx_handle(port: c_int) c.i2s_chan_handle_t;
extern fn i2s_helper_enable_rx(port: c_int) c.esp_err_t;
extern fn i2s_helper_disable_rx(port: c_int) c.esp_err_t;
extern fn i2s_helper_enable_tx(port: c_int) c.esp_err_t;
extern fn i2s_helper_disable_tx(port: c_int) c.esp_err_t;
extern fn i2s_helper_read(
    port: c_int,
    buffer: [*]u8,
    buffer_size: usize,
    bytes_read: *usize,
    timeout_ms: u32,
) c.esp_err_t;
extern fn i2s_helper_write(
    port: c_int,
    buffer: [*]const u8,
    buffer_size: usize,
    bytes_written: *usize,
    timeout_ms: u32,
) c.esp_err_t;

/// I2S mode selection
pub const Mode = enum {
    /// Standard stereo mode (2 channels)
    /// Use this when ES7210 is configured with internal TDM mode.
    /// ES7210 TDM output: Ch1, Ch3, Ch2, Ch4 packed into 32-bit stereo:
    ///   L (32-bit) = [MIC1 (HI)] + [MIC3/REF (LO)]
    ///   R (32-bit) = [MIC2 (HI)] + [MIC4 (LO)]
    std,
    /// TDM multi-channel mode (up to 4 channels)
    tdm,
};

/// I2S configuration
pub const Config = struct {
    /// I2S port number (0 or 1)
    port: u8 = 0,
    /// Sample rate in Hz
    sample_rate: u32 = 16000,
    /// I2S mode: std (stereo) or tdm (multi-channel)
    mode: Mode = .std,
    /// Number of RX channels (1-4 for TDM, ignored for STD mode)
    rx_channels: u8 = 0,
    /// Bits per sample
    bits_per_sample: u8 = 32,
    /// Bit clock pin
    bclk_pin: u8,
    /// Word select (LRCK) pin
    ws_pin: u8,
    /// Data input pin (null = no RX)
    din_pin: ?u8 = null,
    /// Data output pin (null = no TX)
    dout_pin: ?u8 = null,
    /// Master clock pin (null = disabled)
    mclk_pin: ?u8 = null,
};

/// I2S bus instance
pub const I2s = struct {
    const Self = @This();

    config: Config,
    rx_enabled: bool = false,
    tx_enabled: bool = false,
    initialized: bool = false,

    /// Initialize I2S bus
    pub fn init(config: Config) !Self {
        const din: c_int = if (config.din_pin) |p| @intCast(p) else -1;
        const dout: c_int = if (config.dout_pin) |p| @intCast(p) else -1;
        const mclk: c_int = if (config.mclk_pin) |p| @intCast(p) else -1;

        const result = switch (config.mode) {
            .std => i2s_helper_init_std_duplex(
                @intCast(config.port),
                config.sample_rate,
                @intCast(config.bits_per_sample),
                @intCast(config.bclk_pin),
                @intCast(config.ws_pin),
                din,
                dout,
                mclk,
            ),
            .tdm => i2s_helper_init_full_duplex(
                @intCast(config.port),
                config.sample_rate,
                @intCast(config.rx_channels),
                @intCast(config.bits_per_sample),
                @intCast(config.bclk_pin),
                @intCast(config.ws_pin),
                din,
                dout,
                mclk,
            ),
        };

        try sys.espErrToZig(result);

        log.info("I2S bus initialized: port={}, mode={s}, rate={}Hz, bits={}", .{
            config.port,
            @tagName(config.mode),
            config.sample_rate,
            config.bits_per_sample,
        });

        return Self{
            .config = config,
            .initialized = true,
        };
    }

    /// Deinitialize I2S bus
    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            if (self.rx_enabled) {
                self.disableRx() catch {};
            }
            if (self.tx_enabled) {
                self.disableTx() catch {};
            }
            _ = i2s_helper_deinit(@intCast(self.config.port));
            self.initialized = false;
            log.info("I2S bus deinitialized: port={}", .{self.config.port});
        }
    }

    /// Enable RX channel
    pub fn enableRx(self: *Self) !void {
        if (!self.initialized) return error.NotInitialized;
        if (self.rx_enabled) return;
        try sys.espErrToZig(i2s_helper_enable_rx(@intCast(self.config.port)));
        self.rx_enabled = true;
        log.info("I2S RX enabled: port={}", .{self.config.port});
    }

    /// Disable RX channel
    pub fn disableRx(self: *Self) !void {
        if (!self.rx_enabled) return;
        try sys.espErrToZig(i2s_helper_disable_rx(@intCast(self.config.port)));
        self.rx_enabled = false;
        log.info("I2S RX disabled: port={}", .{self.config.port});
    }

    /// Enable TX channel
    pub fn enableTx(self: *Self) !void {
        if (!self.initialized) return error.NotInitialized;
        if (self.tx_enabled) return;
        try sys.espErrToZig(i2s_helper_enable_tx(@intCast(self.config.port)));
        self.tx_enabled = true;
        log.info("I2S TX enabled: port={}", .{self.config.port});
    }

    /// Disable TX channel
    pub fn disableTx(self: *Self) !void {
        if (!self.tx_enabled) return;
        try sys.espErrToZig(i2s_helper_disable_tx(@intCast(self.config.port)));
        self.tx_enabled = false;
        log.info("I2S TX disabled: port={}", .{self.config.port});
    }

    /// Read audio data from RX channel
    pub fn read(self: *Self, buffer: []u8) !usize {
        if (!self.initialized) return error.NotInitialized;
        if (!self.rx_enabled) {
            try self.enableRx();
        }

        var bytes_read: usize = 0;
        const timeout_ms: u32 = 1000;

        const result = i2s_helper_read(
            @intCast(self.config.port),
            buffer.ptr,
            buffer.len,
            &bytes_read,
            timeout_ms,
        );

        try sys.espErrToZig(result);
        return bytes_read;
    }

    /// Write audio data to TX channel
    pub fn write(self: *Self, buffer: []const u8) !usize {
        if (!self.initialized) return error.NotInitialized;
        if (!self.tx_enabled) {
            try self.enableTx();
        }

        var bytes_written: usize = 0;
        const timeout_ms: u32 = 1000;

        const result = i2s_helper_write(
            @intCast(self.config.port),
            buffer.ptr,
            buffer.len,
            &bytes_written,
            timeout_ms,
        );

        try sys.espErrToZig(result);
        return bytes_written;
    }

    /// Get port number
    pub fn getPort(self: *const Self) u8 {
        return self.config.port;
    }
};
