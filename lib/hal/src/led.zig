//! LED Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for single LEDs:
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   board.led.setBrightness(128)         │
//! │   board.led.fadeIn(1000)               │
//! ├─────────────────────────────────────────┤
//! │ Led(spec)  ← HAL wrapper               │
//! │   - brightness control                  │
//! │   - fade support                        │
//! │   - enable/disable                      │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← platform impl  │
//! │   - setDuty()                           │
//! │   - getDuty()                           │
//! │   - fade()                              │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const led_spec = struct {
//!     pub const Driver = LedDriver;  // Platform-specific implementation
//!     pub const meta = hal.spec.Meta{ .id = "led.main" };
//! };
//!
//! // Create HAL wrapper
//! const MyLed = hal.led.from(led_spec);
//! var led = MyLed.init(&driver_instance);
//!
//! // Use unified interface
//! led.setBrightness(128);  // 50% brightness
//! led.fadeIn(1000);        // Fade in over 1 second
//! ```

const std = @import("std");
const builtin = @import("builtin");


// ============================================================================
// Type Marker (for hal.Board identification)
// ============================================================================

const _LedMarker = struct {};

/// Check if a type is a Led peripheral (for hal.Board)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _LedMarker;
}

// ============================================================================
// LED HAL Component
// ============================================================================

/// Create LED HAL component from spec
///
/// spec must define:
/// - `Driver`: struct with setDuty, getDuty methods
/// - `meta`: hal.Meta with component id
///
/// Driver required methods:
/// - `fn setDuty(self: *Self, duty: u16) void` - Set duty cycle (0-65535)
/// - `fn getDuty(self: *const Self) u16` - Get current duty cycle
///
/// Driver optional methods:
/// - `fn fade(self: *Self, target: u16, duration_ms: u32) void` - Hardware fade
///
/// Example:
/// ```zig
/// const led_spec = struct {
///     pub const Driver = LedcPwmDriver;
///     pub const meta = hal.Meta{ .id = "led.main" };
/// };
/// const MyLed = hal.led.from(led_spec);
/// ```
pub fn from(comptime spec: type) type {
    // Comptime validation - verify spec interface
    comptime {
        // Verify Driver methods signature
        _ = @as(*const fn (*spec.Driver, u16) void, &spec.Driver.setDuty);
        _ = @as(*const fn (*const spec.Driver) u16, &spec.Driver.getDuty);
        // Verify meta.id
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        /// Type marker for hal.Board identification
        pub const _hal_marker = _LedMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver instance
        driver: *Driver,

        /// Enable/disable output
        enabled: bool = true,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ----- Brightness Control -----

        /// Set brightness (0-255, where 255 = 100%)
        pub fn setBrightness(self: *Self, brightness: u8) void {
            if (!self.enabled) return;
            // Convert 8-bit brightness to 16-bit duty
            const duty: u16 = @as(u16, brightness) * 257; // 255 * 257 = 65535
            self.driver.setDuty(duty);
        }

        /// Get current brightness (0-255)
        pub fn getBrightness(self: *const Self) u8 {
            const duty = self.driver.getDuty();
            return @intCast(duty / 257);
        }

        /// Set brightness as percentage (0-100)
        pub fn setPercent(self: *Self, percent: u8) void {
            const clamped = @min(percent, 100);
            const brightness: u8 = @intCast((@as(u16, clamped) * 255) / 100);
            self.setBrightness(brightness);
        }

        /// Get brightness as percentage (0-100)
        pub fn getPercent(self: *const Self) u8 {
            const brightness = self.getBrightness();
            return @intCast((@as(u16, brightness) * 100) / 255);
        }

        // ----- Fade Control -----

        /// Fade to target brightness over duration
        pub fn fadeTo(self: *Self, brightness: u8, duration_ms: u32) void {
            if (!self.enabled) return;

            const target: u16 = @as(u16, brightness) * 257;

            if (@hasDecl(Driver, "fade")) {
                self.driver.fade(target, duration_ms);
            } else {
                // Fallback: instant set
                self.driver.setDuty(target);
            }
        }

        /// Fade in to full brightness
        pub fn fadeIn(self: *Self, duration_ms: u32) void {
            self.fadeTo(255, duration_ms);
        }

        /// Fade out to off
        pub fn fadeOut(self: *Self, duration_ms: u32) void {
            self.fadeTo(0, duration_ms);
        }

        /// Fade to percentage over duration
        pub fn fadePercent(self: *Self, percent: u8, duration_ms: u32) void {
            const clamped = @min(percent, 100);
            const brightness: u8 = @intCast((@as(u16, clamped) * 255) / 100);
            self.fadeTo(brightness, duration_ms);
        }

        // ----- Enable Control -----

        /// Enable/disable LED output
        pub fn setEnabled(self: *Self, enabled: bool) void {
            self.enabled = enabled;
            if (!enabled) {
                self.driver.setDuty(0);
            }
        }

        /// Check if enabled
        pub fn isEnabled(self: Self) bool {
            return self.enabled;
        }

        // ----- Convenience Methods -----

        /// Turn on (100% brightness)
        pub fn on(self: *Self) void {
            self.setBrightness(255);
        }

        /// Turn off (0% brightness)
        pub fn off(self: *Self) void {
            self.setBrightness(0);
        }

        /// Toggle on/off
        pub fn toggle(self: *Self) void {
            if (self.getBrightness() > 0) {
                self.off();
            } else {
                self.on();
            }
        }

        /// Check if LED is on (brightness > 0)
        pub fn isOn(self: *const Self) bool {
            return self.getBrightness() > 0;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Led with mock driver" {
    // Mock driver implementation
    const MockDriver = struct {
        duty: u16 = 0,
        fade_target: u16 = 0,
        fade_duration: u32 = 0,

        pub fn setDuty(self: *@This(), duty: u16) void {
            self.duty = duty;
        }

        pub fn getDuty(self: *const @This()) u16 {
            return self.duty;
        }

        pub fn fade(self: *@This(), target: u16, duration_ms: u32) void {
            self.fade_target = target;
            self.fade_duration = duration_ms;
            self.duty = target; // Instant for test
        }
    };

    // Define spec
    const led_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "led.test" };
    };

    const TestLed = from(led_spec);

    var driver = MockDriver{};
    var led = TestLed.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("led.test", TestLed.meta.id);

    // Test setBrightness
    led.setBrightness(128);
    // 128 * 257 = 32896
    try std.testing.expect(driver.duty >= 32768 and driver.duty <= 33024);

    // Test getBrightness
    driver.duty = 65535;
    try std.testing.expectEqual(@as(u8, 255), led.getBrightness());

    // Test setPercent
    led.setPercent(50);
    const percent = led.getPercent();
    try std.testing.expect(percent >= 48 and percent <= 52);

    // Test fadeIn/fadeOut
    led.fadeIn(1000);
    try std.testing.expectEqual(@as(u16, 65535), driver.fade_target);
    try std.testing.expectEqual(@as(u32, 1000), driver.fade_duration);

    led.fadeOut(500);
    try std.testing.expectEqual(@as(u16, 0), driver.fade_target);
    try std.testing.expectEqual(@as(u32, 500), driver.fade_duration);

    // Test on/off
    led.on();
    try std.testing.expect(led.isOn());

    led.off();
    try std.testing.expect(!led.isOn());

    // Test toggle
    led.toggle();
    try std.testing.expect(led.isOn());

    led.toggle();
    try std.testing.expect(!led.isOn());

    // Test enable/disable
    led.setEnabled(false);
    try std.testing.expect(!led.isEnabled());
    led.setBrightness(255); // Should be ignored
    try std.testing.expectEqual(@as(u16, 0), driver.duty);
}
