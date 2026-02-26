//! Selector — BK7258/Armino (FreeRTOS) implementation
//!
//! Multi-channel wait using FreeRTOS xQueueSet.
//!
//! ## Close Notification Support
//!
//! To support S2.3 (closed channel immediately wakes selector), each channel has
//! a close notification queue. When a channel is closed, a byte is sent to this
//! queue, causing xQueueSelectFromSet to return immediately.

const std = @import("std");

const c = @cImport({
    @cInclude("FreeRTOS.h");
    @cInclude("queue.h");
});

/// Selector — wait on multiple channels with optional timeout.
///
/// `max_sources` is the maximum number of channels that can be registered.
/// `max_events` is the total capacity of all channels plus close notification slots.
/// FreeRTOS QueueSet capacity must equal the sum of all member queue depths.
pub fn Selector(comptime max_sources: usize, comptime max_events: usize) type {
    return struct {
        const Self = @This();

        const SourceEntry = struct {
            data_handle: c.QueueHandle_t,
            close_handle: c.QueueHandle_t,
            logical_index: usize,
        };

        entries: [max_sources]SourceEntry,
        recv_count: usize,
        source_count: usize,
        queue_set: c.QueueSetHandle_t,
        timeout_enabled: bool,
        timeout_ms: u32,
        timeout_index: usize,

        /// Initialize a new Selector
        pub fn init() !Self {
            // FreeRTOS QueueSet capacity must be the sum of all member queue depths,
            // not just the number of sources. See FreeRTOS docs for xQueueCreateSet.
            const queue_set = c.xQueueCreateSet(max_events);
            if (queue_set == null) return error.QueueSetCreateFailed;

            return .{
                .entries = undefined,
                .recv_count = 0,
                .source_count = 0,
                .queue_set = queue_set,
                .timeout_enabled = false,
                .timeout_ms = 0,
                .timeout_index = max_sources,
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
        /// Returns error.TooMany if max_sources is reached.
        /// Returns error.QueueAddFailed if the queue could not be added to the set.
        pub fn addRecv(self: *Self, channel: anytype) error{ TooMany, QueueAddFailed }!usize {
            if (self.source_count >= max_sources) return error.TooMany;

            const data_handle = channel.queueHandle();
            const close_handle = channel.closeNotifyHandle();
            const logical_index = self.source_count;
            const recv_index = self.recv_count;

            self.entries[recv_index] = .{
                .data_handle = data_handle,
                .close_handle = close_handle,
                .logical_index = logical_index,
            };

            // Add both data queue and close notification queue to the set
            const result1 = c.xQueueAddToSet(data_handle, self.queue_set);
            if (result1 != c.pdPASS) return error.QueueAddFailed;

            const result2 = c.xQueueAddToSet(close_handle, self.queue_set);
            if (result2 != c.pdPASS) return error.QueueAddFailed;

            self.recv_count += 1;
            self.source_count += 1;
            return logical_index;
        }

        /// Add a timeout source.
        pub fn addTimeout(self: *Self, timeout_ms: u32) error{TooMany}!usize {
            if (self.timeout_enabled) {
                self.timeout_ms = timeout_ms;
                return self.timeout_index;
            }
            if (self.source_count >= max_sources) return error.TooMany;

            self.timeout_enabled = true;
            self.timeout_ms = timeout_ms;
            self.timeout_index = self.source_count;
            self.source_count += 1;
            return self.timeout_index;
        }

        /// Wait for any channel to be ready or timeout.
        pub fn wait(self: *Self, timeout_ms: ?u32) error{Empty}!usize {
            if (self.source_count == 0) return error.Empty;

            const effective_timeout_ms = if (timeout_ms != null)
                timeout_ms
            else if (self.timeout_enabled)
                self.timeout_ms
            else
                null;

            const ticks: c.TickType_t = if (effective_timeout_ms) |ms|
                ms / c.portTICK_PERIOD_MS
            else
                c.portMAX_DELAY;

            const selected = c.xQueueSelectFromSet(self.queue_set, ticks);

            if (selected == null) {
                if (self.timeout_enabled) return self.timeout_index;
                return max_sources;
            }

            // Check both data_handle and close_handle for each entry
            for (self.entries[0..self.recv_count], 0..) |entry, i| {
                if (entry.data_handle == selected or entry.close_handle == selected) {
                    _ = i;
                    // If it's the close notification queue, consume the notification byte
                    if (entry.close_handle == selected) {
                        var dummy: u8 = undefined;
                        _ = c.xQueueReceive(entry.close_handle, &dummy, 0);
                    }
                    return entry.logical_index;
                }
            }

            return max_sources;
        }

        /// Reset the selector.
        pub fn reset(self: *Self) void {
            self.recv_count = 0;
            self.source_count = 0;
            self.timeout_enabled = false;
            self.timeout_ms = 0;
            self.timeout_index = max_sources;
            if (self.queue_set != null) {
                c.vQueueDelete(self.queue_set);
            }
            // Re-create the queue set with correct capacity (sum of all channel depths)
            self.queue_set = c.xQueueCreateSet(max_events);
        }
    };
}
