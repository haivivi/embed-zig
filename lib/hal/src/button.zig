//! HAL Button Abstraction
//!
//! Provides two button HAL types:
//!
//! - `Button(spec)` - Single button with debounce and click detection
//! - `ButtonGroup` - Legacy adapter for multiple buttons
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application                             │
//! │   if (board.btn_power.isPressed()) ... │
//! ├─────────────────────────────────────────┤
//! │ Button(spec)  ← HAL wrapper            │
//! │   - debounce                            │
//! │   - click/double-click detection        │
//! │   - long press detection                │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← hardware impl  │
//! │   - isPressed()                         │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! // Define spec with driver and metadata
//! const btn_spec = struct {
//!     pub const Driver = GpioButtonDriver;
//!     pub const meta = hal.spec.Meta{ .id = "btn.power" };
//! };
//!
//! const PowerButton = hal.Button(btn_spec);
//! var btn = PowerButton.init(&driver);
//!
//! // Poll and get events
//! if (btn.poll(now_ms)) |event| {
//!     switch (event.action) {
//!         .press => log.info("pressed"),
//!         .click => log.info("clicked"),
//!         .long_press => log.info("long press"),
//!         else => {},
//!     }
//! }
//! ```

const std = @import("std");

const event_mod = @import("event.zig");
const spec_mod = @import("spec.zig");

// ============================================================================
// Private Type Marker (for hal.Board identification)
// ============================================================================

/// Private marker type - NOT exported, used only for comptime type identification
const _ButtonMarker = struct {};

/// Check if a type is a Button peripheral (internal use only)
pub fn isButtonType(comptime T: type) bool {
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _ButtonMarker;
}

/// Button state from low-level driver
pub const ButtonState = struct {
    /// Whether the button is currently pressed
    is_pressed: bool = false,
    /// How long the button has been/was pressed (ms)
    press_duration_ms: u32 = 0,
    /// How long since the button was released (ms)
    release_duration_ms: u32 = 0,
    /// Number of consecutive clicks
    consecutive_clicks: u8 = 0,
};

/// Button action type
pub const ButtonAction = enum {
    /// Button just pressed
    press,
    /// Button just released
    release,
    /// Short click detected (after release)
    click,
    /// Double click detected
    double_click,
    /// Long press detected (while held)
    long_press,
};

/// Event from a single Button
pub const SingleButtonEvent = struct {
    /// Component identifier (from spec.meta.id)
    source: []const u8,
    /// What happened
    action: ButtonAction,
    /// Timestamp
    timestamp_ms: u64,
    /// Click count (for click events)
    click_count: u8 = 1,
    /// Duration (for release/long_press)
    duration_ms: u32 = 0,
};

/// Button configuration
pub const ButtonConfig = struct {
    /// Debounce time in milliseconds
    debounce_ms: u32 = 20,
    /// Long press threshold in milliseconds
    long_press_ms: u32 = 1000,
    /// Double click window in milliseconds
    double_click_ms: u32 = 300,
    /// Enable click detection
    detect_clicks: bool = true,
    /// Enable double click detection
    detect_double_click: bool = true,
};

// ============================================================================
// Button HAL Wrapper (Single Button)
// ============================================================================

/// Single Button HAL component
///
/// Wraps a low-level Driver and provides:
/// - Debounce filtering
/// - Click/double-click detection
/// - Long press detection
///
/// spec must define:
/// - `Driver`: struct with isPressed() method
/// - `meta`: spec.Meta with component id
pub fn Button(comptime spec: type) type {
    // Compile-time verification
    spec_mod.verifyButtonSpec(spec);

    const Driver = spec.Driver;

    return struct {
        const Self = @This();

        // ================================================================
        // Type Identification (for hal.Board)
        // ================================================================

        /// Private marker for type identification (DO NOT use externally)
        pub const _hal_marker = _ButtonMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// Event type
        pub const Event = SingleButtonEvent;

        /// The underlying driver instance
        driver: *Driver,

        /// Configuration
        config: ButtonConfig,

        // Internal state
        state: enum { idle, debouncing, pressed, waiting_double } = .idle,
        last_raw: bool = false,
        debounce_start_ms: u64 = 0,
        press_start_ms: u64 = 0,
        release_time_ms: u64 = 0,
        long_press_fired: bool = false,
        pending_click: bool = false,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return Self.initWithConfig(driver, .{});
        }

        /// Initialize with custom configuration
        pub fn initWithConfig(driver: *Driver, config: ButtonConfig) Self {
            return .{
                .driver = driver,
                .config = config,
            };
        }

        /// Check if button is currently pressed (after debounce)
        pub fn isPressed(self: *const Self) bool {
            return self.state == .pressed;
        }

        /// Poll button and return event if any
        /// Call this periodically (e.g., every 10-20ms)
        pub fn poll(self: *Self, now_ms: u64) ?Event {
            const raw = self.driver.isPressed();

            // State machine
            switch (self.state) {
                .idle => {
                    if (raw and !self.last_raw) {
                        // Rising edge - start debounce
                        self.state = .debouncing;
                        self.debounce_start_ms = now_ms;
                    } else if (self.pending_click) {
                        // Check double-click timeout
                        if (now_ms >= self.release_time_ms + self.config.double_click_ms) {
                            self.pending_click = false;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .click,
                                .timestamp_ms = self.release_time_ms,
                                .click_count = 1,
                            };
                        }
                    }
                },

                .debouncing => {
                    if (now_ms >= self.debounce_start_ms + self.config.debounce_ms) {
                        if (raw) {
                            // Confirmed press
                            self.state = .pressed;
                            self.press_start_ms = now_ms;
                            self.long_press_fired = false;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .press,
                                .timestamp_ms = now_ms,
                            };
                        } else {
                            // Noise, back to idle
                            self.state = .idle;
                        }
                    }
                },

                .pressed => {
                    // Check for release
                    if (!raw) {
                        const duration = @as(u32, @intCast(now_ms -| self.press_start_ms));
                        self.release_time_ms = now_ms;

                        // Check for double click
                        if (self.config.detect_double_click and self.pending_click) {
                            self.pending_click = false;
                            self.state = .idle;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .double_click,
                                .timestamp_ms = now_ms,
                                .click_count = 2,
                                .duration_ms = duration,
                            };
                        }

                        // Set pending click for double-click detection
                        if (self.config.detect_clicks and self.config.detect_double_click) {
                            self.pending_click = true;
                            self.state = .idle;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .release,
                                .timestamp_ms = now_ms,
                                .duration_ms = duration,
                            };
                        } else if (self.config.detect_clicks) {
                            // No double-click, emit click immediately
                            self.state = .idle;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .click,
                                .timestamp_ms = now_ms,
                                .click_count = 1,
                                .duration_ms = duration,
                            };
                        } else {
                            // Just release
                            self.state = .idle;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .release,
                                .timestamp_ms = now_ms,
                                .duration_ms = duration,
                            };
                        }
                    }

                    // Check for long press
                    if (!self.long_press_fired) {
                        const held_ms = now_ms -| self.press_start_ms;
                        if (held_ms >= self.config.long_press_ms) {
                            self.long_press_fired = true;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .long_press,
                                .timestamp_ms = now_ms,
                                .duration_ms = @intCast(held_ms),
                            };
                        }
                    }
                },

                .waiting_double => {
                    // Legacy state, not used in new implementation
                },
            }

            self.last_raw = raw;
            return null;
        }

        /// Reset button state
        pub fn reset(self: *Self) void {
            self.state = .idle;
            self.last_raw = false;
            self.long_press_fired = false;
            self.pending_click = false;
        }
    };
}

// ============================================================================
// Legacy Types (for backward compatibility)
// ============================================================================

/// Button adapter configuration
pub const AdapterConfig = struct {
    /// Long press threshold in milliseconds
    long_press_ms: u32 = 1000,

    /// Enable click detection (fires after release)
    detect_clicks: bool = true,

    /// Maximum consecutive clicks to track
    max_consecutive_clicks: u8 = 3,
};

/// Create a ButtonAdapter that converts raw button events to HAL events
///
/// Config must define:
///   - ButtonId: enum type for button identifiers
///
/// The adapter maps raw button indices (0, 1, 2, ...) to Config.ButtonId
/// values in enum declaration order.
pub fn ButtonAdapter(comptime Config: type) type {
    if (!@hasDecl(Config, "ButtonId")) {
        @compileError("Config must define ButtonId enum type");
    }

    const ButtonId = Config.ButtonId;
    const Event = event_mod.Event(Config);
    const ButtonEvent = event_mod.ButtonEvent(Config);
    const _ButtonAction = event_mod.ButtonAction;
    _ = _ButtonAction;

    const num_buttons = @typeInfo(ButtonId).@"enum".fields.len;

    return struct {
        const Self = @This();

        /// Per-button tracking state
        const TrackingState = struct {
            /// Previous pressed state
            was_pressed: bool = false,
            /// Whether long press was already fired
            long_press_fired: bool = false,
            /// Press start timestamp
            press_start_ms: u64 = 0,
        };

        /// Adapter configuration
        config: AdapterConfig,

        /// Per-button tracking
        tracking: [num_buttons]TrackingState = [_]TrackingState{.{}} ** num_buttons,

        /// Time source function
        time_fn: *const fn () u64,

        /// Event send function (to queue or callback)
        send_fn: *const fn (Event) void,

        /// Initialize adapter
        pub fn init(
            time_fn: *const fn () u64,
            send_fn: *const fn (Event) void,
            config: AdapterConfig,
        ) Self {
            return .{
                .config = config,
                .time_fn = time_fn,
                .send_fn = send_fn,
            };
        }

        /// Process button state change from low-level driver
        ///
        /// Call this when a button's state changes. The adapter will generate
        /// appropriate HAL events (press, release, click, long_press).
        ///
        /// Args:
        ///   - raw_id: Raw button index from driver (0, 1, 2, ...)
        ///   - state: Current button state
        pub fn onButtonChange(self: *Self, raw_id: usize, state: ButtonState) void {
            if (raw_id >= num_buttons) return;

            const id: ButtonId = @enumFromInt(raw_id);
            const now_ms = self.time_fn();
            const track = &self.tracking[raw_id];

            // Detect press edge
            if (state.is_pressed and !track.was_pressed) {
                // Button just pressed
                track.press_start_ms = now_ms;
                track.long_press_fired = false;

                self.send_fn(.{ .button = ButtonEvent.press(id, now_ms) });
            }

            // Detect release edge
            if (!state.is_pressed and track.was_pressed) {
                // Button just released
                const duration = state.press_duration_ms;

                self.send_fn(.{ .button = ButtonEvent.release(id, now_ms, duration) });

                // Generate click event if enabled
                if (self.config.detect_clicks and state.consecutive_clicks > 0) {
                    const clicks = @min(state.consecutive_clicks, self.config.max_consecutive_clicks);
                    self.send_fn(.{ .button = ButtonEvent.click(id, now_ms, clicks) });
                }

                track.long_press_fired = false;
            }

            // Detect long press (while still held)
            if (state.is_pressed and !track.long_press_fired) {
                if (state.press_duration_ms >= self.config.long_press_ms) {
                    track.long_press_fired = true;
                    self.send_fn(.{ .button = ButtonEvent.longPress(
                        id,
                        now_ms,
                        state.press_duration_ms,
                    ) });
                }
            }

            track.was_pressed = state.is_pressed;
        }

        /// Reset tracking state for a button
        pub fn resetButton(self: *Self, raw_id: usize) void {
            if (raw_id < num_buttons) {
                self.tracking[raw_id] = .{};
            }
        }

        /// Reset all tracking state
        pub fn resetAll(self: *Self) void {
            for (&self.tracking) |*t| {
                t.* = .{};
            }
        }

        /// Get ButtonId from raw index
        pub fn idFromRaw(raw_id: usize) ?ButtonId {
            if (raw_id >= num_buttons) return null;
            return @enumFromInt(raw_id);
        }

        /// Get raw index from ButtonId
        pub fn rawFromId(id: ButtonId) usize {
            return @intFromEnum(id);
        }
    };
}

// ============================================================================
// Button Group - Multiple buttons with shared event queue
// ============================================================================

/// Create a ButtonGroup that manages multiple button sources
///
/// This is a higher-level abstraction that combines ButtonAdapter
/// with polling logic for a set of buttons.
pub fn ButtonGroup(comptime Config: type) type {
    const ButtonId = Config.ButtonId;
    const num_buttons = @typeInfo(ButtonId).@"enum".fields.len;

    return struct {
        const Self = @This();

        /// Button state storage
        states: [num_buttons]ButtonState = [_]ButtonState{.{}} ** num_buttons,

        /// Adapter for event generation
        adapter: ButtonAdapter(Config),

        /// Initialize button group
        pub fn init(
            time_fn: *const fn () u64,
            send_fn: *const fn (event_mod.Event(Config)) void,
            config: AdapterConfig,
        ) Self {
            return .{
                .adapter = ButtonAdapter(Config).init(time_fn, send_fn, config),
            };
        }

        /// Update a button's state
        ///
        /// Call this when polling detects a state change
        pub fn updateState(self: *Self, id: ButtonId, state: ButtonState) void {
            const raw_id = @intFromEnum(id);
            const old_state = self.states[raw_id];

            // Only process if state changed
            if (old_state.is_pressed != state.is_pressed or
                old_state.consecutive_clicks != state.consecutive_clicks)
            {
                self.states[raw_id] = state;
                self.adapter.onButtonChange(raw_id, state);
            }
        }

        /// Get current state of a button
        pub fn getState(self: *const Self, id: ButtonId) ButtonState {
            return self.states[@intFromEnum(id)];
        }

        /// Check if any button is pressed
        pub fn isAnyPressed(self: *const Self) bool {
            for (self.states) |s| {
                if (s.is_pressed) return true;
            }
            return false;
        }

        /// Reset all button states
        pub fn reset(self: *Self) void {
            for (&self.states) |*s| {
                s.* = .{};
            }
            self.adapter.resetAll();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

// Test helper - global state for test callbacks
const TestState = struct {
    var events: [16]event_mod.ButtonAction = undefined;
    var event_count: usize = 0;
    var current_time: u64 = 0;

    fn reset() void {
        event_count = 0;
        current_time = 0;
    }

    fn getTime() u64 {
        return current_time;
    }
};

test "ButtonState struct" {
    const state = ButtonState{
        .is_pressed = true,
        .press_duration_ms = 500,
        .consecutive_clicks = 2,
    };

    try std.testing.expect(state.is_pressed);
    try std.testing.expectEqual(@as(u32, 500), state.press_duration_ms);
    try std.testing.expectEqual(@as(u8, 2), state.consecutive_clicks);
}

test "ButtonAdapter id mapping" {
    const TestConfig = struct {
        pub const ButtonId = enum(u8) { btn_a, btn_b, btn_c };
    };

    // Test raw to id conversion
    try std.testing.expectEqual(TestConfig.ButtonId.btn_a, ButtonAdapter(TestConfig).idFromRaw(0).?);
    try std.testing.expectEqual(TestConfig.ButtonId.btn_b, ButtonAdapter(TestConfig).idFromRaw(1).?);
    try std.testing.expectEqual(TestConfig.ButtonId.btn_c, ButtonAdapter(TestConfig).idFromRaw(2).?);
    try std.testing.expect(ButtonAdapter(TestConfig).idFromRaw(3) == null);

    // Test id to raw conversion
    try std.testing.expectEqual(@as(usize, 0), ButtonAdapter(TestConfig).rawFromId(.btn_a));
    try std.testing.expectEqual(@as(usize, 1), ButtonAdapter(TestConfig).rawFromId(.btn_b));
    try std.testing.expectEqual(@as(usize, 2), ButtonAdapter(TestConfig).rawFromId(.btn_c));
}

test "AdapterConfig defaults" {
    const config = AdapterConfig{};

    try std.testing.expectEqual(@as(u32, 1000), config.long_press_ms);
    try std.testing.expect(config.detect_clicks);
    try std.testing.expectEqual(@as(u8, 3), config.max_consecutive_clicks);
}

test "ButtonGroup initial state" {
    const TestConfig = struct {
        pub const ButtonId = enum(u8) { up, down };
    };

    // Simple null callback for testing
    const null_send = struct {
        fn send(_: event_mod.Event(TestConfig)) void {}
    }.send;

    var group = ButtonGroup(TestConfig).init(TestState.getTime, null_send, .{});

    // Initial state
    try std.testing.expect(!group.isAnyPressed());
    try std.testing.expect(!group.getState(.up).is_pressed);
    try std.testing.expect(!group.getState(.down).is_pressed);
}

test "ButtonGroup state update" {
    const TestConfig = struct {
        pub const ButtonId = enum(u8) { btn };
    };

    const null_send = struct {
        fn send(_: event_mod.Event(TestConfig)) void {}
    }.send;

    var group = ButtonGroup(TestConfig).init(TestState.getTime, null_send, .{});

    // Press
    group.updateState(.btn, .{ .is_pressed = true });
    try std.testing.expect(group.isAnyPressed());
    try std.testing.expect(group.getState(.btn).is_pressed);

    // Release
    group.updateState(.btn, .{ .is_pressed = false });
    try std.testing.expect(!group.isAnyPressed());
    try std.testing.expect(!group.getState(.btn).is_pressed);
}

test "ButtonGroup reset" {
    const TestConfig = struct {
        pub const ButtonId = enum(u8) { a, b };
    };

    const null_send = struct {
        fn send(_: event_mod.Event(TestConfig)) void {}
    }.send;

    var group = ButtonGroup(TestConfig).init(TestState.getTime, null_send, .{});

    // Set some state
    group.updateState(.a, .{ .is_pressed = true });
    group.updateState(.b, .{ .is_pressed = true });
    try std.testing.expect(group.isAnyPressed());

    // Reset
    group.reset();
    try std.testing.expect(!group.isAnyPressed());
    try std.testing.expect(!group.getState(.a).is_pressed);
    try std.testing.expect(!group.getState(.b).is_pressed);
}

// ============================================================================
// Button(spec) Tests
// ============================================================================

test "Button with mock driver - press and release" {
    const MockButtonDriver = struct {
        pressed: bool = false,

        pub fn isPressed(self: *@This()) bool {
            return self.pressed;
        }
    };

    const btn_spec = struct {
        pub const Driver = MockButtonDriver;
        pub const meta = spec_mod.Meta{ .id = "btn.test" };
    };

    const TestButton = Button(btn_spec);

    var driver = MockButtonDriver{};
    var btn = TestButton.initWithConfig(&driver, .{
        .debounce_ms = 10,
        .detect_double_click = false, // Simplify test
    });

    // Initial state
    try std.testing.expect(!btn.isPressed());
    try std.testing.expectEqualStrings("btn.test", TestButton.meta.id);

    // Simulate press
    driver.pressed = true;
    var event = btn.poll(0);
    try std.testing.expect(event == null); // Debouncing

    // After debounce
    event = btn.poll(15);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.press, event.?.action);
    try std.testing.expect(btn.isPressed());

    // Simulate release
    driver.pressed = false;
    event = btn.poll(100);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.click, event.?.action);
    try std.testing.expect(!btn.isPressed());
}

test "Button long press detection" {
    const MockButtonDriver = struct {
        pressed: bool = false,

        pub fn isPressed(self: *@This()) bool {
            return self.pressed;
        }
    };

    const btn_spec = struct {
        pub const Driver = MockButtonDriver;
        pub const meta = spec_mod.Meta{ .id = "btn.long" };
    };

    const TestButton = Button(btn_spec);

    var driver = MockButtonDriver{};
    var btn = TestButton.initWithConfig(&driver, .{
        .debounce_ms = 10,
        .long_press_ms = 500,
        .detect_clicks = false,
        .detect_double_click = false,
    });

    // Press
    driver.pressed = true;
    _ = btn.poll(0);
    const press_event = btn.poll(15);
    try std.testing.expect(press_event != null);
    try std.testing.expectEqual(ButtonAction.press, press_event.?.action);

    // Hold but not long enough
    var event = btn.poll(400);
    try std.testing.expect(event == null);

    // Long press threshold reached
    event = btn.poll(520);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.long_press, event.?.action);

    // No more long press events
    event = btn.poll(600);
    try std.testing.expect(event == null);
}

test "Button double click detection" {
    const MockButtonDriver = struct {
        pressed: bool = false,

        pub fn isPressed(self: *@This()) bool {
            return self.pressed;
        }
    };

    const btn_spec = struct {
        pub const Driver = MockButtonDriver;
        pub const meta = spec_mod.Meta{ .id = "btn.dbl" };
    };

    const TestButton = Button(btn_spec);

    var driver = MockButtonDriver{};
    var btn = TestButton.initWithConfig(&driver, .{
        .debounce_ms = 5,
        .double_click_ms = 200,
    });

    // First click - press
    driver.pressed = true;
    _ = btn.poll(0);
    _ = btn.poll(10);

    // First click - release
    driver.pressed = false;
    var event = btn.poll(50);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.release, event.?.action);

    // Second click - press (within double-click window)
    driver.pressed = true;
    _ = btn.poll(100);
    _ = btn.poll(110);

    // Second click - release
    driver.pressed = false;
    event = btn.poll(150);
    try std.testing.expect(event != null);
    try std.testing.expectEqual(ButtonAction.double_click, event.?.action);
    try std.testing.expectEqual(@as(u8, 2), event.?.click_count);
}
