//! LED Strip (WS2812, SK6812) driver

const sys = @import("sys.zig");

/// LED pixel format
pub const PixelFormat = enum(c_uint) {
    grb = 0,
    grbw = 1,
};

/// LED model
pub const Model = enum(c_uint) {
    ws2812 = 0,
    sk6812 = 1,
};

/// LED strip configuration
pub const Config = extern struct {
    strip_gpio_num: c_int = 0,
    max_leds: u32 = 1,
    led_pixel_format: PixelFormat = .grb,
    led_model: Model = .ws2812,
    flags: u32 = 0,
};

/// RMT configuration
pub const RmtConfig = extern struct {
    clk_src: c_int = 0,
    resolution_hz: u32 = 10_000_000,
    mem_block_symbols: usize = 0,
    flags: u32 = 0,
};

/// Opaque LED strip handle
pub const Handle = opaque {};

// External C functions
extern fn led_strip_new_rmt_device(
    led_config: *const Config,
    rmt_config: *const RmtConfig,
    ret_strip: **Handle,
) sys.esp_err_t;

extern fn led_strip_set_pixel(
    strip: *Handle,
    index: u32,
    red: u32,
    green: u32,
    blue: u32,
) sys.esp_err_t;

extern fn led_strip_refresh(strip: *Handle) sys.esp_err_t;
extern fn led_strip_clear(strip: *Handle) sys.esp_err_t;
extern fn led_strip_del(strip: *Handle) sys.esp_err_t;

/// LED Strip wrapper with Zig-idiomatic API
pub const LedStrip = struct {
    handle: *Handle,

    pub fn init(config: Config, rmt_config: RmtConfig) !LedStrip {
        var handle: *Handle = undefined;
        try sys.espErrToZig(led_strip_new_rmt_device(&config, &rmt_config, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *LedStrip) void {
        _ = led_strip_del(self.handle);
    }

    pub fn setPixel(self: LedStrip, index: u32, r: u8, g: u8, b: u8) !void {
        try sys.espErrToZig(led_strip_set_pixel(self.handle, index, r, g, b));
    }

    pub fn refresh(self: LedStrip) !void {
        try sys.espErrToZig(led_strip_refresh(self.handle));
    }

    pub fn clear(self: LedStrip) !void {
        try sys.espErrToZig(led_strip_clear(self.handle));
    }

    /// Set pixel and refresh in one call
    pub fn setPixelAndRefresh(self: LedStrip, index: u32, r: u8, g: u8, b: u8) !void {
        try self.setPixel(index, r, g, b);
        try self.refresh();
    }
};
