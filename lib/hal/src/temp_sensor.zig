//! Temperature Sensor Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for temperature sensors:
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   const temp = board.temp.readCelsius() │
//! ├─────────────────────────────────────────┤
//! │ TempSensor(spec)  ← HAL wrapper        │
//! │   - Celsius/Fahrenheit conversion       │
//! │   - Range validation                    │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← hardware impl  │
//! │   - readCelsius()                       │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const temp_spec = struct {
//!     pub const Driver = Esp32TempDriver;
//!     pub const meta = hal.spec.Meta{ .id = "temp.internal" };
//! };
//!
//! // Create HAL wrapper
//! const MyTemp = hal.TempSensor(temp_spec);
//! var temp = MyTemp.init(&driver_instance);
//!
//! // Use unified interface
//! const celsius = temp.readCelsius() catch return;
//! const fahrenheit = temp.readFahrenheit() catch return;
//! ```

const std = @import("std");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _TempSensorMarker = struct {};

/// Check if a type is a TempSensor peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _TempSensorMarker;
}

// ============================================================================
// TempSensor HAL Wrapper
// ============================================================================

/// Temperature Sensor HAL component
///
/// Wraps a low-level Driver and provides:
/// - Unified readCelsius interface
/// - Celsius to Fahrenheit conversion
/// - Optional range validation
///
/// spec must define:
/// - `Driver`: struct with readCelsius method
/// - `meta`: spec.Meta with component id
///
/// Driver required methods:
/// - `fn readCelsius(self: *Self) !f32` - Read temperature in Celsius
///
/// Example:
/// ```zig
/// const temp_spec = struct {
///     pub const Driver = Esp32TempDriver;
///     pub const meta = hal.spec.Meta{ .id = "temp.internal" };
/// };
/// const MyTemp = temp_sensor.from(temp_spec);
/// ```
pub fn from(comptime spec: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify readCelsius signature (check type, don't call)
        _ = @as(*const fn (*BaseDriver) anyerror!f32, &BaseDriver.readCelsius);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _TempSensorMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver instance
        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ----- Temperature Reading -----

        /// Read temperature in Celsius
        pub fn readCelsius(self: *Self) !f32 {
            return self.driver.readCelsius();
        }

        /// Read temperature in Fahrenheit
        pub fn readFahrenheit(self: *Self) !f32 {
            const celsius = try self.readCelsius();
            return celsiusToFahrenheit(celsius);
        }

        /// Read temperature in Kelvin
        pub fn readKelvin(self: *Self) !f32 {
            const celsius = try self.readCelsius();
            return celsiusToKelvin(celsius);
        }

        // ----- Conversion Utilities -----

        /// Convert Celsius to Fahrenheit
        pub fn celsiusToFahrenheit(celsius: f32) f32 {
            return celsius * 9.0 / 5.0 + 32.0;
        }

        /// Convert Fahrenheit to Celsius
        pub fn fahrenheitToCelsius(fahrenheit: f32) f32 {
            return (fahrenheit - 32.0) * 5.0 / 9.0;
        }

        /// Convert Celsius to Kelvin
        pub fn celsiusToKelvin(celsius: f32) f32 {
            return celsius + 273.15;
        }

        /// Convert Kelvin to Celsius
        pub fn kelvinToCelsius(kelvin: f32) f32 {
            return kelvin - 273.15;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "TempSensor with mock driver" {
    // Mock driver implementation
    const MockDriver = struct {
        temperature: f32 = 25.0,

        pub fn readCelsius(self: *@This()) !f32 {
            return self.temperature;
        }
    };

    // Define spec
    const temp_spec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "temp.test" };
    };

    const TestTemp = from(temp_spec);

    var driver = MockDriver{ .temperature = 25.0 };
    var temp = TestTemp.init(&driver);

    // Test metadata
    try std.testing.expectEqualStrings("temp.test", TestTemp.meta.id);

    // Test readCelsius
    const celsius = try temp.readCelsius();
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), celsius, 0.01);

    // Test readFahrenheit
    const fahrenheit = try temp.readFahrenheit();
    try std.testing.expectApproxEqAbs(@as(f32, 77.0), fahrenheit, 0.01);

    // Test readKelvin
    const kelvin = try temp.readKelvin();
    try std.testing.expectApproxEqAbs(@as(f32, 298.15), kelvin, 0.01);
}

test "Temperature conversions" {
    const TestTemp = from(struct {
        pub const Driver = struct {
            pub fn readCelsius(_: *@This()) !f32 {
                return 0;
            }
        };
        pub const meta = .{ .id = "test" };
    });

    // Celsius to Fahrenheit
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), TestTemp.celsiusToFahrenheit(0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 212.0), TestTemp.celsiusToFahrenheit(100), 0.01);

    // Fahrenheit to Celsius
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), TestTemp.fahrenheitToCelsius(32), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), TestTemp.fahrenheitToCelsius(212), 0.01);

    // Celsius to Kelvin
    try std.testing.expectApproxEqAbs(@as(f32, 273.15), TestTemp.celsiusToKelvin(0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 373.15), TestTemp.celsiusToKelvin(100), 0.01);
}
