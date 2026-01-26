//! HAL Board Abstraction (v5)
//!
//! Automatically manages HAL peripherals, drivers, and event queue.
//!
//! ## Required: RtcReader
//!
//! Every board spec MUST have `rtc` (RtcReader) for time source.
//! Other peripherals are optional.
//!
//! ## Minimal board.zig
//!
//! ```zig
//! const hal = @import("hal");
//! const hw = @import("korvo2_v3.zig");
//!
//! const spec = struct {
//!     // Required: time source
//!     pub const rtc = hal.RtcReader(hw.rtc_spec);
//!     
//!     // Optional peripherals
//!     pub const ButtonId = enum(u8) { vol_up, vol_down };
//!     pub const buttons = hal.ButtonGroup(hw.button_spec, ButtonId);
//!     pub const rgb_leds = hal.RgbLedStrip(hw.led_spec);
//! };
//!
//! pub const Board = hal.Board(spec);
//! ```
//!
//! ## main.zig Usage
//!
//! ```zig
//! var board = try Board.init();
//! defer board.deinit();
//!
//! while (true) {
//!     board.poll();
//!     while (board.nextEvent()) |event| {
//!         switch (event) {
//!             .button => |btn| handleButton(btn),
//!             else => {},
//!         }
//!     }
//!     board.led.setColor(hal.Color.red);
//!     
//!     // Time access
//!     const uptime_ms = board.rtc.uptime();
//!     if (board.rtc.now()) |time| { ... }
//! }
//! ```

const std = @import("std");

const button_group_mod = @import("button_group.zig");
const button_mod = @import("button.zig");
const event_mod = @import("event.zig");
const rgb_led_strip_mod = @import("led_strip.zig");
const led_mod = @import("led.zig");
const rtc_mod = @import("rtc.zig");
const wifi_mod = @import("wifi.zig");
const temp_sensor_mod = @import("temp_sensor.zig");
const kvs_mod = @import("kvs.zig");

// ============================================================================
// Simple Queue (Default implementation)
// ============================================================================

pub fn SimpleQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        size: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn trySend(self: *Self, item: T) bool {
            if (self.size >= capacity) return false;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;
            return true;
        }

        pub fn tryReceive(self: *Self) ?T {
            if (self.size == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.size -= 1;
            return item;
        }

        pub fn count(self: *const Self) usize {
            return self.size;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.size == 0;
        }

        pub fn reset(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.size = 0;
        }
    };
}

// ============================================================================
// Spec Analysis
// ============================================================================

const PeripheralKind = enum { button_group, button, rgb_led_strip, led, wifi, temp_sensor, kvs, unknown };

fn getPeripheralKind(comptime T: type) PeripheralKind {
    if (@typeInfo(T) != .@"struct") return .unknown;
    if (!@hasDecl(T, "_hal_marker")) return .unknown;
    if (button_group_mod.isButtonGroupType(T)) return .button_group;
    if (button_mod.isButtonType(T)) return .button;
    if (rgb_led_strip_mod.isRgbLedStripType(T)) return .rgb_led_strip;
    if (led_mod.isLedType(T)) return .led;
    if (wifi_mod.isWifiType(T)) return .wifi;
    if (temp_sensor_mod.isTempSensorType(T)) return .temp_sensor;
    if (kvs_mod.isKvsType(T)) return .kvs;
    return .unknown;
}

fn SpecAnalysis(comptime spec: type) type {
    // Verify required: rtc (RtcReader)
    if (!@hasDecl(spec, "rtc")) {
        @compileError("Board spec must have 'rtc' (hal.RtcReader) for time source");
    }
    const rtc_field = @field(spec, "rtc");
    if (@typeInfo(@TypeOf(rtc_field)) != .type or !rtc_mod.isRtcReaderType(rtc_field)) {
        @compileError("Board spec.rtc must be a hal.RtcReader type");
    }

    return struct {
        pub const button_group_count = countType(spec, .button_group);
        pub const button_count = countType(spec, .button);
        pub const rgb_led_strip_count = countType(spec, .rgb_led_strip);
        pub const led_count = countType(spec, .led);
        pub const wifi_count = countType(spec, .wifi);
        pub const temp_sensor_count = countType(spec, .temp_sensor);
        pub const kvs_count = countType(spec, .kvs);
        pub const has_buttons = button_group_count > 0 or button_count > 0;
        pub const ButtonId = extractButtonId(spec);

        // RtcReader type (required)
        pub const RtcReaderType = @field(spec, "rtc");
        pub const RtcDriverType = RtcReaderType.DriverType;

        fn countType(comptime s: type, comptime kind: PeripheralKind) comptime_int {
            var n: comptime_int = 0;
            for (@typeInfo(s).@"struct".decls) |decl| {
                if (@hasDecl(s, decl.name)) {
                    const F = @TypeOf(@field(s, decl.name));
                    if (@typeInfo(F) == .type) {
                        if (getPeripheralKind(@field(s, decl.name)) == kind) n += 1;
                    }
                }
            }
            return n;
        }

        fn extractButtonId(comptime s: type) type {
            // First check if spec defines ButtonId directly
            if (@hasDecl(s, "ButtonId")) {
                const F = @TypeOf(@field(s, "ButtonId"));
                if (@typeInfo(F) == .type) {
                    return @field(s, "ButtonId");
                }
            }
            // Then try to extract from ButtonGroup
            for (@typeInfo(s).@"struct".decls) |decl| {
                if (@hasDecl(s, decl.name)) {
                    const F = @TypeOf(@field(s, decl.name));
                    if (@typeInfo(F) == .type) {
                        const T = @field(s, decl.name);
                        if (button_group_mod.isButtonGroupType(T)) return T.ButtonIdType;
                    }
                }
            }
            // Default: single button with id 0
            return enum(u8) { default = 0 };
        }
    };
}

// ============================================================================
// Board (v4) - Only needs spec, extracts everything from it
// ============================================================================

/// Create a Board type from spec
///
/// Required: spec.rtc (RtcReader) for time source
/// Optional: buttons, button, led, wifi, etc.
pub fn Board(comptime spec: type) type {
    const analysis = SpecAnalysis(spec);

    // Get Queue implementation from spec or use default
    const QueueImpl = if (@hasDecl(spec, "Queue")) spec.Queue else SimpleQueue;

    // RTC types (required)
    const RtcReaderType = analysis.RtcReaderType;
    const RtcDriverType = analysis.RtcDriverType;

    // Extract types from HAL components in spec (optional)
    const ButtonGroupType = if (analysis.button_group_count > 0) getButtonGroupType(spec) else void;
    const ButtonGroupDriverType = if (analysis.button_group_count > 0) ButtonGroupType.DriverType else void;
    const ButtonType = if (analysis.button_count > 0) getButtonType(spec) else void;
    const ButtonDriverType = if (analysis.button_count > 0) ButtonType.DriverType else void;
    const RgbLedStripType = if (analysis.rgb_led_strip_count > 0) getRgbLedStripType(spec) else void;
    const RgbLedStripDriverType = if (analysis.rgb_led_strip_count > 0) RgbLedStripType.DriverType else void;
    const LedType = if (analysis.led_count > 0) getLedType(spec) else void;
    const LedDriverType = if (analysis.led_count > 0) LedType.DriverType else void;
    const TempSensorType = if (analysis.temp_sensor_count > 0) getTempSensorType(spec) else void;
    const TempSensorDriverType = if (analysis.temp_sensor_count > 0) TempSensorType.DriverType else void;
    const KvsType = if (analysis.kvs_count > 0) getKvsType(spec) else void;
    const KvsDriverType = if (analysis.kvs_count > 0) KvsType.DriverType else void;

    // Generate Event type
    const Event = union(enum) {
        button: if (analysis.has_buttons) ButtonEventPayload(analysis.ButtonId) else void,
        system: event_mod.SystemEvent,
        timer: event_mod.TimerEvent,
        wifi: if (analysis.wifi_count > 0) wifi_mod.WifiEvent else void,
    };

    return struct {
        const Self = @This();

        // ================================================================
        // Exported Types
        // ================================================================

        pub const EventType = Event;
        pub const ButtonId = analysis.ButtonId;
        pub const ButtonAction = button_mod.ButtonAction;
        pub const ButtonGroup = ButtonGroupType;
        pub const Button = ButtonType;
        pub const RgbLedStrip = RgbLedStripType;
        pub const Led = LedType;
        pub const TempSensor = TempSensorType;
        pub const Kvs = KvsType;
        pub const RtcReader = RtcReaderType;

        // ================================================================
        // Fields
        // ================================================================

        // Event queue
        events: QueueImpl(Event, 64),

        // RTC (required - provides time source)
        rtc_driver: RtcDriverType,
        rtc: RtcReaderType,

        // ButtonGroup (if present)
        buttons_driver: if (analysis.button_group_count > 0) ButtonGroupDriverType else void,
        buttons: if (analysis.button_group_count > 0) ButtonGroupType else void,

        // Button (if present)
        button_driver: if (analysis.button_count > 0) ButtonDriverType else void,
        button: if (analysis.button_count > 0) ButtonType else void,

        // RgbLedStrip (if present)
        rgb_leds_driver: if (analysis.rgb_led_strip_count > 0) RgbLedStripDriverType else void,
        rgb_leds: if (analysis.rgb_led_strip_count > 0) RgbLedStripType else void,

        // Led (if present)
        led_driver: if (analysis.led_count > 0) LedDriverType else void,
        led: if (analysis.led_count > 0) LedType else void,

        // TempSensor (if present)
        temp_driver: if (analysis.temp_sensor_count > 0) TempSensorDriverType else void,
        temp: if (analysis.temp_sensor_count > 0) TempSensorType else void,

        // Kvs (if present)
        kvs_driver: if (analysis.kvs_count > 0) KvsDriverType else void,
        kvs: if (analysis.kvs_count > 0) KvsType else void,

        // ================================================================
        // Lifecycle
        // ================================================================

        /// Initialize board in-place - use this pattern:
        /// ```
        /// var board: Board = undefined;
        /// try board.init();
        /// defer board.deinit();
        /// ```
        pub fn init(self: *Self) !void {
            self.events = QueueImpl(Event, 64).init();

            // Initialize RTC first (required - provides time source)
            self.rtc_driver = try RtcDriverType.init();
            errdefer self.rtc_driver.deinit();

            // Initialize ButtonGroup driver
            if (analysis.button_group_count > 0) {
                self.buttons_driver = try ButtonGroupDriverType.init();
                errdefer self.buttons_driver.deinit();
            }

            // Initialize Button driver
            if (analysis.button_count > 0) {
                self.button_driver = try ButtonDriverType.init();
                errdefer self.button_driver.deinit();
            }

            // Initialize RgbLedStrip driver
            if (analysis.rgb_led_strip_count > 0) {
                self.rgb_leds_driver = try RgbLedStripDriverType.init();
                errdefer {
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Led driver
            if (analysis.led_count > 0) {
                self.led_driver = try LedDriverType.init();
                errdefer {
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize TempSensor driver
            if (analysis.temp_sensor_count > 0) {
                self.temp_driver = try TempSensorDriverType.init();
                errdefer {
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize Kvs driver
            if (analysis.kvs_count > 0) {
                self.kvs_driver = try KvsDriverType.init();
                errdefer {
                    if (analysis.temp_sensor_count > 0) self.temp_driver.deinit();
                    if (analysis.led_count > 0) self.led_driver.deinit();
                    if (analysis.rgb_led_strip_count > 0) self.rgb_leds_driver.deinit();
                    if (analysis.button_group_count > 0) self.buttons_driver.deinit();
                    if (analysis.button_count > 0) self.button_driver.deinit();
                }
            }

            // Initialize HAL wrappers with driver pointers (now pointing to correct locations)
            self.rtc = RtcReaderType.init(&self.rtc_driver);
            if (analysis.button_group_count > 0) {
                self.buttons = ButtonGroupType.init(&self.buttons_driver, &uptimeWrapper);
            }
            if (analysis.button_count > 0) {
                self.button = ButtonType.init(&self.button_driver);
            }
            if (analysis.rgb_led_strip_count > 0) {
                self.rgb_leds = RgbLedStripType.init(&self.rgb_leds_driver);
            }
            if (analysis.led_count > 0) {
                self.led = LedType.init(&self.led_driver);
            }
            if (analysis.temp_sensor_count > 0) {
                self.temp = TempSensorType.init(&self.temp_driver);
            }
            if (analysis.kvs_count > 0) {
                self.kvs = KvsType.init(&self.kvs_driver);
            }
        }

        // Static wrapper for uptime (used by ButtonGroup)
        var static_rtc_driver: ?*RtcDriverType = null;

        fn uptimeWrapper() u64 {
            if (static_rtc_driver) |drv| {
                return drv.uptime();
            }
            return 0;
        }

        /// Deinitialize board
        pub fn deinit(self: *Self) void {
            if (analysis.kvs_count > 0) {
                self.kvs_driver.deinit();
            }
            if (analysis.temp_sensor_count > 0) {
                self.temp_driver.deinit();
            }
            if (analysis.led_count > 0) {
                self.led.off();
                self.led_driver.deinit();
            }
            if (analysis.rgb_led_strip_count > 0) {
                self.rgb_leds.clear();
                self.rgb_leds_driver.deinit();
            }
            if (analysis.button_count > 0) {
                self.button_driver.deinit();
            }
            if (analysis.button_group_count > 0) {
                self.buttons_driver.deinit();
            }
            self.rtc_driver.deinit();
            self.events.deinit();
            static_rtc_driver = null;
        }

        // ================================================================
        // Event Queue
        // ================================================================

        /// Get next event
        pub fn nextEvent(self: *Self) ?Event {
            return self.events.tryReceive();
        }

        /// Check if there are pending events
        pub fn hasEvents(self: *const Self) bool {
            return !self.events.isEmpty();
        }

        // ================================================================
        // Polling
        // ================================================================

        /// Poll all peripherals
        pub fn poll(self: *Self) void {
            // Set static pointer for uptime wrapper
            static_rtc_driver = &self.rtc_driver;

            // Poll ButtonGroup
            if (analysis.button_group_count > 0) {
                self.buttons.poll();
                while (self.buttons.nextEvent()) |btn_event| {
                    _ = self.events.trySend(.{ .button = .{
                        .source = btn_event.source,
                        .id = btn_event.id,
                        .action = btn_event.action,
                        .timestamp_ms = btn_event.timestamp_ms,
                        .click_count = btn_event.click_count,
                        .duration_ms = btn_event.duration_ms,
                    } });
                }
            }

            // Poll single Button
            if (analysis.button_count > 0) {
                const current_time = self.rtc.uptime();
                if (self.button.poll(current_time)) |btn_event| {
                    _ = self.events.trySend(.{ .button = .{
                        .source = btn_event.source,
                        .id = @enumFromInt(0),
                        .action = btn_event.action,
                        .timestamp_ms = current_time,
                        .click_count = 1,
                        .duration_ms = btn_event.duration_ms,
                    } });
                }
            }
        }

        // ================================================================
        // Time (via RTC)
        // ================================================================

        /// Get monotonic uptime in milliseconds
        pub fn uptime(self: *Self) u64 {
            return self.rtc.uptime();
        }

        /// Get wall-clock time (if synced)
        pub fn now(self: *Self) ?rtc_mod.Timestamp {
            return self.rtc.now();
        }
    };
}

// ============================================================================
// Type Helpers
// ============================================================================

fn getButtonGroupType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (button_group_mod.isButtonGroupType(T)) return T;
            }
        }
    }
    @compileError("No ButtonGroup found in spec");
}

fn getButtonType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (button_mod.isButtonType(T)) return T;
            }
        }
    }
    @compileError("No Button found in spec");
}

fn getRgbLedStripType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (rgb_led_strip_mod.isRgbLedStripType(T)) return T;
            }
        }
    }
    @compileError("No RgbLedStrip found in spec");
}

fn getLedType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (led_mod.isLedType(T)) return T;
            }
        }
    }
    @compileError("No Led found in spec");
}

fn getTempSensorType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (temp_sensor_mod.isTempSensorType(T)) return T;
            }
        }
    }
    @compileError("No TempSensor found in spec");
}

fn getKvsType(comptime spec: type) type {
    for (@typeInfo(spec).@"struct".decls) |decl| {
        if (@hasDecl(spec, decl.name)) {
            const F = @TypeOf(@field(spec, decl.name));
            if (@typeInfo(F) == .type) {
                const T = @field(spec, decl.name);
                if (kvs_mod.isKvsType(T)) return T;
            }
        }
    }
    @compileError("No Kvs found in spec");
}

fn ButtonEventPayload(comptime ButtonId: type) type {
    return struct {
        source: []const u8,
        id: ButtonId,
        action: button_mod.ButtonAction,
        timestamp_ms: u64,
        click_count: u8 = 1,
        duration_ms: u32 = 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "SimpleQueue basic operations" {
    var q = SimpleQueue(u32, 4).init();

    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.trySend(1));
    try std.testing.expect(q.trySend(2));
    try std.testing.expect(!q.isEmpty());
    try std.testing.expectEqual(@as(usize, 2), q.count());

    try std.testing.expectEqual(@as(?u32, 1), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, 2), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, null), q.tryReceive());
}

test "SimpleQueue overflow" {
    var q = SimpleQueue(u32, 2).init();

    try std.testing.expect(q.trySend(1));
    try std.testing.expect(q.trySend(2));
    try std.testing.expect(!q.trySend(3)); // Should fail - full

    try std.testing.expectEqual(@as(?u32, 1), q.tryReceive());
    try std.testing.expect(q.trySend(3)); // Now should work
}

test "SpecAnalysis with rtc only" {
    const MockRtcDriver = struct {
        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn uptime(_: *@This()) u64 {
            return 0;
        }
        pub fn read(_: *@This()) ?i64 {
            return null;
        }
    };

    const rtc_spec = struct {
        pub const Driver = MockRtcDriver;
        pub const meta = @import("spec.zig").Meta{ .id = "rtc" };
    };

    const minimal_spec = struct {
        pub const rtc = rtc_mod.RtcReader(rtc_spec);
    };
    const analysis = SpecAnalysis(minimal_spec);

    try std.testing.expectEqual(@as(comptime_int, 0), analysis.button_group_count);
    try std.testing.expectEqual(@as(comptime_int, 0), analysis.button_count);
    try std.testing.expectEqual(@as(comptime_int, 0), analysis.rgb_led_strip_count);
    try std.testing.expectEqual(@as(comptime_int, 0), analysis.wifi_count);
    try std.testing.expect(!analysis.has_buttons);
}
