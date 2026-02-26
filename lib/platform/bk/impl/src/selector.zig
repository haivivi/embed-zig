//! Selector — BK7258/Armino (FreeRTOS) implementation
//!
//! Multi-channel wait using FreeRTOS xQueueSet.
//!
//! ## Close Notification Support
//!
//! To support S2.3 (closed channel immediately wakes selector), each channel has
//! a close notification queue. When a channel is closed, a byte is sent to this
//! queue, causing xQueueSelectFromSet to return immediately.

// C helper function declarations
extern fn bk_zig_queue_set_create(event_count: u32) ?*anyopaque;
extern fn bk_zig_queue_set_delete(queue_set: ?*anyopaque) void;
extern fn bk_zig_queue_add_to_set(queue: ?*anyopaque, queue_set: ?*anyopaque) i32;
extern fn bk_zig_queue_remove_from_set(queue: ?*anyopaque, queue_set: ?*anyopaque) i32;
extern fn bk_zig_queue_select_from_set(queue_set: ?*anyopaque, timeout_ms: u32) ?*anyopaque;
extern fn bk_zig_queue_receive(queue: ?*anyopaque, item: *anyopaque, timeout_ms: u32) i32;

/// Selector — wait on multiple channels with optional timeout.
///
/// `max_sources` is the maximum number of channels that can be registered.
/// `max_events` is the total capacity of all channels plus close notification slots.
/// FreeRTOS QueueSet capacity must equal the sum of all member queue depths.
pub fn Selector(comptime max_sources: usize, comptime max_events: usize) type {
    return struct {
        const Self = @This();

        const SourceEntry = struct {
            data_handle: ?*anyopaque,
            close_handle: ?*anyopaque,
            logical_index: usize,
        };

        entries: [max_sources]SourceEntry,
        recv_count: usize,
        source_count: usize,
        /// Tracks total slots required by registered channels in the QueueSet.
        /// This is the sum of all channels' queue_set_slots for capacity validation.
        required_slots: usize,
        queue_set: ?*anyopaque,
        timeout_enabled: bool,
        timeout_ms: u32,
        timeout_index: usize,

        /// Initialize a new Selector
        pub fn init() !Self {
            // FreeRTOS QueueSet capacity must be the sum of all member queue depths,
            // not just the number of sources. See FreeRTOS docs for xQueueCreateSet.
            const queue_set = bk_zig_queue_set_create(@intCast(max_events));
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
                bk_zig_queue_set_delete(self.queue_set);
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

            const data_handle = channel.queueHandle();
            const close_handle = channel.closeNotifyHandle();
            if (data_handle == null or close_handle == null) return error.QueueAddFailed;
            if (self.queue_set == null) return error.QueueAddFailed;
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

            // Add both data queue and close notification queue to the set
            // IMPORTANT: Must add both successfully before updating entries,
            // or rollback on partial failure to avoid "poisoning" the selector.
            const result1 = bk_zig_queue_add_to_set(data_handle, self.queue_set);
            if (result1 != 0) return error.QueueAddFailed;

            const result2 = bk_zig_queue_add_to_set(close_handle, self.queue_set);
            if (result2 != 0) {
                // Rollback: remove data_handle from set to avoid leaving partial state
                const rollback_result = bk_zig_queue_remove_from_set(data_handle, self.queue_set);
                if (rollback_result != 0) {
                    // Critical: rollback failed, selector may be in inconsistent state
                    return error.RollbackFailed;
                }
                return error.QueueAddFailed;
            }

            // Only update state after both adds succeed
            self.entries[recv_index] = .{
                .data_handle = data_handle,
                .close_handle = close_handle,
                .logical_index = logical_index,
            };

            self.recv_count += 1;
            self.source_count += 1;
            self.required_slots += channel_slots;
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
        /// Returns error.Empty if no sources were added.
        /// Returns error.PollWaitFailed if the underlying poll mechanism failed (not timeout).
        pub fn wait(self: *Self, timeout_ms: ?u32) error{ Empty, PollWaitFailed }!usize {
            if (self.source_count == 0) return error.Empty;
            if (self.queue_set == null) return error.PollWaitFailed;

            const effective_timeout_ms = if (timeout_ms != null)
                timeout_ms
            else if (self.timeout_enabled)
                self.timeout_ms
            else
                null;

            const wait_timeout_ms: u32 = if (effective_timeout_ms) |ms|
                ms
            else
                0xFFFFFFFF;

            const selected = bk_zig_queue_select_from_set(self.queue_set, wait_timeout_ms);

            if (selected == null) {
                // Check if this is timeout or error
                // FreeRTOS doesn't distinguish between timeout and error for null return
                // We treat it as timeout if timeout is configured, otherwise as potential error
                if (self.timeout_enabled) return self.timeout_index;
                // No timeout configured but xQueueSelectFromSet returned null - could be error
                // Unfortunately FreeRTOS doesn't provide error codes here
                return max_sources;
            }

            // Check both data_handle and close_handle for each entry
            for (self.entries[0..self.recv_count], 0..) |entry, i| {
                if (entry.data_handle == selected or entry.close_handle == selected) {
                    _ = i;
                    // If it's the close notification queue, consume the notification byte
                    if (entry.close_handle == selected) {
                        var dummy: u8 = undefined;
                        _ = bk_zig_queue_receive(entry.close_handle, &dummy, 0);
                    }
                    return entry.logical_index;
                }
            }

            // Should not reach here - selector returned unknown queue handle
            return error.PollWaitFailed;
        }

        /// Reset the selector.
        pub fn reset(self: *Self) void {
            self.recv_count = 0;
            self.source_count = 0;
            self.required_slots = 0;
            self.timeout_enabled = false;
            self.timeout_ms = 0;
            self.timeout_index = max_sources;
            if (self.queue_set != null) {
                bk_zig_queue_set_delete(self.queue_set);
            }
            self.queue_set = bk_zig_queue_set_create(@intCast(max_events));
        }
    };
}
