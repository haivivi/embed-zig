//! Channel — BK7258/Armino (FreeRTOS) implementation
//!
//! Bounded, thread-safe FIFO channel using FreeRTOS xQueue.
//! Uses C helper functions to avoid @cImport issues.

const std = @import("std");

// C helper function declarations
extern fn bk_zig_queue_create(item_count: u32, item_size: u32) ?*anyopaque;
extern fn bk_zig_queue_delete(queue: ?*anyopaque) void;
extern fn bk_zig_queue_send(queue: ?*anyopaque, item: *const anyopaque, timeout_ms: u32) i32;
extern fn bk_zig_queue_receive(queue: ?*anyopaque, item: *anyopaque, timeout_ms: u32) i32;
extern fn bk_zig_queue_messages_waiting(queue: ?*anyopaque) u32;

/// Bounded channel with Go chan semantics.
pub fn Channel(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Channel capacity must be > 0");

    return struct {
        const Self = @This();

        /// Number of slots this channel occupies in a QueueSet.
        /// This is capacity (data queue) + 1 (close notification queue).
        /// Use this to calculate Selector's max_events parameter.
        pub const queue_set_slots = capacity + 1;

        handle: ?*anyopaque,
        closed: std.atomic.Value(bool),
        /// Close notification queue for selector support.
        close_notify: ?*anyopaque,

        /// Initialize a new channel
        pub fn init() !Self {
            const handle = bk_zig_queue_create(capacity, @sizeOf(T));
            if (handle == null) return error.QueueCreateFailed;

            // Create close notification queue (capacity 1, size 1 byte)
            const close_notify = bk_zig_queue_create(1, 1);
            if (close_notify == null) {
                bk_zig_queue_delete(handle);
                return error.QueueCreateFailed;
            }

            return .{
                .handle = handle,
                .closed = std.atomic.Value(bool).init(false),
                .close_notify = close_notify,
            };
        }

        /// Release channel resources
        pub fn deinit(self: *Self) void {
            if (self.close_notify != null) {
                bk_zig_queue_delete(self.close_notify);
                self.close_notify = null;
            }
            if (self.handle != null) {
                bk_zig_queue_delete(self.handle);
                self.handle = null;
            }
        }

        /// Send item to channel (blocking).
        pub fn send(self: *Self, item: T) error{Closed}!void {
            if (self.closed.load(.acquire)) return error.Closed;

            const result = bk_zig_queue_send(self.handle, &item, 0xFFFFFFFF); // portMAX_DELAY
            if (result != 0) return error.Closed;
        }

        /// Try to send item (non-blocking).
        pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void {
            if (self.closed.load(.acquire)) return error.Closed;

            const result = bk_zig_queue_send(self.handle, &item, 0);
            if (result != 0) return error.Full;
        }

        /// Receive item from channel (blocking).
        pub fn recv(self: *Self) ?T {
            var item: T = undefined;

            while (true) {
                // Use 100ms timeout to periodically check closed status
                const result = bk_zig_queue_receive(self.handle, &item, 100);
                if (result == 0) {
                    return item;
                }

                if (self.closed.load(.acquire)) {
                    // Try once more with zero timeout to drain remaining items
                    if (bk_zig_queue_receive(self.handle, &item, 0) == 0) {
                        return item;
                    }
                    return null;
                }
            }
        }

        /// Try to receive item (non-blocking).
        pub fn tryRecv(self: *Self) ?T {
            var item: T = undefined;
            if (bk_zig_queue_receive(self.handle, &item, 0) == 0) {
                return item;
            }
            return null;
        }

        /// Close the channel.
        pub fn close(self: *Self) void {
            // Only close and notify if not already closed
            if (self.closed.load(.acquire)) return;

            self.closed.store(true, .release);

            // Send notification to wake up any selectors waiting on this channel.
            // This ensures that S2.3 (close wakes up selector) works on FreeRTOS.
            const notify_byte: u8 = 1;
            _ = bk_zig_queue_send(self.close_notify, &notify_byte, 0);
        }

        /// Check if channel is closed
        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }

        /// Get number of items currently in channel
        pub fn count(self: *Self) usize {
            return @intCast(bk_zig_queue_messages_waiting(self.handle));
        }

        /// Check if channel is empty
        pub fn isEmpty(self: *Self) bool {
            return bk_zig_queue_messages_waiting(self.handle) == 0;
        }

        /// Get the queue handle for Selector usage.
        pub fn queueHandle(self: *const Self) ?*anyopaque {
            return self.handle;
        }

        /// Get the close notification queue handle for Selector.
        /// This allows selectors to be notified when the channel is closed.
        pub fn closeNotifyHandle(self: *const Self) ?*anyopaque {
            return self.close_notify;
        }
    };
}
