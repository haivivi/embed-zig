//! LiChuang SZP Board Configuration for GPIO Button Test
//!
//! Uses pre-configured drivers from esp.boards.lichuang_szp

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const board = esp.boards.lichuang_szp;

// ============================================================================
// Re-export board definitions
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;
pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const boot_button_gpio = board.boot_button_gpio;
    pub const has_led = true;
    pub const led_type = "lcd_backlight";
    pub const led_count: u32 = 1;
};

// ============================================================================
// Drivers (from board)
// ============================================================================

pub const ButtonDriver = board.BootButtonDriver;
pub const LedDriver = board.LedDriver;
pub const RtcDriver = board.RtcDriver;

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
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.main" };
};
