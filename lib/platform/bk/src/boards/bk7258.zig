//! Hardware Definition & Drivers: BK7258
//!
//! This file defines hardware configuration and provides pre-configured drivers
//! for the BK7258 development board.
//!
//! Usage:
//!   const board = bk.boards.bk7258;
//!   pub const WifiDriver = board.WifiDriver;
//!   pub const RtcDriver = board.RtcDriver;

const armino = @import("../../armino/src/armino.zig");
const impl = @import("../../impl/src/impl.zig");

// ============================================================================
// Board Identification
// ============================================================================

pub const name = "BK7258";
pub const serial_port = "/dev/cu.usbserial-130";

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = impl.log.scoped("app");

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        impl.Time.sleepMs(ms);
    }
    pub fn getTimeMs() u64 {
        return impl.Time.getTimeMs();
    }
};

pub fn isRunning() bool {
    return true;
}

// ============================================================================
// Socket (LWIP)
// ============================================================================

pub const socket = impl.Socket;

// ============================================================================
// RTC Driver (uptime from AON RTC)
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return armino.time.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null; // No wall-clock RTC on BK7258
    }
};

// ============================================================================
// WiFi (hal.wifi compatible)
// ============================================================================

pub const WifiDriver = impl.WifiDriver;
pub const wifi_spec = impl.wifi.wifi_spec;

// ============================================================================
// Net (hal.net compatible)
// ============================================================================

pub const NetDriver = impl.NetDriver;
pub const net_spec = impl.net.net_spec;

// ============================================================================
// Button Driver (GPIO-based)
// ============================================================================

pub fn ButtonDriver(comptime gpio_pin: u32, comptime active_low: bool) type {
    return struct {
        const Self = @This();

        initialized: bool = false,

        pub fn init() !Self {
            armino.gpio.enableInput(gpio_pin) catch return error.InitFailed;
            if (active_low) {
                armino.gpio.pullUp(gpio_pin) catch {};
            }
            return .{ .initialized = true };
        }

        pub fn deinit(self: *Self) void {
            self.initialized = false;
        }

        pub fn isPressed(_: *const Self) bool {
            const level = armino.gpio.getInput(gpio_pin);
            return if (active_low) !level else level;
        }
    };
}

// ============================================================================
// LED Driver (PWM-based single LED)
// ============================================================================

pub fn PwmLedDriver(comptime pwm_channel: u32, comptime period_us: u32) type {
    return struct {
        const Self = @This();
        const MAX_DUTY: u16 = 65535;

        duty: u16 = 0,
        initialized: bool = false,

        pub fn init() !Self {
            armino.pwm.init(pwm_channel, period_us, 0) catch return error.InitFailed;
            armino.pwm.start(pwm_channel) catch return error.InitFailed;
            return .{ .initialized = true };
        }

        pub fn deinit(self: *Self) void {
            if (self.initialized) {
                armino.pwm.stop(pwm_channel) catch {};
                self.initialized = false;
            }
        }

        pub fn setDuty(self: *Self, duty: u16) void {
            self.duty = duty;
            // Map u16 duty (0-65535) to PWM period (0-period_us)
            const hw_duty: u32 = @as(u32, duty) * period_us / MAX_DUTY;
            armino.pwm.setDuty(pwm_channel, hw_duty) catch {};
        }

        pub fn getDuty(self: *const Self) u16 {
            return self.duty;
        }

        pub fn fade(self: *Self, target: u16, duration_ms: u32) void {
            // Software fade: step from current to target over duration
            const steps: u32 = duration_ms / 10; // 10ms per step
            if (steps == 0) {
                self.setDuty(target);
                return;
            }
            const current = self.duty;
            var i: u32 = 0;
            while (i <= steps) : (i += 1) {
                const progress = @as(u32, i) * 65535 / steps;
                const new_duty: u16 = @intCast(
                    (@as(u32, current) * (65535 - progress) + @as(u32, target) * progress) / 65535,
                );
                self.setDuty(new_duty);
                armino.time.sleepMs(10);
            }
        }
    };
}

// ============================================================================
// Speaker Driver (onboard DAC via audio pipeline)
// ============================================================================

pub const SpeakerDriver = struct {
    const Self = @This();

    speaker: ?armino.speaker.Speaker = null,

    pub fn init() !Self {
        return .{};
    }

    /// Initialize speaker with audio config.
    /// shared_i2c and shared_i2s are ignored on BK (onboard DAC, no external bus).
    pub fn initWithShared(self: *Self, _: anytype, _: anytype) !void {
        self.speaker = armino.speaker.Speaker.init(
            audio.sample_rate,
            audio.channels,
            audio.bits,
            audio.dig_gain,
        ) catch return error.InitFailed;
    }

    pub fn deinit(self: *Self) void {
        if (self.speaker) |*s| {
            s.deinit();
        }
        self.speaker = null;
    }

    pub fn write(self: *Self, buffer: []const i16) !usize {
        if (self.speaker) |*s| {
            return s.write(buffer);
        }
        return error.NotInitialized;
    }

    pub fn setVolume(self: *Self, volume: u8) !void {
        _ = self;
        _ = volume;
        // BK onboard DAC has fixed gain set at init time
    }
};

/// Dummy PA switch for BK (onboard DAC, no external PA)
pub const PaSwitchDriver = struct {
    const Self = @This();

    pub fn init(_: anytype) !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn on(_: *Self) !void {}
    pub fn off(_: *Self) !void {}
};

// ============================================================================
// Audio Configuration (BK7258 Onboard DAC)
// ============================================================================

pub const audio = struct {
    pub const sample_rate: u32 = 8000;
    pub const channels: u8 = 1;
    pub const bits: u8 = 16;
    pub const dig_gain: u8 = 0x2d;
    pub const ana_gain: u8 = 0x0A;
};

// ============================================================================
// Default GPIO assignments (BK7258 dev board)
// ============================================================================

pub const gpio = struct {
    /// Boot button (active low, typically GPIO22 on BK dev boards)
    pub const boot_button: u32 = 22;
    /// PWM LED channel
    pub const pwm_led_channel: u32 = 0;
    pub const pwm_led_period_us: u32 = 1000; // 1kHz
};

/// Pre-configured boot button driver
pub const BootButtonDriver = ButtonDriver(gpio.boot_button, true);

/// Pre-configured PWM LED driver
pub const LedDriver = PwmLedDriver(gpio.pwm_led_channel, gpio.pwm_led_period_us);
