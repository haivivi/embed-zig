//! Board Configuration for WebSim gpio_button example

const hal = @import("hal");
const websim = @import("websim");

// ============================================================================
// LED Driver (adapts hal.Color to websim.Color)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();

    count: u32,

    pub fn init() !Self {
        websim.shared.addLog("WebSim: LED initialized");
        return .{ .count = websim.shared.led_count };
    }

    pub fn deinit(_: *Self) void {}

    pub fn setPixel(_: *Self, index: u32, color: hal.Color) void {
        if (index < websim.MAX_LEDS) {
            websim.shared.led_colors[index] = .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            };
        }
    }

    pub fn getPixelCount(self: *Self) u32 {
        return self.count;
    }

    pub fn refresh(_: *Self) void {}
};

// ============================================================================
// HAL Specs
// ============================================================================

const rtc_spec = struct {
    pub const Driver = websim.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

const button_spec = struct {
    pub const Driver = websim.ButtonDriver;
    pub const meta = .{ .id = "button.boot" };
};

const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.main" };
};

const spec = struct {
    pub const meta = .{ .id = "Simulator (WebSim)" };
    pub const ButtonId = enum(u8) { boot = 0 };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(rtc_spec);
    pub const log = websim.sal.log;
    pub const time = websim.sal.time;

    // Peripherals
    pub const button = hal.button.from(button_spec);
    pub const rgb_leds = hal.led_strip.from(led_spec);
};

pub const Board = hal.Board(spec);
