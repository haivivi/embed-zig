//! Selector — ESP32/FreeRTOS implementation
//!
//! Multi-channel wait using FreeRTOS xQueueSet.
//! Allows waiting on multiple channels simultaneously.

const std = @import("std");
const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/queue.h");
});

/// Selector — wait on multiple channels with optional timeout.
///
/// `max_sources` is the maximum number of channels that can be registered.
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
        /// Returns the index of the added source.
        /// Returns error.TooMany if max_sources is reached.
        pub fn addRecv(self: *Self, channel: anytype) error{TooMany}!usize {
            if (self.count >= max_sources) return error.TooMany;

            const handle = channel.queueHandle();
            const idx = self.count;

            self.entries[idx] = .{
                .handle = handle,
                .channel_ptr = @ptrCast(channel),
            };

            // Add queue to the set
            const result = c.xQueueAddToSet(handle, self.queue_set);
            if (result != c.pdPASS) return error.QueueAddFailed;

            self.count += 1;
            return idx;
        }

        /// Add a timeout source.
        /// Note: On FreeRTOS, we handle timeout differently - pass timeout to wait().
        pub fn addTimeout(self: *Self, timeout_ms: u32) error{TooMany}!usize {
            _ = self;
            _ = timeout_ms;
            // Timeout is handled in wait(), not as a separate queue
            return max_sources; // Special timeout index
        }

        /// Wait for any channel to be ready or timeout.
        /// Returns the index of the ready source.
        /// Returns error.Empty if no sources were added.
        /// Returns max_sources if timeout occurred.
        pub fn wait(self: *Self, timeout_ms: ?u32) error{Empty}!usize {
            if (self.count == 0) return error.Empty;

            const ticks: c.TickType_t = if (timeout_ms) |ms|
                ms / c.portTICK_PERIOD_MS
            else
                c.portMAX_DELAY;

            // Select from the queue set
            const selected = c.xQueueSelectFromSet(self.queue_set, ticks);

            if (selected == null) {
                // Timeout or error
                return max_sources;
            }

            // Find which index corresponds to this queue handle
            for (self.entries[0..self.count], 0..) |entry, i| {
                if (entry.handle == selected) {
                    return i;
                }
            }

            // Should not reach here
            return max_sources;
        }

        /// Reset the selector, clearing all registered sources.
        pub fn reset(self: *Self) void {
            self.count = 0;

            // Re-create the queue set
            if (self.queue_set != null) {
                c.vQueueDelete(self.queue_set);
            }
            self.queue_set = c.xQueueCreateSet(max_sources);
        }
    };
}
