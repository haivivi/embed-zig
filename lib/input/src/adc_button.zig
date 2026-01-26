//! ADC Button - Multi-button input via single ADC channel
//!
//! Provides a clean API for handling multiple buttons connected to a single ADC
//! channel through a resistor ladder. Features include:
//!   - Automatic debouncing
//!   - Press/release detection
//!   - Long press detection
//!   - Consecutive click counting (double-click, triple-click, etc.)
//!
//! ## Architecture
//!
//! ```
//! Application
//!     │
//!     ▼
//! AdcButtonSet(AdcReader, N)
//!     │  • Background polling task
//!     │  • ADC value → button mapping
//!     │  • State change detection
//!     │
//!     ▼
//! ButtonEvents[N]
//!     • Event ring buffer per button
//!     • Timestamp storage
//!     • State calculation
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const MyAdc = struct {
//!     pub fn readMv() u32 { ... }
//! };
//!
//! const Buttons = AdcButtonSet(MyAdc, 4);
//! var btns = Buttons.init(.{
//!     .ranges = .{
//!         .{ .min_mv = 2700, .max_mv = 3000 },
//!         .{ .min_mv = 2200, .max_mv = 2600 },
//!         .{ .min_mv = 1700, .max_mv = 2100 },
//!         .{ .min_mv = 1200, .max_mv = 1600 },
//!     },
//! });
//!
//! try btns.start(allocator);
//! defer btns.stop();
//!
//! // Check button state
//! const state = btns.getState(0);
//! if (state.consecutive_clicks == 2) {
//!     // Double click detected
//! }
//! ```

const std = @import("std");

const RingBuffer = @import("ring_buffer.zig").RingBuffer;

// ============================================================================
// ButtonEvents - Generic button event buffer (platform-independent)
// ============================================================================

/// Ring buffer for button press/release events.
///
/// Can be used standalone for any button type (GPIO, touch, ADC, etc.)
/// Stores timestamps for press/release events and calculates derived state
/// like consecutive clicks and press duration.
pub const ButtonEvents = struct {
    const Self = @This();
    pub const MAX_EVENTS = 8;

    /// A single button event (press + optional release)
    pub const Event = struct {
        down_ms: u64 = 0, // Timestamp when pressed
        up_ms: u64 = 0, // Timestamp when released (0 = still pressed)
    };

    /// Calculated button state
    pub const State = struct {
        /// Whether the button is currently pressed
        is_pressed: bool = false,
        /// How long the button has been/was pressed (ms)
        press_duration_ms: u32 = 0,
        /// How long since the button was released (ms), 0 if still pressed
        release_duration_ms: u32 = 0,
        /// Number of consecutive clicks within click_gap_ms
        consecutive_clicks: u8 = 0,
    };

    /// Event storage
    events: RingBuffer(Event, MAX_EVENTS) = RingBuffer(Event, MAX_EVENTS).init(),

    /// Record a button press event
    pub fn recordDown(self: *Self, now_ms: u64) void {
        // If last event has no up_ms, it's still pressed - ignore duplicate down
        if (self.events.getLast()) |evt| {
            if (evt.up_ms == 0) {
                return;
            }
        }

        // Append new event
        _ = self.events.push(.{
            .down_ms = now_ms,
            .up_ms = 0,
        });
    }

    /// Record a button release event
    pub fn recordUp(self: *Self, now_ms: u64) void {
        if (self.events.getLast()) |evt| {
            if (evt.up_ms == 0) {
                evt.up_ms = now_ms;
            }
        }
    }

    /// Calculate current button state
    pub fn calcState(self: *Self, now_ms: u64, click_gap_ms: u32) State {
        var state = State{};

        const last_evt = self.events.getLast() orelse return state;

        // Determine pressed state and durations
        if (last_evt.up_ms == 0) {
            // Still pressed
            state.is_pressed = true;
            state.press_duration_ms = @intCast(now_ms -| last_evt.down_ms);
            state.release_duration_ms = 0;
            state.consecutive_clicks = 0; // Not a click yet
        } else {
            // Released
            state.is_pressed = false;
            state.press_duration_ms = @intCast(last_evt.up_ms -| last_evt.down_ms);
            state.release_duration_ms = @intCast(now_ms -| last_evt.up_ms);
            state.consecutive_clicks = 1;
        }

        // Count consecutive clicks (only when released)
        if (!state.is_pressed) {
            const n = self.events.count();
            var prev_evt = last_evt;

            for (1..n) |i| {
                const evt = self.events.getReverse(i) orelse break;

                // Check gap between this press and previous release
                const gap = prev_evt.down_ms -| evt.up_ms;
                if (gap > click_gap_ms) break;

                state.consecutive_clicks += 1;
                prev_evt = evt;
            }
        }

        return state;
    }

    /// Clear all events
    pub fn reset(self: *Self) void {
        self.events.clear();
    }
};

// ============================================================================
// AdcButtonSet - ADC button collection with background polling
// ============================================================================

/// Create an ADC button set type for a specific ADC reader and button count.
///
/// `AdcReader` must have a `readMv() u32` function that returns the current
/// ADC value in millivolts.
pub fn AdcButtonSet(
    comptime AdcReader: type,
    comptime num_buttons: comptime_int,
) type {
    // Verify AdcReader has required function
    if (!@hasDecl(AdcReader, "readMv")) {
        @compileError("AdcReader must have a readMv() u32 function");
    }

    return struct {
        const Self = @This();

        // -------------------------- Configuration --------------------------

        /// Voltage range for a button
        pub const Range = struct {
            min_mv: u16,
            max_mv: u16,
        };

        /// Button change callback type
        pub const OnChangeFn = *const fn (button_id: i8, state: ButtonEvents.State, ctx: ?*anyopaque) void;

        /// Sleep function type
        pub const SleepMsFn = *const fn (ms: u32) void;

        /// Configuration options
        pub const Config = struct {
            /// Voltage ranges for each button
            ranges: [num_buttons]Range,

            /// Reference (idle) voltage when no button is pressed
            ref_value_mv: u32 = 3300,

            /// Tolerance for detecting reference state (±mv)
            ref_tolerance_mv: u32 = 200,

            /// Tolerance for detecting value changes (±mv)
            change_tolerance_mv: u32 = 50,

            /// ADC polling interval in milliseconds
            poll_interval_ms: u32 = 10,

            /// Maximum gap between clicks to count as consecutive (ms)
            click_gap_ms: u32 = 300,

            /// Callback when button state changes (optional)
            on_change: ?OnChangeFn = null,

            /// User context passed to callback
            user_ctx: ?*anyopaque = null,

            /// Task stack size (for ESP32)
            task_stack_size: u32 = 4096,

            /// Sleep function (platform-dependent)
            sleep_ms: ?SleepMsFn = null,
        };

        // -------------------------- State --------------------------

        config: Config,

        /// Event history for each button
        buttons: [num_buttons]ButtonEvents = [_]ButtonEvents{ButtonEvents{}} ** num_buttons,

        /// Currently pressed button (-1 = none)
        current_button: i8 = -1,

        /// ADC monitor state
        is_at_ref: bool = true,
        start_value_mv: u32 = 0,
        last_value_mv: u32 = 0,
        state_start_ms: u64 = 0,

        /// Time source (injected for testing)
        time_fn: *const fn () u64,

        /// Task control
        running: bool = false,

        // -------------------------- Lifecycle --------------------------

        /// Initialize with configuration
        pub fn init(config: Config, time_fn: *const fn () u64) Self {
            return Self{
                .config = config,
                .time_fn = time_fn,
                .start_value_mv = config.ref_value_mv,
                .last_value_mv = config.ref_value_mv,
            };
        }

        /// Start background polling (blocking - run in a task)
        /// Requires sleep_ms to be configured
        pub fn run(self: *Self) void {
            const sleep_ms = self.config.sleep_ms orelse return;
            self.running = true;

            while (self.running) {
                self.poll();
                sleep_ms(self.config.poll_interval_ms);
            }
        }

        /// Stop the polling loop
        pub fn stop(self: *Self) void {
            self.running = false;
        }

        // -------------------------- Query --------------------------

        /// Get the state of a specific button
        pub fn getState(self: *Self, button_id: u8) ButtonEvents.State {
            if (button_id >= num_buttons) {
                return ButtonEvents.State{};
            }
            const now_ms = self.time_fn();
            return self.buttons[button_id].calcState(now_ms, self.config.click_gap_ms);
        }

        /// Get the currently pressed button (-1 if none)
        pub fn getCurrentButton(self: *const Self) i8 {
            return self.current_button;
        }

        /// Check if any button is currently pressed
        pub fn isAnyPressed(self: *const Self) bool {
            return self.current_button >= 0;
        }

        // -------------------------- Polling --------------------------

        /// Single poll iteration - call this periodically from your main loop
        pub fn poll(self: *Self) void {
            const now_ms = self.time_fn();
            const adc_mv = AdcReader.readMv();

            const cur_is_ref = self.isRefValue(adc_mv);
            const crossed_ref = (cur_is_ref != self.is_at_ref);

            if (crossed_ref) {
                // State transition
                var stable_mv = adc_mv;

                if (!cur_is_ref) {
                    // ref → non-ref: button pressed
                    // Read multiple times and take minimum for stability
                    stable_mv = self.readStable(adc_mv);
                }

                // Determine which button (if any)
                const new_button = self.findButton(stable_mv);

                // Handle button change
                self.handleButtonChange(new_button, now_ms);

                // Update state
                self.is_at_ref = cur_is_ref;
                self.start_value_mv = stable_mv;
                self.last_value_mv = stable_mv;
                self.state_start_ms = now_ms;
            }
        }

        /// Read ADC multiple times and return minimum (for debouncing)
        fn readStable(self: *Self, first_value: u32) u32 {
            var min_value = first_value;

            // If sleep is available, do debounce sampling
            if (self.config.sleep_ms) |sleep_ms| {
                for (0..2) |_| {
                    sleep_ms(5);
                    const sample = AdcReader.readMv();
                    if (sample < min_value) {
                        min_value = sample;
                    }
                }
            }

            return min_value;
        }

        /// Check if value is at reference (idle) state
        fn isRefValue(self: *const Self, mv: u32) bool {
            const ref = self.config.ref_value_mv;
            const tol = self.config.ref_tolerance_mv;
            return mv >= ref -| tol and mv <= ref +| tol;
        }

        /// Find button index by ADC value (-1 if not found)
        fn findButton(self: *const Self, mv: u32) i8 {
            for (self.config.ranges, 0..) |range, i| {
                if (mv >= range.min_mv and mv <= range.max_mv) {
                    return @intCast(i);
                }
            }
            return -1;
        }

        /// Handle button state change
        fn handleButtonChange(self: *Self, new_button: i8, now_ms: u64) void {
            const prev_button = self.current_button;

            // Release previous button
            if (prev_button >= 0 and prev_button < num_buttons) {
                const idx: usize = @intCast(prev_button);
                self.buttons[idx].recordUp(now_ms);

                // Notify release
                if (self.config.on_change) |cb| {
                    const state = self.buttons[idx].calcState(now_ms, self.config.click_gap_ms);
                    cb(prev_button, state, self.config.user_ctx);
                }
            }

            // Press new button
            if (new_button >= 0 and new_button < num_buttons) {
                const idx: usize = @intCast(new_button);
                self.buttons[idx].recordDown(now_ms);

                // Notify press
                if (self.config.on_change) |cb| {
                    const state = self.buttons[idx].calcState(now_ms, self.config.click_gap_ms);
                    cb(new_button, state, self.config.user_ctx);
                }
            }

            self.current_button = new_button;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ButtonEvents: basic press/release" {
    var evts = ButtonEvents{};

    evts.recordDown(100);
    var state = evts.calcState(150, 300);
    try std.testing.expect(state.is_pressed);
    try std.testing.expectEqual(@as(u32, 50), state.press_duration_ms);

    evts.recordUp(200);
    state = evts.calcState(250, 300);
    try std.testing.expect(!state.is_pressed);
    try std.testing.expectEqual(@as(u32, 100), state.press_duration_ms);
    try std.testing.expectEqual(@as(u32, 50), state.release_duration_ms);
    try std.testing.expectEqual(@as(u8, 1), state.consecutive_clicks);
}

test "ButtonEvents: consecutive clicks" {
    var evts = ButtonEvents{};

    // First click
    evts.recordDown(100);
    evts.recordUp(150);

    // Second click (within 300ms gap)
    evts.recordDown(300);
    evts.recordUp(350);

    // Third click
    evts.recordDown(500);
    evts.recordUp(550);

    const state = evts.calcState(600, 300);
    try std.testing.expectEqual(@as(u8, 3), state.consecutive_clicks);
}

test "ButtonEvents: click gap breaks consecutive" {
    var evts = ButtonEvents{};

    // First click
    evts.recordDown(100);
    evts.recordUp(150);

    // Second click (gap > 300ms)
    evts.recordDown(500);
    evts.recordUp(550);

    const state = evts.calcState(600, 300);
    try std.testing.expectEqual(@as(u8, 1), state.consecutive_clicks);
}

test "ButtonEvents: ring buffer overflow" {
    var evts = ButtonEvents{};

    // Fill more than MAX_EVENTS
    for (0..ButtonEvents.MAX_EVENTS + 2) |i| {
        const base: u64 = @intCast(i * 100);
        evts.recordDown(base);
        evts.recordUp(base + 50);
    }

    // Should still work, old events discarded
    try std.testing.expectEqual(ButtonEvents.MAX_EVENTS, evts.events.count());

    const state = evts.calcState(2000, 300);
    try std.testing.expect(!state.is_pressed);
}

// ============================================================================
// ButtonEvents Tests
// ============================================================================

test "ButtonEvents: long press detection" {
    var evts = ButtonEvents{};

    // Press and hold
    evts.recordDown(100);

    // After 500ms still pressed
    var state = evts.calcState(600, 300);
    try std.testing.expect(state.is_pressed);
    try std.testing.expectEqual(@as(u32, 500), state.press_duration_ms);
    try std.testing.expectEqual(@as(u8, 0), state.consecutive_clicks); // Not a click yet

    // After 1000ms still pressed
    state = evts.calcState(1100, 300);
    try std.testing.expect(state.is_pressed);
    try std.testing.expectEqual(@as(u32, 1000), state.press_duration_ms);

    // Release after 1500ms (long press)
    evts.recordUp(1600);
    state = evts.calcState(1700, 300);
    try std.testing.expect(!state.is_pressed);
    try std.testing.expectEqual(@as(u32, 1500), state.press_duration_ms);
    try std.testing.expectEqual(@as(u8, 1), state.consecutive_clicks);
}

test "ButtonEvents: duplicate down ignored" {
    var evts = ButtonEvents{};

    // First press
    evts.recordDown(100);
    try std.testing.expectEqual(@as(usize, 1), evts.events.count());

    // Duplicate down should be ignored (still pressed)
    evts.recordDown(150);
    try std.testing.expectEqual(@as(usize, 1), evts.events.count());

    // Release
    evts.recordUp(200);

    // Another down is valid now
    evts.recordDown(300);
    try std.testing.expectEqual(@as(usize, 2), evts.events.count());
}

test "ButtonEvents: orphan up ignored" {
    var evts = ButtonEvents{};

    // Up without down should do nothing
    evts.recordUp(100);
    try std.testing.expectEqual(@as(usize, 0), evts.events.count());

    // Press and release normally
    evts.recordDown(200);
    evts.recordUp(250);
    try std.testing.expectEqual(@as(usize, 1), evts.events.count());

    // Another up after release should be ignored
    evts.recordUp(300);
    const evt = evts.events.getLast().?;
    try std.testing.expectEqual(@as(u64, 250), evt.up_ms); // Still 250, not 300
}

test "ButtonEvents: rapid clicks" {
    var evts = ButtonEvents{};

    // Simulate very rapid clicking (5 clicks in 500ms)
    var t: u64 = 0;
    for (0..5) |_| {
        evts.recordDown(t);
        evts.recordUp(t + 30); // 30ms press
        t += 100; // 70ms gap between clicks
    }

    const state = evts.calcState(t, 300);
    try std.testing.expectEqual(@as(u8, 5), state.consecutive_clicks);
}

test "ButtonEvents: reset clears all events" {
    var evts = ButtonEvents{};

    evts.recordDown(100);
    evts.recordUp(150);
    evts.recordDown(200);
    evts.recordUp(250);

    try std.testing.expectEqual(@as(usize, 2), evts.events.count());

    evts.reset();
    try std.testing.expectEqual(@as(usize, 0), evts.events.count());

    const state = evts.calcState(300, 300);
    try std.testing.expect(!state.is_pressed);
    try std.testing.expectEqual(@as(u8, 0), state.consecutive_clicks);
}

test "ButtonEvents: consecutive clicks with varying press duration" {
    var evts = ButtonEvents{};

    // Click 1: short press
    evts.recordDown(0);
    evts.recordUp(50);

    // Click 2: longer press
    evts.recordDown(200);
    evts.recordUp(400);

    // Click 3: very short press
    evts.recordDown(550);
    evts.recordUp(570);

    const state = evts.calcState(600, 300);
    try std.testing.expectEqual(@as(u8, 3), state.consecutive_clicks);
    try std.testing.expectEqual(@as(u32, 20), state.press_duration_ms); // Last press duration
}

// ============================================================================
// AdcButtonSet Tests - Test Helpers
// ============================================================================

fn createMockTimeSource() type {
    return struct {
        var t: u64 = 0;
        pub fn now() u64 {
            return t;
        }
        pub fn set(ms: u64) void {
            t = ms;
        }
        pub fn advance(ms: u64) void {
            t += ms;
        }
    };
}

fn createMockAdc() type {
    return struct {
        var value: u32 = 3300;
        pub fn readMv() u32 {
            return value;
        }
        pub fn set(mv: u32) void {
            value = mv;
        }
    };
}

// ============================================================================
// AdcButtonSet Tests
// ============================================================================

test "AdcButtonSet: button detection" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 }, // Button 0
            .{ .min_mv = 2200, .max_mv = 2600 }, // Button 1
            .{ .min_mv = 1700, .max_mv = 2100 }, // Button 2
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
    }, Time.now);

    // Initially no button pressed
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());

    // Press button 1
    MockAdc.set(2400);
    Time.set(100);
    btns.poll();

    try std.testing.expectEqual(@as(i8, 1), btns.getCurrentButton());

    // Release
    MockAdc.set(3300);
    Time.set(200);
    btns.poll();

    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());

    // Check state
    const state = btns.getState(1);
    try std.testing.expect(!state.is_pressed);
    try std.testing.expectEqual(@as(u8, 1), state.consecutive_clicks);
}

test "AdcButtonSet: long press" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 },
            .{ .min_mv = 2200, .max_mv = 2600 },
            .{ .min_mv = 1700, .max_mv = 2100 },
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
    }, Time.now);

    // Press button 0
    MockAdc.set(2850);
    Time.set(0);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Keep holding - poll multiple times
    Time.advance(100);
    btns.poll();
    Time.advance(100);
    btns.poll();
    Time.advance(100);
    btns.poll();

    // Still pressed after 300ms
    var state = btns.getState(0);
    try std.testing.expect(state.is_pressed);
    try std.testing.expectEqual(@as(u32, 300), state.press_duration_ms);

    // Hold for 1 second total
    Time.set(1000);
    btns.poll();
    state = btns.getState(0);
    try std.testing.expect(state.is_pressed);
    try std.testing.expectEqual(@as(u32, 1000), state.press_duration_ms);

    // Release
    MockAdc.set(3300);
    Time.advance(100);
    btns.poll();

    state = btns.getState(0);
    try std.testing.expect(!state.is_pressed);
    try std.testing.expectEqual(@as(u32, 1100), state.press_duration_ms);
}

test "AdcButtonSet: double click" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 },
            .{ .min_mv = 2200, .max_mv = 2600 },
            .{ .min_mv = 1700, .max_mv = 2100 },
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
        .click_gap_ms = 300,
    }, Time.now);

    // First click
    MockAdc.set(2400); // Button 1
    Time.set(0);
    btns.poll();

    MockAdc.set(3300);
    Time.set(50);
    btns.poll();

    // Second click within gap
    MockAdc.set(2400);
    Time.set(200);
    btns.poll();

    MockAdc.set(3300);
    Time.set(250);
    btns.poll();

    const state = btns.getState(1);
    try std.testing.expectEqual(@as(u8, 2), state.consecutive_clicks);
}

test "AdcButtonSet: first button locks until full release" {
    // This tests the "single decoder" logic:
    // - First pressed button is locked
    // - Voltage changes (pressing another button) don't change the detected button
    // - Only returning to ref voltage releases the button
    //
    // Scenario: User presses button 0, then also presses button 1 (combo),
    // then releases button 0 (only button 1 held). The detected button
    // should remain button 0 until all buttons are released.

    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 }, // Button 0: ~2850mV
            .{ .min_mv = 2200, .max_mv = 2600 }, // Button 1: ~2400mV
            .{ .min_mv = 1700, .max_mv = 2100 }, // Button 2: ~1900mV
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200, // ref range: 3100-3500mV
    }, Time.now);

    // Step 1: Press button 0 (voltage = 2850mV)
    MockAdc.set(2850);
    Time.set(0);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Step 2: Press button 1 while holding button 0 (combo press)
    // Voltage drops to ~1500mV (parallel resistance effect)
    // This is BELOW all button ranges but NOT at ref
    MockAdc.set(1500);
    Time.set(50);
    btns.poll();
    // Button should STILL be 0 (locked at first press)
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Step 3: Release button 0, only button 1 held
    // Voltage rises to button 1 range (~2400mV)
    MockAdc.set(2400);
    Time.set(100);
    btns.poll();
    // Button should STILL be 0 (not crossed ref boundary)
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Step 4: Release all buttons (return to ref)
    MockAdc.set(3300);
    Time.set(150);
    btns.poll();
    // Now button should be released
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());

    // Button 0 should have recorded 1 complete click
    const state0 = btns.getState(0);
    try std.testing.expect(!state0.is_pressed);
    try std.testing.expectEqual(@as(u8, 1), state0.consecutive_clicks);
    try std.testing.expectEqual(@as(u32, 150), state0.press_duration_ms);
}

test "AdcButtonSet: release and press different button" {
    // Different from above: user releases first, then presses another
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 }, // Button 0
            .{ .min_mv = 2200, .max_mv = 2600 }, // Button 1
            .{ .min_mv = 1700, .max_mv = 2100 }, // Button 2
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
    }, Time.now);

    // Press button 0
    MockAdc.set(2850);
    Time.set(0);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Release (return to ref)
    MockAdc.set(3300);
    Time.set(100);
    btns.poll();
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());

    // Press button 2 (different button)
    MockAdc.set(1900);
    Time.set(150);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 2), btns.getCurrentButton());

    // Button 0 should have 1 click
    const state0 = btns.getState(0);
    try std.testing.expectEqual(@as(u8, 1), state0.consecutive_clicks);

    // Button 2 currently pressed
    const state2 = btns.getState(2);
    try std.testing.expect(state2.is_pressed);
}

test "AdcButtonSet: voltage fluctuation during hold" {
    // Test that voltage fluctuation during button hold doesn't affect detection
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 }, // Button 0
            .{ .min_mv = 2200, .max_mv = 2600 }, // Button 1
            .{ .min_mv = 1700, .max_mv = 2100 }, // Button 2
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
    }, Time.now);

    // Press button 0
    MockAdc.set(2850);
    Time.set(0);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Voltage fluctuates but stays in non-ref range
    MockAdc.set(2900);
    Time.advance(10);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    MockAdc.set(2800);
    Time.advance(10);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Voltage enters button 1 range (simulating finger slip)
    MockAdc.set(2400);
    Time.advance(10);
    btns.poll();
    // Should STILL be button 0 (locked)
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Back to button 0 range
    MockAdc.set(2850);
    Time.advance(10);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Release
    MockAdc.set(3300);
    Time.advance(10);
    btns.poll();
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());

    // Only 1 click recorded for button 0
    try std.testing.expectEqual(@as(u8, 1), btns.getState(0).consecutive_clicks);
    // Button 1 should have NO events (voltage passed through but not recorded)
    try std.testing.expectEqual(@as(u8, 0), btns.getState(1).consecutive_clicks);
}

test "AdcButtonSet: voltage in no-button zone" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 }, // Button 0
            .{ .min_mv = 2200, .max_mv = 2600 }, // Button 1
            .{ .min_mv = 1700, .max_mv = 2100 }, // Button 2
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
    }, Time.now);

    // Voltage between button 0 and button 1 (2600-2700 gap)
    MockAdc.set(2650);
    Time.set(0);
    btns.poll();

    // No button should be detected (voltage is in gap)
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());
}

test "AdcButtonSet: rapid button switching" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 },
            .{ .min_mv = 2200, .max_mv = 2600 },
            .{ .min_mv = 1700, .max_mv = 2100 },
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
        .click_gap_ms = 300,
    }, Time.now);

    // Rapidly press different buttons
    // Button 0 click
    MockAdc.set(2850);
    Time.set(0);
    btns.poll();
    MockAdc.set(3300);
    Time.set(50);
    btns.poll();

    // Button 1 click
    MockAdc.set(2400);
    Time.set(100);
    btns.poll();
    MockAdc.set(3300);
    Time.set(150);
    btns.poll();

    // Button 2 click
    MockAdc.set(1900);
    Time.set(200);
    btns.poll();
    MockAdc.set(3300);
    Time.set(250);
    btns.poll();

    // Each button should have exactly 1 click
    try std.testing.expectEqual(@as(u8, 1), btns.getState(0).consecutive_clicks);
    try std.testing.expectEqual(@as(u8, 1), btns.getState(1).consecutive_clicks);
    try std.testing.expectEqual(@as(u8, 1), btns.getState(2).consecutive_clicks);
}

test "AdcButtonSet: callback invocation" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const CallbackTracker = struct {
        var press_count: u32 = 0;
        var release_count: u32 = 0;
        var last_button: i8 = -99;
        var last_pressed: bool = false;

        fn callback(button_id: i8, state: ButtonEvents.State, ctx: ?*anyopaque) void {
            _ = ctx;
            last_button = button_id;
            last_pressed = state.is_pressed;
            if (state.is_pressed) {
                press_count += 1;
            } else {
                release_count += 1;
            }
        }

        fn reset() void {
            press_count = 0;
            release_count = 0;
            last_button = -99;
            last_pressed = false;
        }
    };

    CallbackTracker.reset();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 },
            .{ .min_mv = 2200, .max_mv = 2600 },
            .{ .min_mv = 1700, .max_mv = 2100 },
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
        .on_change = CallbackTracker.callback,
    }, Time.now);

    // Press button 1
    MockAdc.set(2400);
    Time.set(0);
    btns.poll();

    try std.testing.expectEqual(@as(u32, 1), CallbackTracker.press_count);
    try std.testing.expectEqual(@as(u32, 0), CallbackTracker.release_count);
    try std.testing.expectEqual(@as(i8, 1), CallbackTracker.last_button);
    try std.testing.expect(CallbackTracker.last_pressed);

    // Release
    MockAdc.set(3300);
    Time.set(100);
    btns.poll();

    try std.testing.expectEqual(@as(u32, 1), CallbackTracker.press_count);
    try std.testing.expectEqual(@as(u32, 1), CallbackTracker.release_count);
    try std.testing.expectEqual(@as(i8, 1), CallbackTracker.last_button);
    try std.testing.expect(!CallbackTracker.last_pressed);
}

test "AdcButtonSet: polling with no state change" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 },
            .{ .min_mv = 2200, .max_mv = 2600 },
            .{ .min_mv = 1700, .max_mv = 2100 },
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
    }, Time.now);

    // Poll multiple times at ref - no button pressed
    MockAdc.set(3300);
    for (0..10) |i| {
        Time.set(i * 10);
        btns.poll();
        try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());
    }

    // Press and hold, poll multiple times
    MockAdc.set(2400);
    Time.set(100);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 1), btns.getCurrentButton());

    // Continue polling while held - button should stay pressed
    for (0..10) |i| {
        Time.set(100 + (i + 1) * 10);
        btns.poll();
        try std.testing.expectEqual(@as(i8, 1), btns.getCurrentButton());
    }
}

test "AdcButtonSet: consecutive clicks on same button" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 },
            .{ .min_mv = 2200, .max_mv = 2600 },
            .{ .min_mv = 1700, .max_mv = 2100 },
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
        .click_gap_ms = 300,
    }, Time.now);

    // Triple click on button 1
    for (0..3) |i| {
        const base: u64 = @intCast(i * 150);
        MockAdc.set(2400);
        Time.set(base);
        btns.poll();

        MockAdc.set(3300);
        Time.set(base + 50);
        btns.poll();
    }

    const state = btns.getState(1);
    try std.testing.expectEqual(@as(u8, 3), state.consecutive_clicks);
}

test "AdcButtonSet: click gap timeout" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 3);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 2700, .max_mv = 3000 },
            .{ .min_mv = 2200, .max_mv = 2600 },
            .{ .min_mv = 1700, .max_mv = 2100 },
        },
        .ref_value_mv = 3300,
        .ref_tolerance_mv = 200,
        .click_gap_ms = 300,
    }, Time.now);

    // First click
    MockAdc.set(2400);
    Time.set(0);
    btns.poll();
    MockAdc.set(3300);
    Time.set(50);
    btns.poll();

    // Wait too long (500ms > 300ms gap)
    // Second click
    MockAdc.set(2400);
    Time.set(550);
    btns.poll();
    MockAdc.set(3300);
    Time.set(600);
    btns.poll();

    // Should only count as 1 click (gap broken)
    const state = btns.getState(1);
    try std.testing.expectEqual(@as(u8, 1), state.consecutive_clicks);
}

// ============================================================================
// ESP-ADF style contiguous voltage range tests
// ============================================================================

test "AdcButtonSet: ESP-ADF contiguous ranges - exact boundaries" {
    // ESP-ADF uses contiguous ranges: btn_array = {190, 600, 1000, 1375, 1775, 2195, 3000}
    // Logic: adc > step[i] && adc <= step[i+1] -> button i
    // Converted to mV (raw * 3100 / 4095):
    //   VOL+ (i=0): raw 191-600  -> mV 145-454
    //   VOL- (i=1): raw 601-1000 -> mV 455-757
    //   SET  (i=2): raw 1001-1375 -> mV 758-1041
    //   PLAY (i=3): raw 1376-1775 -> mV 1042-1344
    //   MODE (i=4): raw 1776-2195 -> mV 1345-1662
    //   REC  (i=5): raw 2196-3000 -> mV 1663-2272
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 6);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 145, .max_mv = 454 }, // VOL+ (0)
            .{ .min_mv = 455, .max_mv = 757 }, // VOL- (1)
            .{ .min_mv = 758, .max_mv = 1041 }, // SET (2)
            .{ .min_mv = 1042, .max_mv = 1344 }, // PLAY (3)
            .{ .min_mv = 1345, .max_mv = 1662 }, // MODE (4)
            .{ .min_mv = 1663, .max_mv = 2272 }, // REC (5)
        },
        .ref_value_mv = 3100,
        .ref_tolerance_mv = 500,
    }, Time.now);

    // Test exact boundary values
    const test_cases = [_]struct { mv: u32, expected: i8, name: []const u8 }{
        // Below VOL+ range - no button
        .{ .mv = 100, .expected = -1, .name = "below VOL+" },
        .{ .mv = 144, .expected = -1, .name = "just below VOL+" },
        // VOL+ range
        .{ .mv = 145, .expected = 0, .name = "VOL+ min" },
        .{ .mv = 300, .expected = 0, .name = "VOL+ mid" },
        .{ .mv = 454, .expected = 0, .name = "VOL+ max" },
        // Boundary VOL+/VOL-
        .{ .mv = 455, .expected = 1, .name = "VOL- min (boundary)" },
        // VOL- range
        .{ .mv = 600, .expected = 1, .name = "VOL- mid" },
        .{ .mv = 757, .expected = 1, .name = "VOL- max" },
        // Boundary VOL-/SET
        .{ .mv = 758, .expected = 2, .name = "SET min (boundary)" },
        // SET range
        .{ .mv = 900, .expected = 2, .name = "SET mid" },
        .{ .mv = 1041, .expected = 2, .name = "SET max" },
        // Boundary SET/PLAY
        .{ .mv = 1042, .expected = 3, .name = "PLAY min (boundary)" },
        // PLAY range
        .{ .mv = 1200, .expected = 3, .name = "PLAY mid" },
        .{ .mv = 1344, .expected = 3, .name = "PLAY max" },
        // Boundary PLAY/MODE
        .{ .mv = 1345, .expected = 4, .name = "MODE min (boundary)" },
        // MODE range
        .{ .mv = 1500, .expected = 4, .name = "MODE mid" },
        .{ .mv = 1662, .expected = 4, .name = "MODE max" },
        // Boundary MODE/REC
        .{ .mv = 1663, .expected = 5, .name = "REC min (boundary)" },
        // REC range
        .{ .mv = 2000, .expected = 5, .name = "REC mid" },
        .{ .mv = 2272, .expected = 5, .name = "REC max" },
        // Above REC - no button (gap before ref)
        .{ .mv = 2273, .expected = -1, .name = "above REC" },
        .{ .mv = 2500, .expected = -1, .name = "in gap" },
        // Ref range (no button)
        .{ .mv = 2600, .expected = -1, .name = "ref low" },
        .{ .mv = 3100, .expected = -1, .name = "ref center" },
        .{ .mv = 3600, .expected = -1, .name = "ref high" },
    };

    for (test_cases) |tc| {
        // Reset to ref first
        MockAdc.set(3100);
        Time.advance(100);
        btns.poll();

        // Set test voltage and poll
        MockAdc.set(tc.mv);
        Time.advance(100);
        btns.poll();

        const actual = btns.getCurrentButton();
        if (actual != tc.expected) {
            std.debug.print("FAIL: {s} - mv={d}, expected button {d}, got {d}\n", .{ tc.name, tc.mv, tc.expected, actual });
        }
        try std.testing.expectEqual(tc.expected, actual);
    }
}

test "AdcButtonSet: ESP-ADF contiguous ranges - button press sequence" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 6);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 145, .max_mv = 454 }, // VOL+
            .{ .min_mv = 455, .max_mv = 757 }, // VOL-
            .{ .min_mv = 758, .max_mv = 1041 }, // SET
            .{ .min_mv = 1042, .max_mv = 1344 }, // PLAY
            .{ .min_mv = 1345, .max_mv = 1662 }, // MODE
            .{ .min_mv = 1663, .max_mv = 2272 }, // REC
        },
        .ref_value_mv = 3100,
        .ref_tolerance_mv = 500,
        .click_gap_ms = 300,
    }, Time.now);

    // Press VOL+ (typical value ~300mV)
    MockAdc.set(300);
    Time.set(0);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 0), btns.getCurrentButton());

    // Release
    MockAdc.set(3100);
    Time.set(100);
    btns.poll();
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());
    try std.testing.expectEqual(@as(u8, 1), btns.getState(0).consecutive_clicks);

    // Press VOL- (typical value ~600mV)
    MockAdc.set(600);
    Time.set(500);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 1), btns.getCurrentButton());

    // Release
    MockAdc.set(3100);
    Time.set(600);
    btns.poll();
    try std.testing.expectEqual(@as(u8, 1), btns.getState(1).consecutive_clicks);

    // Press SET (typical value ~900mV)
    MockAdc.set(900);
    Time.set(1000);
    btns.poll();
    try std.testing.expectEqual(@as(i8, 2), btns.getCurrentButton());

    // Release
    MockAdc.set(3100);
    Time.set(1100);
    btns.poll();
    try std.testing.expectEqual(@as(u8, 1), btns.getState(2).consecutive_clicks);
}

test "AdcButtonSet: ESP-ADF ranges - voltage just outside range" {
    const Time = createMockTimeSource();
    const MockAdc = createMockAdc();

    const Buttons = AdcButtonSet(MockAdc, 6);
    var btns = Buttons.init(.{
        .ranges = .{
            .{ .min_mv = 145, .max_mv = 454 },
            .{ .min_mv = 455, .max_mv = 757 },
            .{ .min_mv = 758, .max_mv = 1041 },
            .{ .min_mv = 1042, .max_mv = 1344 },
            .{ .min_mv = 1345, .max_mv = 1662 },
            .{ .min_mv = 1663, .max_mv = 2272 },
        },
        .ref_value_mv = 3100,
        .ref_tolerance_mv = 500,
    }, Time.now);

    // Test voltages just outside each range don't trigger wrong button
    // 144mV should NOT trigger VOL+ (min is 145)
    MockAdc.set(144);
    Time.set(0);
    btns.poll();
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());

    // Reset
    MockAdc.set(3100);
    Time.advance(100);
    btns.poll();

    // 2273mV should NOT trigger REC (max is 2272)
    MockAdc.set(2273);
    Time.advance(100);
    btns.poll();
    try std.testing.expectEqual(@as(i8, -1), btns.getCurrentButton());
}
