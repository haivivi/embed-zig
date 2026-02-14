//! WebSim WASM entry point for led_strip_anim
//!
//! Cooperative version: per-frame animation with auto mode cycling.

const hal = @import("hal");
const websim = @import("websim");
const platform = @import("platform.zig");

const Board = platform.Board;
const Color = hal.Color;
const log = websim.sal.log;

var board: Board = undefined;
var initialized: bool = false;

// Demo state
const DemoMode = enum {
    breathing,
    flash,
    rainbow,
    solid_red,
    solid_blue,
    solid_cyan,

    pub fn name(self: DemoMode) []const u8 {
        return switch (self) {
            .breathing => "Breathing",
            .flash => "Flash",
            .rainbow => "Rainbow",
            .solid_red => "Solid Red",
            .solid_blue => "Solid Blue",
            .solid_cyan => "Solid Cyan",
        };
    }

    pub fn next(self: DemoMode) DemoMode {
        return switch (self) {
            .breathing => .flash,
            .flash => .rainbow,
            .rainbow => .solid_red,
            .solid_red => .solid_blue,
            .solid_blue => .solid_cyan,
            .solid_cyan => .breathing,
        };
    }
};

var mode = DemoMode.breathing;
var mode_start_ms: u64 = 0;
const MODE_DURATION_MS: u64 = 5000;

// Animation functions
fn breathingAnimation(phase: u64) Color {
    const period_ms: u64 = 2000;
    const pos = phase % period_ms;
    const half = period_ms / 2;

    const brightness: u8 = if (pos < half)
        @intCast((pos * 255) / half)
    else
        @intCast(((period_ms - pos) * 255) / half);

    return Color.red.withBrightness(brightness);
}

fn flashAnimation(phase: u64) Color {
    const period_ms: u64 = 200;
    return if ((phase / period_ms) % 2 == 0) Color.white else Color.black;
}

fn rainbowAnimation(phase: u64) Color {
    const period_ms: u64 = 3000;
    const hue: u8 = @intCast(((phase % period_ms) * 255) / period_ms);
    return Color.hsv(hue, 255, 200);
}

pub fn init() void {
    board.init() catch {
        log.err("Board init failed", .{});
        return;
    };
    initialized = true;

    board.rgb_leds.setBrightness(180);

    log.info("LED Strip Animation - WebSim", .{});
    log.info("Board: {s}", .{Board.meta.id});
    log.info("Starting demo cycle (5 seconds per mode)", .{});
    log.info("Mode: {s}", .{mode.name()});
}

pub fn step() void {
    if (!initialized) return;

    const now_ms = board.uptime();

    // Initialize mode start time
    if (mode_start_ms == 0) {
        mode_start_ms = now_ms;
    }

    // Check for mode change
    if (now_ms - mode_start_ms >= MODE_DURATION_MS) {
        mode = mode.next();
        mode_start_ms = now_ms;

        log.info("Mode: {s}", .{mode.name()});

        // Flash white briefly on mode change
        board.rgb_leds.setColor(Color.white);
    }

    // Calculate animation color based on mode
    const color: Color = switch (mode) {
        .breathing => breathingAnimation(now_ms),
        .flash => flashAnimation(now_ms),
        .rainbow => rainbowAnimation(now_ms),
        .solid_red => Color.red,
        .solid_blue => Color.blue,
        .solid_cyan => Color.cyan,
    };

    board.rgb_leds.setColor(color);
}

comptime {
    websim.wasm.exportAll(@This());
}
