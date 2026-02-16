//! BK7258 Board Implementation for GPIO Button Example
//!
//! Hardware:
//! - Boot button on GPIO22 (active low, pull-up)
//! - PWM LED on channel 0 (used as RGB LED substitute — single color)

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
};

// ============================================================================
// Drivers
// ============================================================================

pub const RtcDriver = board.RtcDriver;
pub const ButtonDriver = board.BootButtonDriver;

/// LED strip stub — BK7258 has no WS2812, use PWM LED as single-pixel strip
pub const LedStripDriver = struct {
    const Self = @This();
    const Color = hal.Color;

    led: board.LedDriver = .{},
    initialized: bool = false,

    pub fn init() !Self {
        var self = Self{};
        self.led = try board.LedDriver.init();
        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.led.deinit();
            self.initialized = false;
        }
    }

    pub fn setPixel(self: *Self, index: u32, color: Color) void {
        _ = index;
        // Map RGB brightness to single PWM duty
        const brightness: u16 = @as(u16, @max(color.r, @max(color.g, color.b)));
        self.led.setDuty(brightness * 257); // scale 0-255 to 0-65535
    }

    pub fn getPixelCount(_: *Self) u32 {
        return 1;
    }

    pub fn refresh(_: *Self) void {
        // PWM updates are immediate
    }

    pub fn clear(self: *Self) void {
        self.led.setDuty(0);
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const button_spec = struct {
    pub const Driver = ButtonDriver;
    pub const meta = .{ .id = "button.boot" };
};

pub const led_spec = struct {
    pub const Driver = LedStripDriver;
    pub const meta = .{ .id = "led.main" };
};

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
