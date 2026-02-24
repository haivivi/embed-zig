//! Selector — BK7258/Armino (FreeRTOS) implementation
//!
//! Multi-channel wait using FreeRTOS xQueueSet.

const std = @import("std");

const c = @cImport({
    @cInclude("FreeRTOS.h");
    @cInclude("queue.h");
});

/// Selector — wait on multiple channels with optional timeout.
pub fn Selector(comptime max_sources: usize) type {
    return struct {
        const Self = @This();

        const SourceEntry = struct {
            handle: c.QueueHandle_t,
            channel_ptr: ?*anyopaque,
        };

        entries: [max_sources]SourceEntry,
        count: usize,
        queue_set: c.QueueSetHandle_t,

        /// Initialize a new Selector
        pub fn init() !Self {
            const queue_set = c.xQueueCreateSet(max_sources);
            if (queue_set == null) return error.QueueSetCreateFailed;

            return .{
                .entries = undefined,
                .count = 0,
                .queue_set = queue_set,
            };
        }

        /// Release selector resources
        pub fn deinit(self: *Self) void {
            if (self.queue_set != null) {
                c.vQueueDelete(self.queue_set);
                self.queue_set = null;
            }
        }

        /// Add a channel to wait on.
        pub fn addRecv(self: *Self, channel: anytype) error{TooMany}!usize {
            if (self.count >= max_sources) return error.TooMany;

            const handle = channel.queueHandle();
            const idx = self.count;

            self.entries[idx] = .{
                .handle = handle,
                .channel_ptr = @ptrCast(channel),
            };

            const result = c.xQueueAddToSet(handle, self.queue_set);
            if (result != c.pdPASS) return error.QueueAddFailed;

            self.count += 1;
            return idx;
        }

        /// Add a timeout source (placeholder).
        pub fn addTimeout(self: *Self, timeout_ms: u32) error{TooMany}!usize {
            _ = self;
            _ = timeout_ms;
            return max_sources;
        }

        /// Wait for any channel to be ready or timeout.
        pub fn wait(self: *Self, timeout_ms: ?u32) error{Empty}!usize {
            if (self.count == 0) return error.Empty;

            const ticks: c.TickType_t = if (timeout_ms) |ms|
                ms / c.portTICK_PERIOD_MS
            else
                c.portMAX_DELAY;

            const selected = c.xQueueSelectFromSet(self.queue_set, ticks);

            if (selected == null) {
                return max_sources;
            }

            for (self.entries[0..self.count], 0..) |entry, i| {
                if (entry.handle == selected) {
                    return i;
                }
            }

            return max_sources;
        }

        /// Reset the selector.
        pub fn reset(self: *Self) void {
            self.count = 0;
            if (self.queue_set != null) {
                c.vQueueDelete(self.queue_set);
            }
            self.queue_set = c.xQueueCreateSet(max_sources);
        }
    };
}
