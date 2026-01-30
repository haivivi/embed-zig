//! Switch Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for on/off switches:
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   try board.pa_switch.on();             │
//! │   defer board.pa_switch.off();          │
//! ├─────────────────────────────────────────┤
//! │ Switch(spec)  ← HAL wrapper             │
//! │   - Unified on/off interface            │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← board impl      │
//! │   - GPIO control, power management      │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Design Principles
//!
//! The Switch abstraction represents any on/off control:
//! - Power amplifier enable
//! - Power rail control
//! - Peripheral enable pins
//! - Any GPIO-based switch
//!
//! Multiple components can share the same switch (e.g., mic and speaker
//! sharing the same power amplifier).
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const pa_switch_spec = struct {
//!     pub const Driver = GpioSwitchDriver;
//!     pub const meta = .{ .id = "switch.pa" };
//! };
//!
//! // Create HAL wrapper
//! const PaSwitch = hal.switch_.from(pa_switch_spec);
//! var pa = PaSwitch.init(&driver_instance);
//!
//! // Use unified interface
//! try pa.on();
//! defer pa.off() catch {};
//! // ... do audio work ...
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _SwitchMarker = struct {};

/// Check if a type is a Switch peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _SwitchMarker;
}

// ============================================================================
// Switch HAL Wrapper
// ============================================================================

/// Switch HAL component
///
/// Wraps a low-level Driver and provides:
/// - Unified on/off interface
/// - Optional state query
///
/// spec must define:
/// - `Driver`: struct implementing on/off methods
/// - `meta`: spec.Meta with component id
///
/// Driver required methods:
/// - `fn on(self: *Self) !void` - Turn on the switch
/// - `fn off(self: *Self) !void` - Turn off the switch
///
/// Driver optional methods:
/// - `fn isOn(self: *Self) bool` - Query current state
///
/// Example:
/// ```zig
/// const pa_spec = struct {
///     pub const Driver = GpioSwitchDriver;
///     pub const meta = .{ .id = "switch.pa" };
/// };
/// const PaSwitch = switch_.from(pa_spec);
/// ```
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify on/off method signatures
        _ = @as(*const fn (*BaseDriver) anyerror!void, &BaseDriver.on);
        _ = @as(*const fn (*BaseDriver) anyerror!void, &BaseDriver.off);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _SwitchMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        // ================================================================
        // Instance Fields
        // ================================================================

        /// The underlying driver instance
        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ================================================================
        // Core API
        // ================================================================

        /// Turn on the switch
        ///
        /// Example:
        /// ```zig
        /// try pa_switch.on();
        /// defer pa_switch.off() catch {};
        /// ```
        pub fn on(self: *Self) !void {
            return self.driver.on();
        }

        /// Turn off the switch
        pub fn off(self: *Self) !void {
            return self.driver.off();
        }

        // ================================================================
        // Optional API (depends on driver support)
        // ================================================================

        /// Query if the switch is currently on
        ///
        /// Returns error if driver doesn't support state query.
        pub fn isOn(self: *Self) !bool {
            if (@hasDecl(Driver, "isOn")) {
                return self.driver.isOn();
            }
            return error.NotSupported;
        }

        /// Check if driver supports state query
        pub fn supportsStateQuery() bool {
            return @hasDecl(Driver, "isOn");
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Switch with mock driver" {
    // Mock driver implementation
    const MockDriver = struct {
        state: bool = false,
        on_count: usize = 0,
        off_count: usize = 0,

        pub fn on(self: *@This()) !void {
            self.state = true;
            self.on_count += 1;
        }

        pub fn off(self: *@This()) !void {
            self.state = false;
            self.off_count += 1;
        }

        pub fn isOn(self: *@This()) bool {
            return self.state;
        }
    };

    // Define spec
    const switch_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "switch.test" };
    };

    const TestSwitch = from(switch_spec);

    var driver = MockDriver{};
    var sw = TestSwitch.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("switch.test", TestSwitch.meta.id);

    // Test on/off
    try std.testing.expect(!driver.state);
    try sw.on();
    try std.testing.expect(driver.state);
    try std.testing.expectEqual(@as(usize, 1), driver.on_count);

    try sw.off();
    try std.testing.expect(!driver.state);
    try std.testing.expectEqual(@as(usize, 1), driver.off_count);

    // Test isOn
    try sw.on();
    try std.testing.expect(try sw.isOn());
    try sw.off();
    try std.testing.expect(!(try sw.isOn()));

    // Test feature detection
    try std.testing.expect(TestSwitch.supportsStateQuery());
}

test "Switch without state query" {
    const MinimalDriver = struct {
        pub fn on(_: *@This()) !void {}
        pub fn off(_: *@This()) !void {}
    };

    const switch_spec = struct {
        pub const Driver = MinimalDriver;
        pub const meta = .{ .id = "switch.minimal" };
    };

    const TestSwitch = from(switch_spec);

    // Test feature detection
    try std.testing.expect(!TestSwitch.supportsStateQuery());
}
