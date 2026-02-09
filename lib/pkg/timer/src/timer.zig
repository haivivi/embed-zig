//! Timer — Delayed callback scheduling
//!
//! Provides a cross-platform timer service with comptime HW/SW selection:
//! - If a HAL timer is provided, delegates to hardware (esp_timer, timerfd, etc.)
//! - If no HAL timer, uses software fallback (Mutex + ArrayList + manual advance)
//!
//! ## Hardware Timer (ESP32, etc.)
//!
//! ```zig
//! const HwTimer = hal.timer.from(esp_timer_spec);
//! const Timer = timer.TimerService(Rt, HwTimer);
//!
//! var hw_driver = try EspTimerDriver.init();
//! var hw_timer = HwTimer.init(&hw_driver);
//! var ts = Timer.initHw(&hw_timer);
//! defer ts.deinit();
//!
//! const handle = ts.schedule(100, myCallback, &ctx);
//! ts.cancel(handle);
//! ```
//!
//! ## Software Timer (desktop/server, testing)
//!
//! ```zig
//! const Timer = timer.TimerService(Rt, null);
//!
//! var ts = Timer.init(allocator);
//! defer ts.deinit();
//!
//! _ = ts.schedule(100, myCallback, &ctx);
//!
//! // Caller drives time (e.g., 1ms loop for KCP):
//! _ = ts.advance(1);
//! ```

const std = @import("std");
const trait = @import("trait");
const hal = @import("hal");

/// Timer callback type — reuses hal.timer / spawner.TaskFn
pub const Callback = hal.TimerCallback;

/// Timer handle — re-exported from hal.timer
pub const TimerHandle = hal.TimerHandle;

/// Timer service with comptime HW/SW backend selection.
///
/// - `Rt`: Runtime type providing Mutex (for software fallback)
/// - `HwTimer`: optional HAL timer type from `hal.timer.from(spec)`.
///   Pass `null` for software-only mode.
pub fn TimerService(comptime Rt: type, comptime HwTimer: ?type) type {
    if (HwTimer) |Hw| {
        return HwTimerService(Hw);
    } else {
        return SwTimerService(Rt);
    }
}

// ============================================================================
// Hardware Timer Backend
// ============================================================================

fn HwTimerService(comptime Hw: type) type {
    return struct {
        const Self = @This();

        hw: *Hw,

        /// Initialize with a HAL timer instance.
        pub fn initHw(hw: *Hw) Self {
            return .{ .hw = hw };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Schedule a callback to fire after `delay_ms` milliseconds.
        pub fn schedule(self: *Self, delay_ms: u32, callback: Callback, ctx: ?*anyopaque) TimerHandle {
            return self.hw.schedule(delay_ms, callback, ctx);
        }

        /// Cancel a scheduled timer.
        pub fn cancel(self: *Self, handle: TimerHandle) void {
            self.hw.cancel(handle);
        }
    };
}

// ============================================================================
// Software Timer Backend
// ============================================================================

fn SwTimerService(comptime Rt: type) type {
    const Mutex = trait.sync.Mutex(Rt.Mutex);

    return struct {
        const Self = @This();

        const TimerEntry = struct {
            handle: TimerHandle,
            fire_at: u64,
            callback: Callback,
            ctx: ?*anyopaque,
            cancelled: bool,
        };

        const EntryList = std.ArrayListAligned(TimerEntry, null);

        const PendingFire = struct {
            callback: Callback,
            ctx: ?*anyopaque,
        };
        const FireList = std.ArrayListAligned(PendingFire, null);

        timers: EntryList,
        allocator: std.mem.Allocator,
        current_time: u64,
        next_id: u64,
        mutex: Mutex,

        /// Initialize software timer service.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .timers = .{},
                .allocator = allocator,
                .current_time = 0,
                .next_id = 1,
                .mutex = Mutex.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.timers.deinit(self.allocator);
            self.mutex.deinit();
        }

        /// Schedule a callback to fire after `delay_ms` milliseconds.
        pub fn schedule(self: *Self, delay_ms: u32, callback: Callback, ctx: ?*anyopaque) TimerHandle {
            self.mutex.lock();
            defer self.mutex.unlock();

            const handle = TimerHandle{ .id = self.next_id };
            self.next_id += 1;

            self.timers.append(self.allocator, .{
                .handle = handle,
                .fire_at = self.current_time + delay_ms,
                .callback = callback,
                .ctx = ctx,
                .cancelled = false,
            }) catch return TimerHandle.null_handle;

            return handle;
        }

        /// Cancel a scheduled timer.
        pub fn cancel(self: *Self, handle: TimerHandle) void {
            if (!handle.isValid()) return;

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.timers.items) |*entry| {
                if (entry.handle.id == handle.id) {
                    entry.cancelled = true;
                    return;
                }
            }
        }

        /// Get the current time in milliseconds.
        pub fn nowMs(self: *Self) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.current_time;
        }

        /// Advance time and fire any due timers.
        /// Returns the number of timers that fired.
        pub fn advance(self: *Self, delta_ms: u64) usize {
            self.mutex.lock();

            self.current_time += delta_ms;
            const now = self.current_time;

            // Collect callbacks to fire (release lock before firing)
            var to_fire: FireList = .{};
            defer to_fire.deinit(self.allocator);

            var i: usize = 0;
            while (i < self.timers.items.len) {
                const entry = &self.timers.items[i];
                if (!entry.cancelled and entry.fire_at <= now) {
                    to_fire.append(self.allocator, .{
                        .callback = entry.callback,
                        .ctx = entry.ctx,
                    }) catch {};
                    _ = self.timers.swapRemove(i);
                } else {
                    i += 1;
                }
            }

            self.mutex.unlock();

            // Fire callbacks outside of lock
            for (to_fire.items) |item| {
                item.callback(item.ctx);
            }

            return to_fire.items.len;
        }

        /// Get the number of pending (non-cancelled) timers.
        pub fn pendingCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            var count: usize = 0;
            for (self.timers.items) |entry| {
                if (!entry.cancelled) count += 1;
            }
            return count;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestRt = @import("runtime");

test "TimerHandle validity" {
    try std.testing.expect(!TimerHandle.null_handle.isValid());
    const valid = TimerHandle{ .id = 1 };
    try std.testing.expect(valid.isValid());
}

test "Software TimerService schedule and advance" {
    const Timer = TimerService(TestRt, null);
    var ts = Timer.init(std.testing.allocator);
    defer ts.deinit();

    var called: bool = false;

    _ = ts.schedule(10, struct {
        fn cb(ctx: ?*anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = true;
        }
    }.cb, &called);

    _ = ts.advance(5);
    try std.testing.expect(!called);

    const fired = ts.advance(5);
    try std.testing.expect(called);
    try std.testing.expectEqual(@as(usize, 1), fired);
}

test "Software TimerService cancel" {
    const Timer = TimerService(TestRt, null);
    var ts = Timer.init(std.testing.allocator);
    defer ts.deinit();

    var called: bool = false;

    const handle = ts.schedule(10, struct {
        fn cb(ctx: ?*anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = true;
        }
    }.cb, &called);

    ts.cancel(handle);

    _ = ts.advance(20);
    try std.testing.expect(!called);
    try std.testing.expectEqual(@as(usize, 0), ts.pendingCount());
}

test "Software TimerService multiple timers ordering" {
    const Timer = TimerService(TestRt, null);
    var ts = Timer.init(std.testing.allocator);
    defer ts.deinit();

    var order: [3]u8 = .{ 0, 0, 0 };
    var idx: u8 = 0;

    const Ctx = struct {
        order: *[3]u8,
        idx: *u8,
        value: u8,

        fn cb(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.order[self.idx.*] = self.value;
            self.idx.* += 1;
        }
    };

    var ctx_a = Ctx{ .order = &order, .idx = &idx, .value = 'A' };
    var ctx_b = Ctx{ .order = &order, .idx = &idx, .value = 'B' };
    var ctx_c = Ctx{ .order = &order, .idx = &idx, .value = 'C' };

    _ = ts.schedule(30, Ctx.cb, @ptrCast(&ctx_c));
    _ = ts.schedule(10, Ctx.cb, @ptrCast(&ctx_a));
    _ = ts.schedule(20, Ctx.cb, @ptrCast(&ctx_b));

    _ = ts.advance(10);
    try std.testing.expectEqual(@as(u8, 1), idx);

    _ = ts.advance(10);
    try std.testing.expectEqual(@as(u8, 2), idx);

    _ = ts.advance(10);
    try std.testing.expectEqual(@as(u8, 3), idx);

    try std.testing.expectEqualSlices(u8, "ABC", &order);
}

test "Hardware TimerService delegates to driver" {
    const MockDriver = struct {
        last_delay: u32 = 0,
        cancelled_id: u64 = 0,
        next_id: u64 = 1,

        pub fn schedule(self: *@This(), delay_ms: u32, _: Callback, _: ?*anyopaque) TimerHandle {
            self.last_delay = delay_ms;
            const handle = TimerHandle{ .id = self.next_id };
            self.next_id += 1;
            return handle;
        }

        pub fn cancel(self: *@This(), handle: TimerHandle) void {
            self.cancelled_id = handle.id;
        }
    };

    const TestSpec = struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "timer.mock" };
    };

    const HwTimer = hal.timer.from(TestSpec);
    const Timer = TimerService(TestRt, HwTimer);

    var driver = MockDriver{};
    var hw = HwTimer.init(&driver);
    var ts = Timer.initHw(&hw);
    defer ts.deinit();

    const handle = ts.schedule(42, struct {
        fn cb(_: ?*anyopaque) void {}
    }.cb, null);

    try std.testing.expectEqual(@as(u32, 42), driver.last_delay);
    try std.testing.expect(handle.isValid());

    ts.cancel(handle);
    try std.testing.expectEqual(handle.id, driver.cancelled_id);
}
