//! Selector — ESP32/FreeRTOS implementation
//!
//! Multi-channel wait using FreeRTOS xQueueSet.
//! Allows waiting on multiple channels simultaneously.
//!
//! ## Close Notification Support
//!
//! To support S2.3 (closed channel immediately wakes selector), each channel has
//! a close notification queue. When a channel is closed, a byte is sent to this
//! queue, causing xQueueSelectFromSet to return immediately.

const std = @import("std");
const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/queue.h");
    @cInclude("freertos/task.h");
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
            /// Whether data_handle has been successfully added to queue_set.
            data_in_set: bool,
            /// Whether close_handle has been successfully added to queue_set.
            close_in_set: bool,
            logical_index: usize,
        };

        entries: [max_sources]SourceEntry,
        recv_count: usize,
        source_count: usize,
        /// Tracks total slots required by registered channels in the QueueSet.
        /// This is the sum of all channels' queue_set_slots for capacity validation.
        required_slots: usize,
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
                .required_slots = 0,
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
        /// Returns error.QueueSetCapacityExceeded if adding this channel would exceed max_events.
        /// Returns error.QueueAddFailed if the queue could not be added to the set.
        /// Returns error.RollbackFailed if rollback after partial failure failed (critical state).
        pub fn addRecv(self: *Self, channel: anytype) error{ TooMany, QueueSetCapacityExceeded, QueueAddFailed, RollbackFailed }!usize {
            if (self.source_count >= max_sources) return error.TooMany;
            if (self.queue_set == null) return error.QueueAddFailed;

            const data_handle: c.QueueHandle_t = @ptrCast(channel.queueHandle());
            const close_handle: c.QueueHandle_t = @ptrCast(channel.closeNotifyHandle());
            if (data_handle == null or close_handle == null) return error.QueueAddFailed;
            const logical_index = self.source_count;
            const recv_index = self.recv_count;

            // Capacity validation: check if this channel would exceed max_events
            const ChannelType = switch (@typeInfo(@TypeOf(channel))) {
                .pointer => |ptr| ptr.child,
                else => @TypeOf(channel),
            };
            const channel_slots = @field(ChannelType, "queue_set_slots");
            if (self.required_slots + channel_slots > max_events) {
                return error.QueueSetCapacityExceeded;
            }

            // FreeRTOS queue-set limitation: non-empty queue cannot be added to set.
            // Strategy: if a handle is non-empty at registration time, defer adding it.
            // wait() will surface it as immediately ready, then attach once drained.
            var data_in_set = false;
            const result1 = c.xQueueAddToSet(data_handle, self.queue_set);
            if (result1 == c.pdPASS) {
                data_in_set = true;
            } else if (c.uxQueueMessagesWaiting(data_handle) == 0) {
                return error.QueueAddFailed;
            }

            var close_in_set = false;
            const result2 = c.xQueueAddToSet(close_handle, self.queue_set);
            if (result2 == c.pdPASS) {
                close_in_set = true;
            } else if (c.uxQueueMessagesWaiting(close_handle) == 0) {
                // Unexpected close-handle add failure when queue is empty.
                // Rollback data handle if it was already added.
                if (data_in_set) {
                    const rollback_result = c.xQueueRemoveFromSet(data_handle, self.queue_set);
                    if (rollback_result != c.pdPASS) {
                        return error.RollbackFailed;
                    }
                }
                return error.QueueAddFailed;
            }

            // Only update state after both adds succeed
            self.entries[recv_index] = .{
                .data_handle = data_handle,
                .close_handle = close_handle,
                .data_in_set = data_in_set,
                .close_in_set = close_in_set,
                .logical_index = logical_index,
            };

            self.recv_count += 1;
            self.source_count += 1;
            self.required_slots += channel_slots;
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
        /// Returns error.PollWaitFailed if the underlying poll mechanism failed (not timeout).
        pub fn wait(self: *Self, timeout_ms: ?u32) error{ Empty, PollWaitFailed }!usize {
            if (self.source_count == 0) return error.Empty;
            if (self.queue_set == null) return error.PollWaitFailed;

            // Handle deferred sources first:
            // - if deferred handle currently non-empty, it is immediately ready
            // - if deferred handle is drained, try to attach to queue_set
            for (self.entries[0..self.recv_count]) |*entry| {
                if (!entry.data_in_set) {
                    if (c.uxQueueMessagesWaiting(entry.data_handle) > 0) {
                        return entry.logical_index;
                    }
                    if (c.xQueueAddToSet(entry.data_handle, self.queue_set) != c.pdPASS) {
                        return error.PollWaitFailed;
                    }
                    entry.data_in_set = true;
                }

                if (!entry.close_in_set) {
                    if (c.uxQueueMessagesWaiting(entry.close_handle) > 0) {
                        var close_dummy: u8 = undefined;
                        _ = c.xQueueReceive(entry.close_handle, &close_dummy, 0);
                        return entry.logical_index;
                    }
                    if (c.xQueueAddToSet(entry.close_handle, self.queue_set) != c.pdPASS) {
                        return error.PollWaitFailed;
                    }
                    entry.close_in_set = true;
                }
            }

            const effective_timeout_ms = if (timeout_ms != null)
                timeout_ms
            else if (self.timeout_enabled)
                self.timeout_ms
            else
                null;

            const timeout_ticks: ?c.TickType_t = if (effective_timeout_ms) |ms|
                @intCast(ms / c.portTICK_PERIOD_MS)
            else
                null;

            const ticks: c.TickType_t = if (timeout_ticks) |t|
                t
            else
                c.portMAX_DELAY;

            var timeout_state: c.TimeOut_t = undefined;
            var ticks_remaining: c.TickType_t = ticks;
            if (effective_timeout_ms != null) {
                c.vTaskSetTimeOutState(&timeout_state);
            }

            // Select from the queue set
            const selected = c.xQueueSelectFromSet(self.queue_set, ticks);

            if (selected == null) {
                // For infinite wait, null is unexpected and treated as failure.
                if (effective_timeout_ms == null) return error.PollWaitFailed;

                // For finite timeout, use FreeRTOS timeout state API to distinguish
                // timeout vs unexpected failure without elapsed-time heuristics.
                if (c.xTaskCheckForTimeOut(&timeout_state, &ticks_remaining) != c.pdTRUE) {
                    return error.PollWaitFailed;
                }

                // Timeout path with explicit duration.
                if (self.timeout_enabled) return self.timeout_index;
                return max_sources;
            }

            // Find which index corresponds to this queue handle
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

            // Should not reach here - selector returned unknown queue handle
            return error.PollWaitFailed;
        }

        /// Reset the selector, clearing all registered sources.
        pub fn reset(self: *Self) void {
            // Re-create queue set first. If allocation fails, keep current state
            // to avoid transitioning into an unusable null-handle state.
            const new_queue_set = c.xQueueCreateSet(max_events);
            if (new_queue_set == null) return;

            if (self.queue_set != null) {
                c.vQueueDelete(self.queue_set);
            }
            self.queue_set = new_queue_set;

            self.recv_count = 0;
            self.source_count = 0;
            self.required_slots = 0;
            self.timeout_enabled = false;
            self.timeout_ms = 0;
            self.timeout_index = max_sources;
        }
    };
}
