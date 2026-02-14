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
    pub fn nowMs() u64 {
        return impl.Time.nowMs();
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
// Crypto (mbedTLS)
// ============================================================================

pub const crypto = impl.crypto.Suite;

// ============================================================================
// Heap (PSRAM + SRAM allocators)
// ============================================================================

pub const heap = armino.heap;

// ============================================================================
// KVS (EasyFlash V4)
// ============================================================================

pub const KvsDriver = impl.KvsDriver;

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
// Matrix Key Driver (3 GPIOs → 5 keys via matrix scan)
// ============================================================================

/// BK7258 V3.2 matrix keyboard driver.
/// 3 GPIOs form a matrix yielding up to 5 keys:
///   K1: gpio[0] input pull-up, read directly (active LOW)
///   K2: gpio[1] input pull-up, read directly (active LOW)
///   K3: gpio[2] input pull-up, read directly (active LOW)
///   K4: gpio[0] output HIGH → gpio[1] pull-down read (active HIGH)
///   K5: gpio[2] output HIGH → gpio[1] pull-down read (active HIGH)
///
/// Reference: armino/ap/components/key/key_main.c matrix_key_get_value()
pub fn MatrixKeyDriver(comptime gpio_pins: [3]u32, comptime num_keys: comptime_int) type {
    return struct {
        const Self = @This();
        const hw_gpio = armino.gpio;
        const g0 = gpio_pins[0]; // GPIO 6
        const g1 = gpio_pins[1]; // GPIO 7
        const g2 = gpio_pins[2]; // GPIO 8

        initialized: bool = false,

        pub fn init() !Self {
            // Disable second functions (QSPI etc.) and set as input + pull-up
            hw_gpio.setAsInputPullup(g0) catch return error.InitFailed;
            hw_gpio.setAsInputPullup(g1) catch return error.InitFailed;
            hw_gpio.setAsInputPullup(g2) catch return error.InitFailed;
            return .{ .initialized = true };
        }

        pub fn deinit(self: *Self) void {
            self.initialized = false;
        }

        /// Scan all keys. Returns array of pressed states.
        /// Scan keys one at a time, exactly like Armino matrix_key_get_value().
        /// Each key: configure ONLY the pins needed, read, done.
        /// This avoids cross-talk through the matrix wiring.
        pub fn scanKeys(_: *Self) [num_keys]bool {
            var result: [num_keys]bool = .{false} ** num_keys;

            // K1: g0 input pull-up, read (active LOW)
            hw_gpio.setAsInputPullup(g0) catch {};
            for (0..200) |_| asm volatile ("nop");
            result[0] = !hw_gpio.getInput(g0);

            // K2: g1 input pull-up, read (active LOW)
            hw_gpio.setAsInputPullup(g1) catch {};
            for (0..200) |_| asm volatile ("nop");
            result[1] = !hw_gpio.getInput(g1);

            // K3: g2 input pull-up, read (active LOW)
            hw_gpio.setAsInputPullup(g2) catch {};
            for (0..200) |_| asm volatile ("nop");
            result[2] = !hw_gpio.getInput(g2);

            // K4: g0 output HIGH → g1 pull-down read (active HIGH)
            if (num_keys > 3) {
                hw_gpio.setAsInputPulldown(g1) catch {};
                hw_gpio.setAsInputPulldown(g2) catch {};
                hw_gpio.setAsOutput(g0) catch {};
                hw_gpio.setOutput(g0, true);
                for (0..200) |_| asm volatile ("nop");
                result[3] = hw_gpio.getInput(g1);
            }

            // K5: g2 output HIGH → g1 pull-down read (active HIGH)
            if (num_keys > 4) {
                hw_gpio.setAsInputPulldown(g1) catch {};
                hw_gpio.setAsInputPulldown(g0) catch {};
                hw_gpio.setAsOutput(g2) catch {};
                hw_gpio.setOutput(g2, true);
                for (0..200) |_| asm volatile ("nop");
                result[4] = hw_gpio.getInput(g1);
            }

            return result;
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
// Speaker Driver (direct DAC + DMA, no pipeline)
// ============================================================================

pub const SpeakerDriver = struct {
    const Self = @This();

    speaker: armino.speaker.Speaker = .{},
    initialized: bool = false,

    pub fn init() !Self {
        var self = Self{};
        self.speaker = armino.speaker.Speaker.init(
            audio.sample_rate,
            audio.channels,
            audio.bits,
            audio.dig_gain,
        ) catch return error.InitFailed;
        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.speaker.deinit();
            self.initialized = false;
        }
    }

    pub fn write(self: *Self, buffer: []const i16) !usize {
        return self.speaker.write(buffer);
    }

    pub fn setVolume(_: *Self, volume: u8) !void {
        armino.speaker.setVolume(volume);
    }
};

/// PA switch — managed by speaker C helper (GPIO 0), no-op here
pub const PaSwitchDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn on(_: *Self) !void {}
    pub fn off(_: *Self) !void {}
};

// ============================================================================
// Microphone Driver (direct audio ADC + DMA)
// ============================================================================

pub const MicDriver = struct {
    const Self = @This();

    mic: armino.mic.Mic = .{},
    initialized: bool = false,

    pub fn init() !Self {
        var self = Self{};
        self.mic = armino.mic.Mic.init(
            audio.sample_rate,
            audio.channels,
            audio.mic_dig_gain,
            audio.mic_ana_gain,
        ) catch return error.InitFailed;
        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.mic.deinit();
            self.initialized = false;
        }
    }

    pub fn read(self: *Self, buffer: []i16) !usize {
        return self.mic.read(buffer) catch return error.ReadFailed;
    }
};

// ============================================================================
// Audio Configuration (BK7258 Onboard DAC)
// ============================================================================

pub const audio = struct {
    pub const sample_rate: u32 = 8000;
    pub const channels: u8 = 1;
    pub const bits: u8 = 16;
    pub const dig_gain: u8 = 0x2d;
    pub const ana_gain: u8 = 0x07; // match official voice service
    pub const mic_dig_gain: u8 = 0x2d;
    pub const mic_ana_gain: u8 = 0x08;
};

// ============================================================================
// AudioSystem (Speaker + Mic + AEC combined)
// ============================================================================

pub const AudioSystem = impl.audio_system.AudioSystem;

// ============================================================================
// Runtime (Mutex, Condition, spawn — for async packages like TLS, Channel)
// ============================================================================

pub const runtime = armino.runtime;

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
