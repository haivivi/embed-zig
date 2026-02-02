//! HAL Event System
//!
//! Unified event types for hardware abstraction.
//! Events are produced by hardware components (buttons, sensors, etc.)
//! and consumed by the application through a single queue.
//!
//! ## New Architecture (spec-based)
//!
//! HAL components (Button, ButtonGroup, LedStrip) produce events with
//! a `source` field identifying the component that generated the event.
//!
//! Example:
//!   ```zig
//!   // Button component produces SingleButtonEvent
//!   if (board.btn_power.poll(now_ms)) |event| {
//!       // event.source = "btn.power"
//!       // event.action = .click
//!   }
//!
//!   // ButtonGroup produces ButtonGroupEvent
//!   if (board.buttons.poll(now_ms)) |event| {
//!       // event.source = "buttons.main"
//!       // event.id = .vol_up
//!       // event.action = .press
//!   }
//!   ```
//!
//! ## Legacy Architecture (Config-based)
//!
//! The old Event(Config) type is kept for backward compatibility.

const std = @import("std");

const button_group_mod = @import("button_group.zig");
const button_mod = @import("button.zig");
const wifi_mod = @import("wifi.zig");

// ============================================================================
// Unified Event System (New Architecture)
// ============================================================================

/// Unified event for Board event bus
/// Contains events from all HAL components with source identification
pub fn UnifiedEvent(comptime ButtonId: type) type {
    return union(enum) {
        const Self = @This();

        /// Button event (from Button or ButtonGroup)
        button: ButtonEventData(ButtonId),

        /// WiFi event (connection state changes, IP assignment, etc.)
        wifi: WifiEventData,

        /// Timer event
        timer: TimerEvent,

        /// System event
        system: SystemEvent,

        /// Format event for debugging
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            switch (self) {
                .button => |btn| {
                    try writer.print("Button({s}: {s}, {s})", .{
                        btn.source,
                        @tagName(btn.id),
                        @tagName(btn.action),
                    });
                },
                .wifi => |w| {
                    try writer.print("WiFi({s}: {s})", .{
                        w.source,
                        @tagName(w.event),
                    });
                },
                .timer => |t| try writer.print("Timer(id={d})", .{t.id}),
                .system => |s| try writer.print("System({s})", .{@tagName(s)}),
            }
        }
    };
}

/// Button event data with source identification
pub fn ButtonEventData(comptime ButtonId: type) type {
    return struct {
        /// Source component ID (from spec.meta.id)
        source: []const u8,

        /// Button identifier
        id: ButtonId,

        /// Action that occurred
        action: button_mod.ButtonAction,

        /// Event timestamp in milliseconds
        timestamp_ms: u64,

        /// Click count (for click events)
        click_count: u8 = 1,

        /// Duration (for release/long_press)
        duration_ms: u32 = 0,

        /// Create from SingleButtonEvent (for single buttons without ButtonId)
        /// Note: This maps to a default button ID, use fromButtonGroup for groups
        pub fn fromSingleButton(event: button_mod.SingleButtonEvent, default_id: ButtonId) @This() {
            return .{
                .source = event.source,
                .id = default_id,
                .action = event.action,
                .timestamp_ms = event.timestamp_ms,
                .click_count = event.click_count,
                .duration_ms = event.duration_ms,
            };
        }

        /// Create from ButtonGroupEvent
        pub fn fromButtonGroup(event: button_group_mod.ButtonGroupEvent(ButtonId)) @This() {
            return .{
                .source = event.source,
                .id = event.id,
                .action = event.action,
                .timestamp_ms = event.timestamp_ms,
                .click_count = event.click_count,
                .duration_ms = event.duration_ms,
            };
        }
    };
}

/// WiFi event data with source identification
pub const WifiEventData = struct {
    /// Source component ID (from spec.meta.id)
    source: []const u8,

    /// WiFi event that occurred
    event: wifi_mod.WifiEvent,

    /// Event timestamp in milliseconds
    timestamp_ms: u64 = 0,
};

// ============================================================================
// Legacy Event System (Backward Compatibility)
// ============================================================================

/// Create an Event type parameterized by hardware configuration
///
/// Config must define:
///   - ButtonId: enum type for button identifiers
///
/// Optional Config fields:
///   - SensorId: enum type for sensor identifiers
///   - LedId: enum type for LED identifiers
pub fn Event(comptime Config: type) type {
    // Validate Config has required types
    if (!@hasDecl(Config, "ButtonId")) {
        @compileError("Config must define ButtonId enum type");
    }

    return union(enum) {
        const Self = @This();

        /// Button event
        button: ButtonEvent(Config),

        /// WiFi event
        wifi: WifiEventData,

        /// Timer event
        timer: TimerEvent,

        /// System event
        system: SystemEvent,

        /// Format event for debugging
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            switch (self) {
                .button => |btn| try writer.print("Button({s}, {s})", .{
                    @tagName(btn.id),
                    @tagName(btn.action),
                }),
                .wifi => |w| try writer.print("WiFi({s}: {s})", .{
                    w.source,
                    @tagName(w.event),
                }),
                .timer => |t| try writer.print("Timer(id={d})", .{t.id}),
                .system => |s| try writer.print("System({s})", .{@tagName(s)}),
            }
        }
    };
}

// ============================================================================
// Button Events
// ============================================================================

/// Button action type
pub const ButtonAction = enum {
    /// Button was pressed down
    press,
    /// Button was released
    release,
    /// Long press detected (while still held)
    long_press,
    /// Single click completed
    click,
    /// Double click completed
    double_click,
    /// Triple click completed
    triple_click,
};

/// Create a ButtonEvent type with Config-defined ButtonId
pub fn ButtonEvent(comptime Config: type) type {
    return struct {
        const Self = @This();

        /// Button identifier (from Config)
        id: Config.ButtonId,

        /// Action that occurred
        action: ButtonAction,

        /// Event timestamp in milliseconds
        timestamp: u64,

        /// Additional data depending on action
        /// - For press/release: duration of previous state
        /// - For click events: number of consecutive clicks
        data: u32 = 0,

        /// Create a press event
        pub fn press(id: Config.ButtonId, timestamp: u64) Self {
            return .{
                .id = id,
                .action = .press,
                .timestamp = timestamp,
            };
        }

        /// Create a release event
        pub fn release(id: Config.ButtonId, timestamp: u64, press_duration_ms: u32) Self {
            return .{
                .id = id,
                .action = .release,
                .timestamp = timestamp,
                .data = press_duration_ms,
            };
        }

        /// Create a click event
        pub fn click(id: Config.ButtonId, timestamp: u64, consecutive: u8) Self {
            return .{
                .id = id,
                .action = switch (consecutive) {
                    1 => .click,
                    2 => .double_click,
                    else => .triple_click,
                },
                .timestamp = timestamp,
                .data = consecutive,
            };
        }

        /// Create a long press event
        pub fn longPress(id: Config.ButtonId, timestamp: u64, duration_ms: u32) Self {
            return .{
                .id = id,
                .action = .long_press,
                .timestamp = timestamp,
                .data = duration_ms,
            };
        }
    };
}

// ============================================================================
// Timer Events
// ============================================================================

/// Timer event for scheduled callbacks
pub const TimerEvent = struct {
    /// Timer identifier
    id: u8,

    /// Timer-specific data
    data: u32 = 0,
};

// ============================================================================
// System Events
// ============================================================================

/// System-level events
pub const SystemEvent = enum {
    /// System initialized and ready
    ready,
    /// Low battery warning
    low_battery,
    /// System going to sleep
    sleep,
    /// System waking up
    wake,
    /// Error occurred
    err,
};

// ============================================================================
// Tests
// ============================================================================

test "Event basic usage" {
    const TestConfig = struct {
        pub const ButtonId = enum(u8) {
            vol_up,
            vol_down,
            play,
        };
    };

    const TestEvent = Event(TestConfig);
    const ButtonEvt = ButtonEvent(TestConfig);

    // Create button event
    const btn_event = TestEvent{
        .button = ButtonEvt.press(.vol_up, 1000),
    };

    try std.testing.expectEqual(ButtonAction.press, btn_event.button.action);
    try std.testing.expectEqual(TestConfig.ButtonId.vol_up, btn_event.button.id);
    try std.testing.expectEqual(@as(u64, 1000), btn_event.button.timestamp);
}

test "Event switch" {
    const TestConfig = struct {
        pub const ButtonId = enum(u8) { a, b };
    };

    const TestEvent = Event(TestConfig);
    const ButtonEvt = ButtonEvent(TestConfig);

    const events = [_]TestEvent{
        .{ .button = ButtonEvt.press(.a, 100) },
        .{ .wifi = .{ .source = "wifi.main", .event = .connected } },
        .{ .timer = .{ .id = 1 } },
        .{ .system = .ready },
    };

    var button_count: usize = 0;
    var wifi_count: usize = 0;
    var timer_count: usize = 0;
    var system_count: usize = 0;

    for (events) |event| {
        switch (event) {
            .button => button_count += 1,
            .wifi => wifi_count += 1,
            .timer => timer_count += 1,
            .system => system_count += 1,
        }
    }

    try std.testing.expectEqual(@as(usize, 1), button_count);
    try std.testing.expectEqual(@as(usize, 1), wifi_count);
    try std.testing.expectEqual(@as(usize, 1), timer_count);
    try std.testing.expectEqual(@as(usize, 1), system_count);
}

test "ButtonEvent helpers" {
    const TestConfig = struct {
        pub const ButtonId = enum(u8) { btn1 };
    };

    const ButtonEvt = ButtonEvent(TestConfig);

    // Test press helper
    const press_evt = ButtonEvt.press(.btn1, 1000);
    try std.testing.expectEqual(ButtonAction.press, press_evt.action);

    // Test release helper
    const release_evt = ButtonEvt.release(.btn1, 1500, 500);
    try std.testing.expectEqual(ButtonAction.release, release_evt.action);
    try std.testing.expectEqual(@as(u32, 500), release_evt.data);

    // Test click helpers
    const click1 = ButtonEvt.click(.btn1, 2000, 1);
    try std.testing.expectEqual(ButtonAction.click, click1.action);

    const click2 = ButtonEvt.click(.btn1, 2000, 2);
    try std.testing.expectEqual(ButtonAction.double_click, click2.action);

    const click3 = ButtonEvt.click(.btn1, 2000, 3);
    try std.testing.expectEqual(ButtonAction.triple_click, click3.action);

    // Test long press helper
    const long = ButtonEvt.longPress(.btn1, 3000, 2000);
    try std.testing.expectEqual(ButtonAction.long_press, long.action);
    try std.testing.expectEqual(@as(u32, 2000), long.data);
}

test "UnifiedEvent basic usage" {
    const TestButtonId = enum { vol_up, vol_down, play };
    const TestEvent = UnifiedEvent(TestButtonId);
    const BtnData = ButtonEventData(TestButtonId);

    // Create button event
    const btn_event = TestEvent{
        .button = BtnData{
            .source = "buttons.main",
            .id = .vol_up,
            .action = .press,
            .timestamp_ms = 1000,
        },
    };

    try std.testing.expectEqualStrings("buttons.main", btn_event.button.source);
    try std.testing.expectEqual(TestButtonId.vol_up, btn_event.button.id);
    try std.testing.expectEqual(button_mod.ButtonAction.press, btn_event.button.action);
}

test "UnifiedEvent from ButtonGroupEvent" {
    const TestButtonId = enum { a, b };
    const BtnData = ButtonEventData(TestButtonId);
    const GroupEvent = button_group_mod.ButtonGroupEvent(TestButtonId);

    // Create a ButtonGroupEvent
    const group_event = GroupEvent{
        .source = "buttons.test",
        .id = .a,
        .action = .click,
        .timestamp_ms = 500,
        .click_count = 2,
    };

    // Convert to ButtonEventData
    const btn_data = BtnData.fromButtonGroup(group_event);

    try std.testing.expectEqualStrings("buttons.test", btn_data.source);
    try std.testing.expectEqual(TestButtonId.a, btn_data.id);
    try std.testing.expectEqual(button_mod.ButtonAction.click, btn_data.action);
    try std.testing.expectEqual(@as(u8, 2), btn_data.click_count);
}

test "UnifiedEvent WiFi events" {
    const TestButtonId = enum { play };
    const TestEvent = UnifiedEvent(TestButtonId);

    // Test WiFi connected event
    const connected_event = TestEvent{
        .wifi = .{
            .source = "wifi.main",
            .event = .connected,
            .timestamp_ms = 1000,
        },
    };
    try std.testing.expectEqualStrings("wifi.main", connected_event.wifi.source);

    // Test WiFi got_ip event
    const ip_event = TestEvent{
        .wifi = .{
            .source = "wifi.main",
            .event = .{ .got_ip = .{ 192, 168, 1, 100 } },
            .timestamp_ms = 2000,
        },
    };
    switch (ip_event.wifi.event) {
        .got_ip => |ip| {
            try std.testing.expectEqual(wifi_mod.IpAddress{ 192, 168, 1, 100 }, ip);
        },
        else => try std.testing.expect(false),
    }

    // Test WiFi disconnected event
    const disconnected_event = TestEvent{
        .wifi = .{
            .source = "wifi.main",
            .event = .{ .disconnected = .connection_lost },
            .timestamp_ms = 3000,
        },
    };
    switch (disconnected_event.wifi.event) {
        .disconnected => |reason| {
            try std.testing.expectEqual(wifi_mod.DisconnectReason.connection_lost, reason);
        },
        else => try std.testing.expect(false),
    }
}
