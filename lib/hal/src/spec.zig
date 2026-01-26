//! HAL Specification Definitions
//!
//! This module defines the compile-time contracts that hardware drivers must satisfy.
//! Each HAL component (RmtLedStrip, Button, ButtonGroup) requires a `spec` parameter
//! containing:
//!   - `Driver`: Type implementing the required interface
//!   - `meta`: Metadata for event tracing
//!
//! ## Usage
//!
//! ```zig
//! const my_led_spec = struct {
//!     pub const Driver = MyLedDriver;
//!     pub const meta = hal.spec.Meta{ .id = "led.main" };
//! };
//!
//! const MyLedStrip = hal.RmtLedStrip(my_led_spec);
//! ```

const std = @import("std");

// ============================================================================
// Common Metadata
// ============================================================================

/// Metadata for all HAL components
/// Used for event tracing and debugging
pub const Meta = struct {
    /// Component identifier for event source tracking
    /// Examples: "led.main", "buttons.main", "btn.power"
    id: []const u8,
};

// ============================================================================
// RgbLedStrip Driver Specification
// ============================================================================

/// Verify that a type satisfies the RgbLedStrip.Driver interface
pub fn verifyRgbLedStripDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("RgbLedStrip.Driver must be a struct type");
    }

    // Required: setPixel(self, index, color) void
    if (!@hasDecl(Driver, "setPixel")) {
        @compileError("RgbLedStrip.Driver must implement: fn setPixel(self: *Self, index: u32, color: Color) void");
    }

    // Required: getPixelCount(self) u32
    if (!@hasDecl(Driver, "getPixelCount")) {
        @compileError("RgbLedStrip.Driver must implement: fn getPixelCount(self: *Self) u32");
    }

    // Verify method signatures
    const Self = *Driver;
    const Color = @import("led_strip.zig").Color;

    // Check setPixel signature
    const setPixel = @field(Driver, "setPixel");
    const SetPixelFn = @TypeOf(setPixel);
    const setPixelInfo = @typeInfo(SetPixelFn);
    if (setPixelInfo != .@"fn") {
        @compileError("RgbLedStrip.Driver.setPixel must be a function");
    }
    const setPixelParams = setPixelInfo.@"fn".params;
    if (setPixelParams.len != 3) {
        @compileError("RgbLedStrip.Driver.setPixel must take 3 parameters: self, index, color");
    }
    if (setPixelParams[0].type != Self) {
        @compileError("RgbLedStrip.Driver.setPixel first parameter must be *Self");
    }
    if (setPixelParams[1].type != u32) {
        @compileError("RgbLedStrip.Driver.setPixel second parameter (index) must be u32");
    }
    if (setPixelParams[2].type != Color) {
        @compileError("RgbLedStrip.Driver.setPixel third parameter must be Color");
    }

    // Check getPixelCount signature
    const getPixelCount = @field(Driver, "getPixelCount");
    const GetPixelCountFn = @TypeOf(getPixelCount);
    const getPixelCountInfo = @typeInfo(GetPixelCountFn);
    if (getPixelCountInfo != .@"fn") {
        @compileError("RgbLedStrip.Driver.getPixelCount must be a function");
    }
    if (getPixelCountInfo.@"fn".return_type != u32) {
        @compileError("RgbLedStrip.Driver.getPixelCount must return u32");
    }

    // Optional: refresh(self) void - for drivers that batch updates
    // No compile error if missing, will be checked at runtime
}

/// Verify that a spec is valid for RgbLedStrip
pub fn verifyRgbLedStripSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("RgbLedStrip spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("RgbLedStrip spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("RgbLedStrip spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyRgbLedStripDriver(@field(spec, "Driver"));
}

// ============================================================================
// Button Driver Specification (Single Button)
// ============================================================================

/// Verify that a type satisfies the Button.Driver interface
pub fn verifyButtonDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("Button.Driver must be a struct type");
    }

    // Required: isPressed(self) bool
    if (!@hasDecl(Driver, "isPressed")) {
        @compileError("Button.Driver must implement: fn isPressed(self: *Self) bool");
    }

    // Verify method signature
    const isPressed = @field(Driver, "isPressed");
    const IsPressedFn = @TypeOf(isPressed);
    const isPressedInfo = @typeInfo(IsPressedFn);

    if (isPressedInfo != .@"fn") {
        @compileError("Button.Driver.isPressed must be a function");
    }
    const isPressedParams = isPressedInfo.@"fn".params;
    if (isPressedParams.len != 1) {
        @compileError("Button.Driver.isPressed must take 1 parameter: self");
    }
    // Accept both *Self and *const Self
    if (isPressedParams[0].type != *Driver and isPressedParams[0].type != *const Driver) {
        @compileError("Button.Driver.isPressed first parameter must be *Self or *const Self");
    }
    if (isPressedInfo.@"fn".return_type != bool) {
        @compileError("Button.Driver.isPressed must return bool");
    }
}

/// Verify that a spec is valid for Button
pub fn verifyButtonSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("Button spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("Button spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("Button spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyButtonDriver(@field(spec, "Driver"));
}

// ============================================================================
// ButtonGroup Driver Specification (Multiple Buttons)
// ============================================================================

/// Verify that a type satisfies the ButtonGroup.Driver interface
/// Note: ButtonId is provided by the application Config
pub fn verifyButtonGroupDriver(comptime Driver: type, comptime ButtonId: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("ButtonGroup.Driver must be a struct type");
    }

    // Verify ButtonId is an enum
    if (@typeInfo(ButtonId) != .@"enum") {
        @compileError("ButtonGroup ButtonId must be an enum type");
    }

    // Required: poll(self) ?ButtonId
    if (!@hasDecl(Driver, "poll")) {
        @compileError("ButtonGroup.Driver must implement: fn poll(self: *Self) ?ButtonId");
    }

    // Verify method signature
    const Self = *Driver;
    const poll = @field(Driver, "poll");
    const PollFn = @TypeOf(poll);
    const pollInfo = @typeInfo(PollFn);

    if (pollInfo != .@"fn") {
        @compileError("ButtonGroup.Driver.poll must be a function");
    }
    const pollParams = pollInfo.@"fn".params;
    if (pollParams.len != 1) {
        @compileError("ButtonGroup.Driver.poll must take 1 parameter: self");
    }
    if (pollParams[0].type != Self) {
        @compileError("ButtonGroup.Driver.poll first parameter must be *Self");
    }
    // Return type check: should be ?ButtonId
    const returnType = pollInfo.@"fn".return_type;
    const returnInfo = @typeInfo(returnType.?);
    if (returnInfo != .optional) {
        @compileError("ButtonGroup.Driver.poll must return ?ButtonId (optional)");
    }
}

/// Verify that a spec is valid for ButtonGroup
pub fn verifyButtonGroupSpec(comptime spec: type, comptime ButtonId: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("ButtonGroup spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("ButtonGroup spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("ButtonGroup spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyButtonGroupDriver(@field(spec, "Driver"), ButtonId);
}

// ============================================================================
// WiFi Driver Specification
// ============================================================================

/// Verify that a type satisfies the Wifi.Driver interface
pub fn verifyWifiDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("Wifi.Driver must be a struct type");
    }

    // Required: connect(self, ssid, password) !void
    if (!@hasDecl(Driver, "connect")) {
        @compileError("Wifi.Driver must implement: fn connect(self: *Self, ssid: []const u8, password: []const u8) !void");
    }

    // Required: disconnect(self) void
    if (!@hasDecl(Driver, "disconnect")) {
        @compileError("Wifi.Driver must implement: fn disconnect(self: *Self) void");
    }

    // Required: isConnected(self) bool
    if (!@hasDecl(Driver, "isConnected")) {
        @compileError("Wifi.Driver must implement: fn isConnected(self: *const Self) bool");
    }

    // Required: getIpAddress(self) ?IpAddress
    if (!@hasDecl(Driver, "getIpAddress")) {
        @compileError("Wifi.Driver must implement: fn getIpAddress(self: *const Self) ?[4]u8");
    }

    // Optional methods (getRssi, getMac) are checked at usage site
}

/// Verify that a spec is valid for Wifi
pub fn verifyWifiSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("Wifi spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("Wifi spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("Wifi spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyWifiDriver(@field(spec, "Driver"));
}

// ============================================================================
// RTC Reader Driver Specification (Read-only)
// ============================================================================

/// Verify that a type satisfies the RtcReader.Driver interface
///
/// Required methods:
/// - uptime() u64: Monotonic time since boot in milliseconds (always available)
/// - read() ?i64: Unix epoch seconds, null if not synced
pub fn verifyRtcReaderDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("RtcReader.Driver must be a struct type");
    }

    // Required: uptime(self) u64 - monotonic time since boot in ms
    if (!@hasDecl(Driver, "uptime")) {
        @compileError("RtcReader.Driver must implement: fn uptime(self: *Self) u64");
    }

    // Required: read(self) ?i64 - returns epoch_secs or null if not synced
    if (!@hasDecl(Driver, "read")) {
        @compileError("RtcReader.Driver must implement: fn read(self: *Self) ?i64");
    }

    // Verify uptime signature
    const uptime = @field(Driver, "uptime");
    const UptimeFn = @TypeOf(uptime);
    const uptimeInfo = @typeInfo(UptimeFn);

    if (uptimeInfo != .@"fn") {
        @compileError("RtcReader.Driver.uptime must be a function");
    }
    if (uptimeInfo.@"fn".return_type != u64) {
        @compileError("RtcReader.Driver.uptime must return u64");
    }

    // Verify read signature
    const read = @field(Driver, "read");
    const ReadFn = @TypeOf(read);
    const readInfo = @typeInfo(ReadFn);

    if (readInfo != .@"fn") {
        @compileError("RtcReader.Driver.read must be a function");
    }
    if (readInfo.@"fn".return_type != ?i64) {
        @compileError("RtcReader.Driver.read must return ?i64");
    }
}

/// Verify that a spec is valid for RtcReader
pub fn verifyRtcReaderSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("RtcReader spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("RtcReader spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("RtcReader spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyRtcReaderDriver(@field(spec, "Driver"));
}

// ============================================================================
// RTC Writer Driver Specification (Write-only)
// ============================================================================

/// Verify that a type satisfies the RtcWriter.Driver interface
///
/// Required methods:
/// - write(epoch_secs: i64) !void: Set the time
pub fn verifyRtcWriterDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("RtcWriter.Driver must be a struct type");
    }

    // Required: write(self, epoch_secs) !void - set time
    if (!@hasDecl(Driver, "write")) {
        @compileError("RtcWriter.Driver must implement: fn write(self: *Self, epoch_secs: i64) !void");
    }

    // Verify write signature
    const write = @field(Driver, "write");
    const WriteFn = @TypeOf(write);
    const writeInfo = @typeInfo(WriteFn);

    if (writeInfo != .@"fn") {
        @compileError("RtcWriter.Driver.write must be a function");
    }
    const writeParams = writeInfo.@"fn".params;
    if (writeParams.len != 2) {
        @compileError("RtcWriter.Driver.write must take 2 parameters: self, epoch_secs");
    }
    if (writeParams[1].type != i64) {
        @compileError("RtcWriter.Driver.write second parameter must be i64");
    }
}

/// Verify that a spec is valid for RtcWriter
pub fn verifyRtcWriterSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("RtcWriter spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("RtcWriter spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("RtcWriter spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyRtcWriterDriver(@field(spec, "Driver"));
}

// ============================================================================
// Led Driver Specification
// ============================================================================

/// Verify that a type satisfies the Led.Driver interface
///
/// Required methods:
/// - setDuty(duty: u16) void: Set duty cycle (0-65535)
/// - getDuty() u16: Get current duty cycle
///
/// Optional methods:
/// - fade(target: u16, duration_ms: u32) void: Hardware-assisted fade
pub fn verifyLedDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("Led.Driver must be a struct type");
    }

    // Required: setDuty(self, duty) void
    if (!@hasDecl(Driver, "setDuty")) {
        @compileError("Led.Driver must implement: fn setDuty(self: *Self, duty: u16) void");
    }

    // Required: getDuty(self) u16
    if (!@hasDecl(Driver, "getDuty")) {
        @compileError("Led.Driver must implement: fn getDuty(self: *const Self) u16");
    }

    // Verify setDuty signature
    const setDuty = @field(Driver, "setDuty");
    const SetDutyFn = @TypeOf(setDuty);
    const setDutyInfo = @typeInfo(SetDutyFn);

    if (setDutyInfo != .@"fn") {
        @compileError("Led.Driver.setDuty must be a function");
    }
    const setDutyParams = setDutyInfo.@"fn".params;
    if (setDutyParams.len != 2) {
        @compileError("Led.Driver.setDuty must take 2 parameters: self, duty");
    }
    if (setDutyParams[1].type != u16) {
        @compileError("Led.Driver.setDuty second parameter (duty) must be u16");
    }

    // Verify getDuty signature
    const getDuty = @field(Driver, "getDuty");
    const GetDutyFn = @TypeOf(getDuty);
    const getDutyInfo = @typeInfo(GetDutyFn);

    if (getDutyInfo != .@"fn") {
        @compileError("Led.Driver.getDuty must be a function");
    }
    if (getDutyInfo.@"fn".return_type != u16) {
        @compileError("Led.Driver.getDuty must return u16");
    }

    // Optional: fade(self, target, duration_ms) void
    // No compile error if missing
}

/// Verify that a spec is valid for Led
pub fn verifyLedSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("Led spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("Led spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("Led spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyLedDriver(@field(spec, "Driver"));
}

// ============================================================================
// Temperature Sensor Driver Specification
// ============================================================================

/// Verify that a type satisfies the TempSensor.Driver interface
///
/// Required methods:
/// - readCelsius() !f32: Read temperature in Celsius
pub fn verifyTempSensorDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("TempSensor.Driver must be a struct type");
    }

    // Required: readCelsius(self) !f32
    if (!@hasDecl(Driver, "readCelsius")) {
        @compileError("TempSensor.Driver must implement: fn readCelsius(self: *Self) !f32");
    }

    // Verify readCelsius signature
    const readCelsius = @field(Driver, "readCelsius");
    const ReadCelsiusFn = @TypeOf(readCelsius);
    const readCelsiusInfo = @typeInfo(ReadCelsiusFn);

    if (readCelsiusInfo != .@"fn") {
        @compileError("TempSensor.Driver.readCelsius must be a function");
    }

    // Return type should be !f32 (error union)
    const returnType = readCelsiusInfo.@"fn".return_type;
    if (returnType) |rt| {
        const rtInfo = @typeInfo(rt);
        if (rtInfo != .error_union) {
            @compileError("TempSensor.Driver.readCelsius must return !f32 (error union)");
        }
        if (rtInfo.error_union.payload != f32) {
            @compileError("TempSensor.Driver.readCelsius must return !f32");
        }
    } else {
        @compileError("TempSensor.Driver.readCelsius must have a return type");
    }
}

/// Verify that a spec is valid for TempSensor
pub fn verifyTempSensorSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("TempSensor spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("TempSensor spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("TempSensor spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyTempSensorDriver(@field(spec, "Driver"));
}

// ============================================================================
// Key-Value Store Driver Specification
// ============================================================================

/// Verify that a type satisfies the Kvs.Driver interface
///
/// Required methods:
/// - getU32(key: []const u8) !u32
/// - setU32(key: []const u8, value: u32) !void
/// - getString(key: []const u8, buf: []u8) ![]const u8
/// - setString(key: []const u8, value: []const u8) !void
/// - commit() !void
///
/// Optional methods:
/// - getI32(key: []const u8) !i32
/// - setI32(key: []const u8, value: i32) !void
/// - erase(key: []const u8) !void
/// - eraseAll() !void
pub fn verifyKvsDriver(comptime Driver: type) void {
    const info = @typeInfo(Driver);
    if (info != .@"struct") {
        @compileError("Kvs.Driver must be a struct type");
    }

    // Required methods
    if (!@hasDecl(Driver, "getU32")) {
        @compileError("Kvs.Driver must implement: fn getU32(self: *Self, key: []const u8) !u32");
    }
    if (!@hasDecl(Driver, "setU32")) {
        @compileError("Kvs.Driver must implement: fn setU32(self: *Self, key: []const u8, value: u32) !void");
    }
    if (!@hasDecl(Driver, "getString")) {
        @compileError("Kvs.Driver must implement: fn getString(self: *Self, key: []const u8, buf: []u8) ![]const u8");
    }
    if (!@hasDecl(Driver, "setString")) {
        @compileError("Kvs.Driver must implement: fn setString(self: *Self, key: []const u8, value: []const u8) !void");
    }
    if (!@hasDecl(Driver, "commit")) {
        @compileError("Kvs.Driver must implement: fn commit(self: *Self) !void");
    }

    // Optional: getI32, setI32, erase, eraseAll - no compile error if missing
}

/// Verify that a spec is valid for Kvs
pub fn verifyKvsSpec(comptime spec: type) void {
    if (!@hasDecl(spec, "Driver")) {
        @compileError("Kvs spec must define: pub const Driver = <driver type>;");
    }
    if (!@hasDecl(spec, "meta")) {
        @compileError("Kvs spec must define: pub const meta = spec.Meta{ .id = \"...\" };");
    }

    // Verify meta type
    const meta = @field(spec, "meta");
    if (@TypeOf(meta) != Meta) {
        @compileError("Kvs spec.meta must be of type spec.Meta");
    }

    // Verify driver interface
    verifyKvsDriver(@field(spec, "Driver"));
}

// ============================================================================
// Tests
// ============================================================================

test "Meta creation" {
    const meta = Meta{ .id = "test.component" };
    try std.testing.expectEqualStrings("test.component", meta.id);
}

test "RgbLedStrip driver verification - mock driver" {
    const Color = @import("led_strip.zig").Color;

    const MockLedDriver = struct {
        pixels: [10]Color = [_]Color{Color.black} ** 10,

        pub fn setPixel(self: *@This(), index: u32, color: Color) void {
            if (index < self.pixels.len) {
                self.pixels[index] = color;
            }
        }

        pub fn getPixelCount(_: *@This()) u32 {
            return 10;
        }
    };

    // This should compile without error
    verifyRgbLedStripDriver(MockLedDriver);
}

test "Button driver verification - mock driver" {
    const MockButtonDriver = struct {
        pressed: bool = false,

        pub fn isPressed(self: *@This()) bool {
            return self.pressed;
        }
    };

    // This should compile without error
    verifyButtonDriver(MockButtonDriver);
}

test "ButtonGroup driver verification - mock driver" {
    const TestButtonId = enum { a, b, c };

    const MockButtonGroupDriver = struct {
        current: ?TestButtonId = null,

        pub fn poll(self: *@This()) ?TestButtonId {
            return self.current;
        }
    };

    // This should compile without error
    verifyButtonGroupDriver(MockButtonGroupDriver, TestButtonId);
}

test "RtcReader driver verification - mock driver" {
    const MockRtcReaderDriver = struct {
        boot_time: u64 = 0,
        epoch: ?i64 = null,

        pub fn uptime(self: *@This()) u64 {
            return self.boot_time;
        }

        pub fn read(self: *@This()) ?i64 {
            return self.epoch;
        }
    };

    // This should compile without error
    verifyRtcReaderDriver(MockRtcReaderDriver);
}

test "RtcWriter driver verification - mock driver" {
    const MockRtcWriterDriver = struct {
        epoch: ?i64 = null,

        pub fn write(self: *@This(), epoch_secs: i64) !void {
            self.epoch = epoch_secs;
        }
    };

    // This should compile without error
    verifyRtcWriterDriver(MockRtcWriterDriver);
}

test "Led driver verification - mock driver" {
    const MockSingleLedDriver = struct {
        duty: u16 = 0,

        pub fn setDuty(self: *@This(), duty: u16) void {
            self.duty = duty;
        }

        pub fn getDuty(self: *const @This()) u16 {
            return self.duty;
        }
    };

    // This should compile without error
    verifyLedDriver(MockSingleLedDriver);
}

test "TempSensor driver verification - mock driver" {
    const MockTempDriver = struct {
        temp: f32 = 25.0,

        pub fn readCelsius(self: *@This()) !f32 {
            return self.temp;
        }
    };

    // This should compile without error
    verifyTempSensorDriver(MockTempDriver);
}

test "Kvs driver verification - mock driver" {
    const MockKvsDriver = struct {
        pub fn getU32(_: *@This(), _: []const u8) !u32 {
            return 0;
        }

        pub fn setU32(_: *@This(), _: []const u8, _: u32) !void {}

        pub fn getString(_: *@This(), _: []const u8, buf: []u8) ![]const u8 {
            return buf[0..0];
        }

        pub fn setString(_: *@This(), _: []const u8, _: []const u8) !void {}

        pub fn commit(_: *@This()) !void {}
    };

    // This should compile without error
    verifyKvsDriver(MockKvsDriver);
}
