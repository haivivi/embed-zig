//! Simulation State for raysim
//!
//! Thread-safe shared state between UI thread and app thread.
//! Uses event queue for button presses to ensure no events are lost.

const std = @import("std");
const build_options = @import("build_options");

/// Maximum number of LEDs in a strip
pub const MAX_LEDS = 16;

/// Debug log file path (compile-time option, empty = disabled)
pub const log_file_path = build_options.log_file;

/// Whether debug logging is enabled
pub const debug_log_enabled = log_file_path.len > 0;

/// Debug log file handle
var debug_file: ?std.fs.File = null;

pub fn initDebugLog() void {
    if (!debug_log_enabled) return;
    debug_file = std.fs.cwd().createFile(log_file_path, .{ .truncate = true }) catch null;
    debugLog("=== raysim debug log started ({s}) ===\n", .{log_file_path});
}

pub fn deinitDebugLog() void {
    if (!debug_log_enabled) return;
    if (debug_file) |f| {
        f.close();
        debug_file = null;
    }
}

pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_log_enabled) return;
    
    // Write to stderr
    std.debug.print(fmt, args);
    
    // Also write to file
    if (debug_file) |f| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = f.write(msg) catch {};
    }
}

/// Maximum pending button events
pub const MAX_BUTTON_EVENTS = 16;

/// Color type for LEDs
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub const black = Color{};
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const red = Color{ .r = 255 };
    pub const green = Color{ .g = 255 };
    pub const blue = Color{ .b = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

/// Button event type
pub const ButtonEvent = enum {
    press,
    release,
};

/// Shared state between app thread and UI thread
pub const SimState = struct {
    // ========== LED State ==========
    led_colors: [MAX_LEDS]Color = [_]Color{Color.black} ** MAX_LEDS,
    led_count: u32 = 1,

    // ========== Button Event Queue ==========
    // Lock-free SPSC queue: UI thread produces, app thread consumes
    button_events: [MAX_BUTTON_EVENTS]ButtonEvent = undefined,
    event_write_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    event_read_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // ========== Button State ==========
    // Two states for reliable detection:
    // - button_held: true while UI button is physically pressed
    // - button_latch: sticky flag, set on press, cleared after HAL sees pressed state
    button_held: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    button_latch: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ========== Running Flag ==========
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // ========== Log Buffer ==========
    log_lines: [32][128]u8 = undefined,
    log_lens: [32]usize = [_]usize{0} ** 32,
    log_count: usize = 0,
    log_next: usize = 0,

    // ========== Uptime ==========
    start_time: i64 = 0,

    // ================================================================
    // Button Event Queue (SPSC - Single Producer Single Consumer)
    // ================================================================

    /// Push a button event (called by UI thread)
    pub fn pushButtonEvent(self: *SimState, event: ButtonEvent) bool {
        const write_idx = self.event_write_idx.load(.acquire);
        const read_idx = self.event_read_idx.load(.acquire);
        const next_write = (write_idx + 1) % MAX_BUTTON_EVENTS;

        // Check if queue is full
        if (next_write == read_idx) {
            return false; // Queue full, drop event
        }

        self.button_events[write_idx] = event;
        self.event_write_idx.store(next_write, .release);
        return true;
    }

    /// Pop a button event (called by app thread)
    pub fn popButtonEvent(self: *SimState) ?ButtonEvent {
        const read_idx = self.event_read_idx.load(.acquire);
        const write_idx = self.event_write_idx.load(.acquire);

        // Check if queue is empty
        if (read_idx == write_idx) {
            return null;
        }

        const event = self.button_events[read_idx];
        const next_read = (read_idx + 1) % MAX_BUTTON_EVENTS;
        self.event_read_idx.store(next_read, .release);
        return event;
    }

    /// Check if there are pending events
    pub fn hasButtonEvents(self: *SimState) bool {
        const read_idx = self.event_read_idx.load(.acquire);
        const write_idx = self.event_write_idx.load(.acquire);
        return read_idx != write_idx;
    }

    // ================================================================
    // Button State (sticky latch for reliable edge detection)
    //
    // Problem: Fast UI clicks may complete between app polls
    // Solution: Two-state tracking:
    //   - button_held: actual UI state (true while mouse down)
    //   - button_latch: sticky flag (ensures HAL sees at least one true)
    //
    // isPressed returns: button_held OR button_latch
    // After returning true, latch is cleared (but held keeps it true)
    // ================================================================

    /// Called by UI when button state changes
    pub fn setButtonPressed(self: *SimState, pressed: bool) void {
        const was_held = self.button_held.swap(pressed, .acq_rel);

        if (pressed and !was_held) {
            // Rising edge: set latch to ensure HAL sees press
            self.button_latch.store(true, .release);
            _ = self.pushButtonEvent(.press);
            debugLog("[SIM] Button PRESS (latch=true)\n", .{});
        } else if (!pressed and was_held) {
            // Falling edge: push release event
            _ = self.pushButtonEvent(.release);
            debugLog("[SIM] Button RELEASE\n", .{});
        }
    }

    /// Get current button state (for UI display)
    pub fn getButtonPressed(self: *SimState) bool {
        return self.button_held.load(.acquire) or self.button_latch.load(.acquire);
    }

    /// Poll button state for HAL driver
    /// Returns true if button is held OR if press latch is set
    /// Clears the latch after returning true (but held keeps it true)
    pub fn pollButtonState(self: *SimState) bool {
        const held = self.button_held.load(.acquire);
        const latched = self.button_latch.swap(false, .acq_rel);
        const result = held or latched;
        if (latched or held) {
            debugLog("[SIM] pollButtonState: held={} latched={} -> {}\n", .{ held, latched, result });
        }
        return result;
    }

    // ================================================================
    // Running Flag
    // ================================================================

    pub fn isRunning(self: *SimState) bool {
        return self.running.load(.acquire);
    }

    pub fn stop(self: *SimState) void {
        self.running.store(false, .release);
    }

    // ================================================================
    // Log Functions
    // ================================================================

    pub fn addLog(self: *SimState, msg: []const u8) void {
        const len = @min(msg.len, 127);
        @memcpy(self.log_lines[self.log_next][0..len], msg[0..len]);
        self.log_lens[self.log_next] = len;
        self.log_next = (self.log_next + 1) % 32;
        if (self.log_count < 32) self.log_count += 1;
    }

    pub fn getLogLine(self: *const SimState, idx: usize) ?[]const u8 {
        if (idx >= self.log_count) return null;
        const actual_idx = if (self.log_count < 32)
            idx
        else
            (self.log_next + idx) % 32;
        return self.log_lines[actual_idx][0..self.log_lens[actual_idx]];
    }

    // ================================================================
    // Reset
    // ================================================================

    pub fn reset(self: *SimState) void {
        self.event_write_idx.store(0, .release);
        self.event_read_idx.store(0, .release);
        self.button_held.store(false, .release);
        self.button_latch.store(false, .release);
        self.running.store(true, .release);
        self.log_count = 0;
        self.log_next = 0;
        for (&self.led_colors) |*c| {
            c.* = Color.black;
        }
    }
};

/// Global simulation state
pub var state: SimState = .{};

// ============================================================================
// Tests
// ============================================================================

test "SimState button event queue - basic" {
    var s = SimState{};
    s.reset();

    // Initially empty
    try std.testing.expect(!s.hasButtonEvents());
    try std.testing.expect(s.popButtonEvent() == null);

    // Push and pop
    try std.testing.expect(s.pushButtonEvent(.press));
    try std.testing.expect(s.hasButtonEvents());
    try std.testing.expectEqual(ButtonEvent.press, s.popButtonEvent().?);
    try std.testing.expect(!s.hasButtonEvents());
}

test "SimState button event queue - multiple events" {
    var s = SimState{};
    s.reset();

    // Push multiple events
    try std.testing.expect(s.pushButtonEvent(.press));
    try std.testing.expect(s.pushButtonEvent(.release));
    try std.testing.expect(s.pushButtonEvent(.press));

    // Pop in order
    try std.testing.expectEqual(ButtonEvent.press, s.popButtonEvent().?);
    try std.testing.expectEqual(ButtonEvent.release, s.popButtonEvent().?);
    try std.testing.expectEqual(ButtonEvent.press, s.popButtonEvent().?);
    try std.testing.expect(s.popButtonEvent() == null);
}

test "SimState button event queue - full queue" {
    var s = SimState{};
    s.reset();

    // Fill the queue (MAX_BUTTON_EVENTS - 1 because of ring buffer)
    var i: usize = 0;
    while (i < MAX_BUTTON_EVENTS - 1) : (i += 1) {
        try std.testing.expect(s.pushButtonEvent(.press));
    }

    // Queue should be full now
    try std.testing.expect(!s.pushButtonEvent(.press));

    // Pop one and push should work again
    _ = s.popButtonEvent();
    try std.testing.expect(s.pushButtonEvent(.release));
}

test "SimState setButtonPressed generates events" {
    var s = SimState{};
    s.reset();

    // Press generates event and sets state
    s.setButtonPressed(true);
    try std.testing.expect(s.getButtonPressed());
    try std.testing.expectEqual(ButtonEvent.press, s.popButtonEvent().?);

    // Holding doesn't generate more events
    s.setButtonPressed(true);
    try std.testing.expect(s.popButtonEvent() == null);

    // Release generates event
    s.setButtonPressed(false);
    try std.testing.expectEqual(ButtonEvent.release, s.popButtonEvent().?);
}

test "SimState pollButtonState with latch" {
    var s = SimState{};
    s.reset();

    // Initially false
    try std.testing.expect(!s.pollButtonState());

    // Press sets latch
    s.setButtonPressed(true);
    try std.testing.expect(s.pollButtonState()); // Returns true (held + latch)
    try std.testing.expect(s.pollButtonState()); // Still true (held)

    // Release clears held, latch already cleared
    s.setButtonPressed(false);
    try std.testing.expect(!s.pollButtonState()); // Returns false
}

test "SimState fast click (press+release between polls)" {
    var s = SimState{};
    s.reset();

    // Fast click: press and release before any poll
    s.setButtonPressed(true);
    s.setButtonPressed(false);

    // First poll should still see true (latch preserves press)
    try std.testing.expect(s.pollButtonState()); // true (latch)

    // Second poll sees false (latch cleared, not held)
    try std.testing.expect(!s.pollButtonState()); // false
}

test "SimState LED colors" {
    var s = SimState{};
    s.reset();

    // Set colors
    s.led_colors[0] = Color.red;
    s.led_colors[1] = Color.green;
    s.led_colors[2] = Color.blue;

    try std.testing.expect(s.led_colors[0].eql(Color.red));
    try std.testing.expect(s.led_colors[1].eql(Color.green));
    try std.testing.expect(s.led_colors[2].eql(Color.blue));
}

test "SimState log buffer" {
    var s = SimState{};
    s.reset();

    s.addLog("Hello");
    s.addLog("World");

    try std.testing.expectEqual(@as(usize, 2), s.log_count);
    try std.testing.expectEqualStrings("Hello", s.getLogLine(0).?);
    try std.testing.expectEqualStrings("World", s.getLogLine(1).?);
}

test "SimState running flag" {
    var s = SimState{};
    s.reset();

    try std.testing.expect(s.isRunning());
    s.stop();
    try std.testing.expect(!s.isRunning());
}
