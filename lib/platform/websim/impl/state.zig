//! WebSim Shared State
//!
//! Flat struct in WASM linear memory, readable from both Zig and JS.
//! JS reads this struct by offset from the pointer returned by getStatePtr().
//!
//! Memory layout is packed and stable — JS accesses fields by known offsets.

/// Maximum number of LEDs in a strip
pub const MAX_LEDS = 16;

/// RGB color for LED state
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    _pad: u8 = 0, // align to 4 bytes for easy JS access

    pub const black = Color{};
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const red = Color{ .r = 255 };
    pub const green = Color{ .g = 255 };
    pub const blue = Color{ .b = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

/// Log ring buffer size
pub const LOG_BUF_SIZE = 4096;
pub const LOG_LINE_MAX = 128;
pub const LOG_LINES_MAX = 32;

/// Maximum number of ADC buttons
pub const MAX_ADC_BUTTONS = 8;

/// Display framebuffer size (240x240 RGB565 = 115200 bytes)
pub const DISPLAY_WIDTH = 240;
pub const DISPLAY_HEIGHT = 240;
pub const DISPLAY_BPP = 2; // RGB565
pub const DISPLAY_FB_SIZE = DISPLAY_WIDTH * DISPLAY_HEIGHT * DISPLAY_BPP;

/// Shared state between WASM (Zig) and JS.
///
/// JS reads this via typed WASM export accessors (not raw memory offsets).
pub const SharedState = struct {
    // ======== Single Button (BOOT/Power) ========
    /// Current button pressed state (written by JS via exports)
    button_pressed: bool = false,
    /// Previous button state for edge detection (internal)
    button_prev: bool = false,
    /// Button press latch — sticky flag for fast clicks
    button_latch: bool = false,
    _btn_pad: u8 = 0,

    // ======== Power Button ========
    power_pressed: bool = false,
    power_prev: bool = false,
    power_latch: bool = false,
    _pwr_pad: u8 = 0,

    // ======== ADC Button Group ========
    /// Simulated ADC raw value — JS sets this based on which button is pressed.
    /// 4095 = no button pressed. Each button maps to an ADC range.
    adc_raw: u16 = 4095,

    // ======== LED State ========
    /// Number of active LEDs
    led_count: u32 = 1,
    /// LED colors (r,g,b,pad per LED) — JS reads these to update DOM
    led_colors: [MAX_LEDS]Color = [_]Color{Color.black} ** MAX_LEDS,

    // ======== Time ========
    /// Current timestamp in ms (written by JS each frame)
    time_ms: u64 = 0,
    /// Start time for uptime calculation
    start_time_ms: u64 = 0,

    // ======== Display Framebuffer ========
    /// LVGL flush writes here, JS reads for canvas rendering
    display_fb: [DISPLAY_FB_SIZE]u8 = [_]u8{0} ** DISPLAY_FB_SIZE,
    /// Dirty flag: set by flush, cleared by JS after rendering
    display_dirty: bool = false,

    // ======== Log Buffer ========
    /// Log line storage
    log_lines: [LOG_LINES_MAX][LOG_LINE_MAX]u8 = undefined,
    /// Length of each log line
    log_lens: [LOG_LINES_MAX]u16 = [_]u16{0} ** LOG_LINES_MAX,
    /// Total lines logged (may exceed LOG_LINES_MAX)
    log_count: u32 = 0,
    /// Next write index (ring buffer)
    log_next: u32 = 0,
    /// Flag: new log lines available (JS resets after reading)
    log_dirty: bool = false,

    // ======== Running Flag ========
    running: bool = true,

    // ================================================================
    // Single Button API (BOOT)
    // ================================================================

    pub fn setButtonPressed(self: *SharedState, pressed: bool) void {
        self.button_pressed = pressed;
        if (pressed and !self.button_prev) {
            self.button_latch = true;
        }
        self.button_prev = pressed;
    }

    pub fn pollButtonState(self: *SharedState) bool {
        const held = self.button_pressed;
        const latched = self.button_latch;
        if (latched) self.button_latch = false;
        return held or latched;
    }

    // ================================================================
    // Power Button API
    // ================================================================

    pub fn setPowerPressed(self: *SharedState, pressed: bool) void {
        self.power_pressed = pressed;
        if (pressed and !self.power_prev) {
            self.power_latch = true;
        }
        self.power_prev = pressed;
    }

    pub fn pollPowerState(self: *SharedState) bool {
        const held = self.power_pressed;
        const latched = self.power_latch;
        if (latched) self.power_latch = false;
        return held or latched;
    }

    // ================================================================
    // ADC Button Group API
    // ================================================================

    /// Read simulated ADC value (called by ButtonGroup driver)
    pub fn readAdc(self: *const SharedState) u16 {
        return self.adc_raw;
    }

    // ================================================================
    // Display API
    // ================================================================

    /// Write pixels to the framebuffer (called by display flush)
    pub fn displayFlush(self: *SharedState, x1: u16, y1: u16, x2: u16, y2: u16, data: [*]const u8) void {
        const w = @as(u32, x2 - x1 + 1);
        const line_bytes = w * DISPLAY_BPP;
        var y: u16 = y1;
        while (y <= y2) : (y += 1) {
            const fb_offset = (@as(u32, y) * DISPLAY_WIDTH + @as(u32, x1)) * DISPLAY_BPP;
            const src_offset = @as(u32, y - y1) * line_bytes;
            if (fb_offset + line_bytes <= DISPLAY_FB_SIZE) {
                const dst = self.display_fb[fb_offset..][0..line_bytes];
                const src = data[src_offset..][0..line_bytes];
                @memcpy(dst, src);
            }
        }
        self.display_dirty = true;
    }

    // ================================================================
    // Log API
    // ================================================================

    pub fn addLog(self: *SharedState, msg: []const u8) void {
        const len: u16 = @intCast(@min(msg.len, LOG_LINE_MAX));
        @memcpy(self.log_lines[self.log_next][0..len], msg[0..len]);
        self.log_lens[self.log_next] = len;
        self.log_next = (self.log_next + 1) % LOG_LINES_MAX;
        if (self.log_count < LOG_LINES_MAX) self.log_count += 1;
        self.log_dirty = true;
    }

    pub fn getLogLine(self: *const SharedState, idx: u32) ?[]const u8 {
        if (idx >= self.log_count) return null;
        const actual_idx = if (self.log_count < LOG_LINES_MAX)
            idx
        else
            (self.log_next + idx) % LOG_LINES_MAX;
        return self.log_lines[actual_idx][0..self.log_lens[actual_idx]];
    }

    // ================================================================
    // Time API
    // ================================================================

    pub fn uptime(self: *const SharedState) u64 {
        return self.time_ms - self.start_time_ms;
    }
};

/// Global shared state instance
pub var state: SharedState = .{};
