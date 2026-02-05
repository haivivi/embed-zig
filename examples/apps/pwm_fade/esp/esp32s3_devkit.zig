//! ESP32-S3 DevKit Board Implementation - PWM Fade
//!
//! Hardware:
//! - Onboard LED on GPIO48 (controlled via LEDC PWM)

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const board = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const led_gpio: u8 = @intCast(board.led_strip_gpio);
    pub const pwm_freq_hz: u32 = 5000;
    pub const pwm_resolution_bits: u8 = 10; // 0-1023
};

// ============================================================================
// Drivers (re-export from central board)
// ============================================================================

pub const RtcDriver = board.RtcDriver;

// ============================================================================
// Led Driver (using ESP IDF PWM)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();

    pwm: idf.Pwm,

    pub fn init() !Self {
        const pwm = try idf.Pwm.init(.{
            .gpio = Hardware.led_gpio,
            .freq_hz = Hardware.pwm_freq_hz,
            .resolution_bits = Hardware.pwm_resolution_bits,
        });
        std.log.info("DevKit LedDriver: LEDC @ GPIO{} initialized", .{Hardware.led_gpio});
        std.log.info("  Frequency: {} Hz, Resolution: {} bits", .{
            Hardware.pwm_freq_hz,
            Hardware.pwm_resolution_bits,
        });
        return .{ .pwm = pwm };
    }

    pub fn deinit(self: *Self) void {
        self.pwm.deinit();
    }

    pub fn setDuty(self: *Self, duty: u16) void {
        self.pwm.setDuty(duty);
    }

    pub fn getDuty(self: *const Self) u16 {
        return self.pwm.getDuty();
    }

    pub fn fade(self: *Self, target: u16, duration_ms: u32) void {
        self.pwm.fade(target, duration_ms);
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.main" };
};

// Platform primitives (re-export from central board)
pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
