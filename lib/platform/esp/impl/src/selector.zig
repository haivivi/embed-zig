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
            const queue_set = c.xQueueCreateSet(max_sources);
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
        /// Returns the index of the added source.
        /// Returns error.TooMany if max_sources is reached.
        pub fn addRecv(self: *Self, channel: anytype) error{TooMany}!usize {
            if (self.source_count >= max_sources) return error.TooMany;

            const handle = channel.queueHandle();
            const logical_index = self.source_count;
            const recv_index = self.recv_count;

            self.entries[recv_index] = .{
                .handle = handle,
                .logical_index = logical_index,
            };

            // Add queue to the set
            const result = c.xQueueAddToSet(handle, self.queue_set);
            if (result != c.pdPASS) return error.QueueAddFailed;

            self.recv_count += 1;
            self.source_count += 1;
            return logical_index;
        }

        /// Add a timeout source.
        /// Note: On FreeRTOS, we handle timeout differently - pass timeout to wait().
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
        /// Returns the index of the ready source.
        /// Returns error.Empty if no sources were added.
        /// Returns max_sources if timeout occurred.
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

            // Select from the queue set
            const selected = c.xQueueSelectFromSet(self.queue_set, ticks);

            if (selected == null) {
                // Timeout or error
                if (self.timeout_enabled) return self.timeout_index;
                return max_sources;
            }

            // Find which index corresponds to this queue handle
            for (self.entries[0..self.recv_count], 0..) |entry, i| {
                if (entry.handle == selected) {
                    _ = i;
                    return entry.logical_index;
                }
            }

            // Should not reach here
            return max_sources;
        }

        /// Reset the selector, clearing all registered sources.
        pub fn reset(self: *Self) void {
            self.recv_count = 0;
            self.source_count = 0;
            self.timeout_enabled = false;
            self.timeout_ms = 0;
            self.timeout_index = max_sources;

            // Re-create the queue set
            if (self.queue_set != null) {
                c.vQueueDelete(self.queue_set);
            }
            self.queue_set = c.xQueueCreateSet(max_sources);
        }
    };
}
