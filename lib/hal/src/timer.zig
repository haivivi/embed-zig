//! HAL Timer — Hardware Timer Abstraction
//!
//! Provides a platform-independent interface for hardware timers:
//! ESP32 esp_timer/GPTimer, Linux timerfd, macOS kqueue EVFILT_TIMER, etc.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ lib/pkg/timer  (TimerService)           │
//! │   - Optionally delegates to HW timer    │
//! │   - Or uses software fallback           │
//! ├─────────────────────────────────────────┤
//! │ hal.timer.from(spec)  ← HAL wrapper     │
//! │   - schedule(delay, callback, ctx)      │
//! │   - cancel(handle)                      │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← platform impl   │
//! │   - esp_timer, timerfd, etc.            │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const timer_spec = struct {
//!     pub const Driver = EspTimerDriver;
//!     pub const meta = .{ .id = "timer.hw" };
//! };
//!
//! const HwTimer = hal.timer.from(timer_spec);
//! var hw_timer = HwTimer.init(&driver);
//!
//! const handle = hw_timer.schedule(100, myCallback, &ctx);
//! hw_timer.cancel(handle);
//! ```

const trait = @import("trait");

/// Timer callback type — reuses spawner.TaskFn: `*const fn (?*anyopaque) void`
pub const Callback = trait.spawner.TaskFn;

/// Handle to a scheduled timer, used for cancellation.
pub const TimerHandle = struct {
    id: u64,

    /// A null handle representing no timer.
    pub const null_handle: TimerHandle = .{ .id = 0 };

    /// Check if this is a valid (non-null) handle.
    pub fn isValid(self: TimerHandle) bool {
        return self.id != 0;
    }
};

// ============================================================================
// Type Marker (for hal.Board identification)
// ============================================================================

const _TimerMarker = struct {};

/// Check if a type is a Timer HAL component (for hal.Board)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _TimerMarker;
}

// ============================================================================
// Timer HAL Component
// ============================================================================

/// Create Timer HAL component from spec
///
/// spec must define:
/// - `Driver`: struct with schedule, cancel methods
/// - `meta`: with component id
///
/// Driver required methods:
/// - `fn schedule(self: *Driver, delay_ms: u32, callback: Callback, ctx: ?*anyopaque) TimerHandle`
/// - `fn cancel(self: *Driver, handle: TimerHandle) void`
pub fn from(comptime spec: type) type {
    comptime {
        if (!@hasDecl(spec.Driver, "schedule")) @compileError("Timer Driver missing schedule() function");
        if (!@hasDecl(spec.Driver, "cancel")) @compileError("Timer Driver missing cancel() function");
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        /// Type marker for hal.Board identification
        pub const _hal_marker = _TimerMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        /// Component metadata
        pub const meta = spec.meta;

        /// The underlying driver instance
        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        /// Schedule a callback to fire after `delay_ms` milliseconds.
        pub fn schedule(self: *Self, delay_ms: u32, callback: Callback, ctx: ?*anyopaque) TimerHandle {
            return self.driver.schedule(delay_ms, callback, ctx);
        }

        /// Cancel a scheduled timer.
        pub fn cancel(self: *Self, handle: TimerHandle) void {
            self.driver.cancel(handle);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "TimerHandle validity" {
    try std.testing.expect(!TimerHandle.null_handle.isValid());
    const valid = TimerHandle{ .id = 1 };
    try std.testing.expect(valid.isValid());
}

test "Timer HAL basic usage" {
    const MockDriver = struct {
        last_delay: u32 = 0,
        last_ctx: ?*anyopaque = null,
        cancelled: bool = false,
        next_id: u64 = 1,

        pub fn schedule(self: *@This(), delay_ms: u32, _: Callback, ctx: ?*anyopaque) TimerHandle {
            self.last_delay = delay_ms;
            self.last_ctx = ctx;
            const handle = TimerHandle{ .id = self.next_id };
            self.next_id += 1;
            return handle;
        }

        pub fn cancel(self: *@This(), _: TimerHandle) void {
            self.cancelled = true;
        }
    };

    const TestSpec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "timer.test" };
    };

    const Timer = from(TestSpec);
    var driver = MockDriver{};
    var hw_timer = Timer.init(&driver);

    var dummy: u32 = 42;
    const handle = hw_timer.schedule(100, struct {
        fn cb(_: ?*anyopaque) void {}
    }.cb, &dummy);

    try std.testing.expect(handle.isValid());
    try std.testing.expectEqual(@as(u32, 100), driver.last_delay);

    hw_timer.cancel(handle);
    try std.testing.expect(driver.cancelled);
}
