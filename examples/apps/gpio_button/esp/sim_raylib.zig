//! Raylib Simulator Board (sim_raylib)
//!
//! Provides simulated hardware for desktop testing with raylib UI.
//! Uses raysim package for shared state and SAL.

const hal = @import("hal");
const raysim = @import("raysim");

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = "Simulator (raylib)";
    pub const has_led = true;
    pub const led_type = "virtual";
    pub const led_count: u32 = 1;
};

// ============================================================================
// Re-export shared state from raysim
// ============================================================================

pub const sim_state = raysim.sim_state;

// ============================================================================
// LED Driver (uses hal.Color for type compatibility)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();

    count: u32,

    pub fn init() !Self {
        raysim.sim_state.addLog("Simulator: LED initialized");
        return .{ .count = raysim.sim_state.led_count };
    }

    pub fn deinit(_: *Self) void {}

    pub fn setPixel(_: *Self, index: u32, color: hal.Color) void {
        if (index < raysim.drivers.MAX_LEDS) {
            raysim.sim_state.led_colors[index] = .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            };
            raysim.sim_state_mod.debugLog("[LED] setPixel({}, rgb({},{},{}))\n", .{ index, color.r, color.g, color.b });
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

pub const rtc_spec = struct {
    pub const Driver = raysim.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const button_spec = struct {
    pub const Driver = raysim.ButtonDriver;
    pub const meta = .{ .id = "button.boot" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.main" };
};

// Platform primitives
pub const log = raysim.sal.log;
pub const time = raysim.sal.time;
pub const isRunning = raysim.sal.isRunning;
