//! Timer — Delayed callback scheduling
//!
//! Provides a cross-platform timer service for scheduling callbacks
//! to fire after a specified delay. Used by KCP Mux for periodic
//! update scheduling (1ms interval).
//!
//! ## Architecture
//!
//! The caller drives time by calling `advance(delta_ms)` in a loop.
//! This is intentional — no background thread, no OS timer dependency.
//! The caller controls the tick rate (e.g., 1ms for KCP).
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("std_impl").runtime;
//! const Timer = timer.TimerService(Rt);
//!
//! var ts = Timer.init(allocator);
//! defer ts.deinit();
//!
//! const handle = ts.schedule(100, myCallback, &ctx);
//! // ... later, cancel if needed:
//! ts.cancel(handle);
//!
//! // Drive time forward (e.g., in a 1ms loop):
//! _ = ts.advance(1);
//! ```

const std = @import("std");
const trait = @import("trait");

/// Callback type — reuses spawner.TaskFn: `*const fn (?*anyopaque) void`
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

/// Timer service — delayed callback scheduling with manual time advancement.
///
/// Generic over `Rt` for cross-platform Mutex support (ESP32 / std).
/// Only requires `Rt.Mutex` (no Condition or Spawner needed).
pub fn TimerService(comptime Rt: type) type {
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

test "TimerService schedule and advance" {
    const Timer = TimerService(TestRt);
    var ts = Timer.init(std.testing.allocator);
    defer ts.deinit();

    var called: bool = false;

    _ = ts.schedule(10, struct {
        fn cb(ctx: ?*anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = true;
        }
    }.cb, &called);

    // Not yet
    _ = ts.advance(5);
    try std.testing.expect(!called);

    // Now fires
    const fired = ts.advance(5);
    try std.testing.expect(called);
    try std.testing.expectEqual(@as(usize, 1), fired);
}

test "TimerService cancel" {
    const Timer = TimerService(TestRt);
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

test "TimerService multiple timers" {
    const Timer = TimerService(TestRt);
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
