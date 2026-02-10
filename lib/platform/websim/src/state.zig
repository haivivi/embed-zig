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

/// Shared state between WASM (Zig) and JS.
///
/// JS reads this struct from WASM linear memory using the pointer
/// returned by the exported `getStatePtr()` function.
pub const SharedState = struct {
    // ======== Button State (offset 0) ========
    /// Current button pressed state (written by JS via exports)
    button_pressed: bool = false,
    /// Previous button state for edge detection (internal)
    button_prev: bool = false,
    /// Button press latch — sticky flag for fast clicks
    button_latch: bool = false,
    _btn_pad: u8 = 0,

    // ======== LED State (offset 4) ========
    /// Number of active LEDs
    led_count: u32 = 1,
    /// LED colors (r,g,b,pad per LED) — JS reads these to update DOM
    led_colors: [MAX_LEDS]Color = [_]Color{Color.black} ** MAX_LEDS,

    // ======== Time (offset 72) ========
    /// Current timestamp in ms (written by JS each frame)
    time_ms: u64 = 0,
    /// Start time for uptime calculation
    start_time_ms: u64 = 0,

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
    // Button API
    // ================================================================

    /// Called by JS (via WASM export) when button is pressed
    pub fn setButtonPressed(self: *SharedState, pressed: bool) void {
        self.button_pressed = pressed;
        if (pressed and !self.button_prev) {
            // Rising edge: set latch
            self.button_latch = true;
        }
        self.button_prev = pressed;
    }

    /// Poll button state for HAL driver.
    /// Returns true if pressed OR if press latch is set.
    /// Clears the latch after returning true.
    pub fn pollButtonState(self: *SharedState) bool {
        const held = self.button_pressed;
        const latched = self.button_latch;
        if (latched) self.button_latch = false;
        return held or latched;
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
