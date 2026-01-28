//! HAL Button Group Abstraction (ADC Mode)
//!
//! Provides ButtonGroup(spec, ButtonId) for managing multiple ADC buttons
//! connected through a resistor ladder on a single ADC channel.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   board.buttons.poll() -> event        │
//! ├─────────────────────────────────────────┤
//! │ ButtonGroup(spec, ButtonId)  ← HAL     │
//! │   - ADC value → button mapping          │
//! │   - debouncing                          │
//! │   - click/double-click detection        │
//! │   - long press detection                │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← hardware impl  │
//! │   - readRaw() -> u16                    │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // Application defines ButtonId
//! const ButtonId = enum(u8) { vol_up, vol_down, play, mute };
//!
//! // Define spec with driver and ADC ranges
//! const buttons_spec = struct {
//!     pub const Driver = AdcReader;  // must have readRaw() -> u16
//!     pub const ranges = &[_]Range{
//!         .{ .id = 0, .min = 250, .max = 600 },   // vol_up
//!         .{ .id = 1, .min = 750, .max = 1100 },  // vol_down
//!         // ...
//!     };
//!     pub const ref_value: u16 = 4095;  // ADC value when no button pressed
//!     pub const ref_tolerance: u16 = 200;
//!     pub const meta = hal.Meta{ .id = "buttons.main" };
//! };
//!
//! const Buttons = hal.ButtonGroup(buttons_spec, ButtonId);
//! var btns = Buttons.init(&driver, time_fn);
//!
//! // Poll and get events
//! btns.poll();
//! while (btns.nextEvent()) |event| {
//!     switch (event.id) {
//!         .vol_up => if (event.action == .click) volumeUp(),
//!         .play => if (event.action == .long_press) showMenu(),
//!         else => {},
//!     }
//! }
//! ```

const std = @import("std");

const button_mod = @import("button.zig");
/// Re-export ButtonAction from button module for consistency
pub const ButtonAction = button_mod.ButtonAction;
// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
/// This ensures only types created via ButtonGroup() can be identified as ButtonGroup
const _ButtonGroupMarker = struct {};

/// Check if a type is a ButtonGroup peripheral (internal use only)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _ButtonGroupMarker;
}

/// ADC range configuration
pub const Range = struct {
    id: u8,
    min: u16,
    max: u16,
};

/// ButtonGroup configuration
pub const ButtonGroupConfig = struct {
    /// Long press threshold in milliseconds
    long_press_ms: u32 = 1000,
    /// Click gap window in milliseconds (for consecutive clicks)
    click_gap_ms: u32 = 300,
};

/// Event from ButtonGroup
pub fn ButtonGroupEvent(comptime ButtonId: type) type {
    return struct {
        /// Component identifier (from spec.meta.id)
        source: []const u8,
        /// Which button
        id: ButtonId,
        /// What happened
        action: ButtonAction,
        /// Timestamp
        timestamp_ms: u64,
        /// Click count (for click events)
        click_count: u8 = 1,
        /// Duration (for release/long_press)
        duration_ms: u32 = 0,
    };
}

/// Button Group HAL component (ADC mode)
///
/// spec must define:
/// - `Driver`: struct with readRaw() -> u16 method
/// - `ranges`: &[_]Range - ADC value ranges for each button
/// - `ref_value`: u16 - ADC value when no button is pressed
/// - `ref_tolerance`: u16 - tolerance for detecting ref state (optional, default 200)
/// - `meta`: spec.Meta with component id
///
/// ButtonId must be an enum(u8) type defined by the application.
pub fn from(comptime spec: type, comptime ButtonId: type) type {
    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };
        // Verify Driver.readRaw signature
        _ = @as(*const fn (*BaseDriver) u16, &BaseDriver.readRaw);
        // Verify ranges
        _ = @as([]const Range, spec.ranges);
        // Verify ref_value
        _ = @as(u16, spec.ref_value);
        // Verify meta.id
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    const num_buttons = @typeInfo(ButtonId).@"enum".fields.len;
    const ref_tolerance: u16 = if (@hasDecl(spec, "ref_tolerance")) spec.ref_tolerance else 200;

    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _ButtonGroupMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;
        pub const ButtonIdType = ButtonId;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// Event type
        pub const Event = ButtonGroupEvent(ButtonId);

        /// Per-button tracking state
        const ButtonTracking = struct {
            /// Event ring buffer (simplified)
            down_ms: u64 = 0,
            up_ms: u64 = 0,
            last_click_ms: u64 = 0,
            consecutive_clicks: u8 = 0,
            is_pressed: bool = false,
            long_press_fired: bool = false,
        };

        /// The underlying driver instance
        driver: *Driver,

        /// Time function
        time_fn: *const fn () u64,

        /// Configuration
        config: ButtonGroupConfig,

        /// Per-button tracking
        tracking: [num_buttons]ButtonTracking = [_]ButtonTracking{.{}} ** num_buttons,

        /// ADC state machine
        current_button: ?ButtonId = null,
        is_at_ref: bool = true,
        last_raw: u16 = 0,

        /// Event queue for multiple events per poll
        event_queue: [8]Event = undefined,
        event_count: u8 = 0,
        event_index: u8 = 0,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver, time_fn: *const fn () u64) Self {
            return Self.initWithConfig(driver, time_fn, .{});
        }

        /// Initialize with custom configuration
        pub fn initWithConfig(driver: *Driver, time_fn: *const fn () u64, config: ButtonGroupConfig) Self {
            return .{
                .driver = driver,
                .time_fn = time_fn,
                .config = config,
            };
        }

        /// Poll ADC and process button state changes
        pub fn poll(self: *Self) void {
            const now_ms = self.time_fn();
            const raw = self.driver.readRaw();
            self.last_raw = raw;

            // Check if at reference (no button pressed)
            const cur_is_ref = isRefValue(raw);

            // State transition detection
            if (cur_is_ref != self.is_at_ref) {
                if (!cur_is_ref) {
                    // Transition: ref → non-ref (button pressed)
                    const new_button = findButton(raw);
                    self.handleButtonPress(new_button, now_ms);
                } else {
                    // Transition: non-ref → ref (button released)
                    self.handleButtonRelease(now_ms);
                }
                self.is_at_ref = cur_is_ref;
            }

            // Check for long press while held
            if (self.current_button) |btn_id| {
                const idx = @intFromEnum(btn_id);
                const track = &self.tracking[idx];
                if (track.is_pressed and !track.long_press_fired) {
                    const held_ms = now_ms -| track.down_ms;
                    if (held_ms >= self.config.long_press_ms) {
                        track.long_press_fired = true;
                        self.queueEvent(.{
                            .source = meta.id,
                            .id = btn_id,
                            .action = .long_press,
                            .timestamp_ms = now_ms,
                            .duration_ms = @intCast(held_ms),
                        });
                    }
                }
            }
        }

        /// Get next event from queue
        pub fn nextEvent(self: *Self) ?Event {
            if (self.event_index < self.event_count) {
                const event = self.event_queue[self.event_index];
                self.event_index += 1;
                return event;
            }
            // Reset queue when exhausted
            self.event_count = 0;
            self.event_index = 0;
            return null;
        }

        /// Handle button press
        fn handleButtonPress(self: *Self, new_button: ?ButtonId, now_ms: u64) void {
            // Release previous button if any
            if (self.current_button) |prev_btn| {
                const idx = @intFromEnum(prev_btn);
                self.tracking[idx].is_pressed = false;
            }

            self.current_button = new_button;

            if (new_button) |btn_id| {
                const idx = @intFromEnum(btn_id);
                const track = &self.tracking[idx];

                track.is_pressed = true;
                track.down_ms = now_ms;
                track.long_press_fired = false;

                self.queueEvent(.{
                    .source = meta.id,
                    .id = btn_id,
                    .action = .press,
                    .timestamp_ms = now_ms,
                });
            }
        }

        /// Handle button release
        fn handleButtonRelease(self: *Self, now_ms: u64) void {
            if (self.current_button) |btn_id| {
                const idx = @intFromEnum(btn_id);
                const track = &self.tracking[idx];

                track.is_pressed = false;
                track.up_ms = now_ms;

                const duration: u32 = @intCast(now_ms -| track.down_ms);

                // Calculate consecutive clicks
                if (track.last_click_ms > 0 and
                    now_ms -| track.last_click_ms <= self.config.click_gap_ms)
                {
                    track.consecutive_clicks += 1;
                } else {
                    track.consecutive_clicks = 1;
                }
                track.last_click_ms = now_ms;

                // Determine action based on click count
                const action: ButtonAction = if (track.consecutive_clicks >= 2)
                    .double_click
                else
                    .click;

                self.queueEvent(.{
                    .source = meta.id,
                    .id = btn_id,
                    .action = action,
                    .timestamp_ms = now_ms,
                    .click_count = track.consecutive_clicks,
                    .duration_ms = duration,
                });

                // Also emit release event
                self.queueEvent(.{
                    .source = meta.id,
                    .id = btn_id,
                    .action = .release,
                    .timestamp_ms = now_ms,
                    .duration_ms = duration,
                });

                self.current_button = null;
            }
        }

        /// Check if raw value is at reference (no button pressed)
        fn isRefValue(raw: u16) bool {
            const ref = spec.ref_value;
            if (raw >= ref -| ref_tolerance and raw <= ref +| ref_tolerance) {
                return true;
            }
            // Also check if significantly above ref (overflow)
            if (raw > ref) return true;
            return false;
        }

        /// Find button by raw ADC value
        fn findButton(raw: u16) ?ButtonId {
            for (spec.ranges) |range| {
                if (raw >= range.min and raw <= range.max) {
                    return @enumFromInt(range.id);
                }
            }
            return null;
        }

        /// Check if a specific button is pressed
        pub fn isPressed(self: *const Self, id: ButtonId) bool {
            return self.tracking[@intFromEnum(id)].is_pressed;
        }

        /// Check if any button is pressed
        pub fn isAnyPressed(self: *const Self) bool {
            return self.current_button != null;
        }

        /// Get last raw ADC value (for debugging/calibration)
        pub fn getLastRaw(self: *const Self) u16 {
            return self.last_raw;
        }

        /// Reset all button states
        pub fn reset(self: *Self) void {
            for (&self.tracking) |*t| {
                t.* = .{};
            }
            self.current_button = null;
            self.is_at_ref = true;
            self.event_count = 0;
            self.event_index = 0;
        }

        // Internal: queue an event
        fn queueEvent(self: *Self, event: Event) void {
            if (self.event_count < self.event_queue.len) {
                self.event_queue[self.event_count] = event;
                self.event_count += 1;
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ButtonGroup ADC mode" {
    const TestButtonId = enum(u8) { btn_a = 0, btn_b = 1, btn_c = 2 };

    const MockTime = struct {
        var t: u64 = 0;
        pub fn now() u64 {
            return t;
        }
    };

    const MockDriver = struct {
        raw: u16 = 4095,

        pub fn readRaw(self: *@This()) u16 {
            return self.raw;
        }
    };

    const btns_spec = struct {
        pub const Driver = MockDriver;
        pub const ranges = &[_]Range{
            .{ .id = 0, .min = 200, .max = 400 }, // btn_a
            .{ .id = 1, .min = 600, .max = 800 }, // btn_b
            .{ .id = 2, .min = 1000, .max = 1200 }, // btn_c
        };
        pub const ref_value: u16 = 4095;
        pub const ref_tolerance: u16 = 200;
        pub const meta = .{ .id = "buttons.test" };
    };

    const TestButtonGroup = from(btns_spec, TestButtonId);

    var driver = MockDriver{};
    var btns = TestButtonGroup.initWithConfig(&driver, MockTime.now, .{
        .long_press_ms = 500,
    });

    // Initial state - no button
    try std.testing.expect(!btns.isAnyPressed());
    try std.testing.expectEqualStrings("buttons.test", TestButtonGroup.meta.id);

    // Press btn_a (raw = 300)
    driver.raw = 300;
    MockTime.t = 100;
    btns.poll();

    var event = btns.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(TestButtonId.btn_a, event.?.id);
    try std.testing.expectEqual(ButtonAction.press, event.?.action);
    try std.testing.expect(btns.isPressed(.btn_a));

    // No more events
    try std.testing.expect(btns.nextEvent() == null);

    // Release (return to ref)
    driver.raw = 4095;
    MockTime.t = 200;
    btns.poll();

    // Should get click + release events
    event = btns.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.click, event.?.action);

    event = btns.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.release, event.?.action);

    try std.testing.expect(!btns.isAnyPressed());
}

test "ButtonGroup long press" {
    const TestButtonId = enum(u8) { btn = 0 };

    const MockTime = struct {
        var t: u64 = 0;
        pub fn now() u64 {
            return t;
        }
    };

    const MockDriver = struct {
        raw: u16 = 4095,
        pub fn readRaw(self: *@This()) u16 {
            return self.raw;
        }
    };

    const btns_spec = struct {
        pub const Driver = MockDriver;
        pub const ranges = &[_]Range{
            .{ .id = 0, .min = 200, .max = 400 },
        };
        pub const ref_value: u16 = 4095;
        pub const meta = .{ .id = "buttons.long" };
    };

    const TestButtonGroup = from(btns_spec, TestButtonId);

    var driver = MockDriver{};
    var btns = TestButtonGroup.initWithConfig(&driver, MockTime.now, .{
        .long_press_ms = 500,
    });

    // Press
    driver.raw = 300;
    MockTime.t = 0;
    btns.poll();

    var event = btns.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.press, event.?.action);

    // Hold but not long enough
    MockTime.t = 400;
    btns.poll();
    try std.testing.expect(btns.nextEvent() == null);

    // Long press threshold
    MockTime.t = 510;
    btns.poll();
    event = btns.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.long_press, event.?.action);

    // No more long press events
    MockTime.t = 600;
    btns.poll();
    try std.testing.expect(btns.nextEvent() == null);
}

test "ButtonGroup double click" {
    const TestButtonId = enum(u8) { btn = 0 };

    const MockTime = struct {
        var t: u64 = 0;
        pub fn now() u64 {
            return t;
        }
    };

    const MockDriver = struct {
        raw: u16 = 4095,
        pub fn readRaw(self: *@This()) u16 {
            return self.raw;
        }
    };

    const btns_spec = struct {
        pub const Driver = MockDriver;
        pub const ranges = &[_]Range{
            .{ .id = 0, .min = 200, .max = 400 },
        };
        pub const ref_value: u16 = 4095;
        pub const meta = .{ .id = "buttons.double" };
    };

    const TestButtonGroup = from(btns_spec, TestButtonId);

    var driver = MockDriver{};
    var btns = TestButtonGroup.initWithConfig(&driver, MockTime.now, .{
        .click_gap_ms = 300,
    });

    // First click
    driver.raw = 300;
    MockTime.t = 0;
    btns.poll();
    _ = btns.nextEvent(); // press

    driver.raw = 4095;
    MockTime.t = 50;
    btns.poll();
    var event = btns.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.click, event.?.action);
    try std.testing.expectEqual(@as(u8, 1), event.?.click_count);
    _ = btns.nextEvent(); // release

    // Second click within gap
    driver.raw = 300;
    MockTime.t = 200;
    btns.poll();
    _ = btns.nextEvent(); // press

    driver.raw = 4095;
    MockTime.t = 250;
    btns.poll();
    event = btns.nextEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.double_click, event.?.action);
    try std.testing.expectEqual(@as(u8, 2), event.?.click_count);
}
