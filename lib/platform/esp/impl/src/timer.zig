//! ESP Timer Driver — hal.timer implementation using esp_timer
//!
//! Wraps ESP-IDF's esp_timer (high-level timer, task-context callbacks)
//! to satisfy the hal.timer Driver contract. Manages a fixed-size pool
//! of timer slots.
//!
//! ## Usage
//!
//! ```zig
//! const impl = @import("impl");
//! const hal = @import("hal");
//!
//! const timer_spec = struct {
//!     pub const Driver = impl.EspTimerDriver;
//!     pub const meta = .{ .id = "timer.esp" };
//! };
//! const HwTimer = hal.timer.from(timer_spec);
//! ```

const std = @import("std");
const idf = @import("idf");
const hal = @import("hal");

const esp_timer = idf.esp_timer;
const Callback = hal.timer.Callback;
const TimerHandle = hal.timer.TimerHandle;

/// Maximum concurrent timers
const MAX_TIMERS = 16;

/// ESP Timer Driver implementing hal.timer.Driver contract
pub const EspTimerDriver = struct {
    const Self = @This();

    const Slot = struct {
        esp_handle: ?esp_timer.Handle = null,
        id: u64 = 0,
        callback: ?Callback = null,
        ctx: ?*anyopaque = null,
        active: bool = false,
    };

    slots: [MAX_TIMERS]Slot,
    next_id: u64,

    pub fn init() Self {
        return .{
            .slots = [_]Slot{.{}} ** MAX_TIMERS,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up all active timers
        for (&self.slots) |*slot| {
            if (slot.active) {
                if (slot.esp_handle) |h| {
                    esp_timer.stop(h);
                    esp_timer.delete(h);
                }
                slot.active = false;
            }
        }
    }

    /// Schedule a callback to fire after `delay_ms` milliseconds.
    pub fn schedule(self: *Self, delay_ms: u32, callback: Callback, ctx: ?*anyopaque) TimerHandle {
        // Find free slot
        const slot_idx = self.findFreeSlot() orelse {
            std.log.err("EspTimerDriver: no free timer slots", .{});
            return TimerHandle.null_handle;
        };
        const slot = &self.slots[slot_idx];

        // Set up slot before creating timer (bridge callback reads slot)
        slot.id = self.next_id;
        self.next_id += 1;
        slot.callback = callback;
        slot.ctx = ctx;
        slot.active = true;

        // Create esp_timer with bridge callback
        const esp_handle = esp_timer.createOneshot(espTimerBridge, @ptrCast(slot)) catch {
            std.log.err("EspTimerDriver: failed to create esp_timer", .{});
            slot.active = false;
            return TimerHandle.null_handle;
        };
        slot.esp_handle = esp_handle;

        // Start one-shot (delay in microseconds)
        esp_timer.startOnce(esp_handle, @as(u64, delay_ms) * 1000) catch {
            std.log.err("EspTimerDriver: failed to start esp_timer", .{});
            esp_timer.delete(esp_handle);
            slot.active = false;
            return TimerHandle.null_handle;
        };

        return .{ .id = slot.id };
    }

    /// Cancel a scheduled timer.
    pub fn cancel(self: *Self, handle: TimerHandle) void {
        if (!handle.isValid()) return;

        for (&self.slots) |*slot| {
            if (slot.active and slot.id == handle.id) {
                if (slot.esp_handle) |h| {
                    esp_timer.stop(h);
                    esp_timer.delete(h);
                }
                slot.esp_handle = null;
                slot.active = false;
                return;
            }
        }
    }

    /// Bridge callback: called by esp_timer in task context, invokes Zig callback.
    fn espTimerBridge(arg: ?*anyopaque) callconv(.c) void {
        const slot: *Slot = @ptrCast(@alignCast(arg orelse return));
        if (!slot.active) return;

        const cb = slot.callback orelse return;
        const ctx = slot.ctx;

        // Clean up esp_timer (one-shot, already expired)
        if (slot.esp_handle) |h| {
            esp_timer.delete(h);
        }
        slot.esp_handle = null;
        slot.active = false;

        // Fire user callback
        cb(ctx);
    }

    fn findFreeSlot(self: *Self) ?usize {
        for (&self.slots, 0..) |*slot, i| {
            if (!slot.active) return i;
        }
        return null;
    }
};

/// Timer spec for convenience (use with hal.timer.from)
pub const timer_spec = struct {
    pub const Driver = EspTimerDriver;
    pub const meta = .{ .id = "timer.esp" };
};
