//! Channel — BK7258/Armino (FreeRTOS) implementation
//!
//! Bounded, thread-safe FIFO channel using FreeRTOS xQueue.

const std = @import("std");

// Import FreeRTOS types from C
const c = @cImport({
    @cInclude("FreeRTOS.h");
    @cInclude("queue.h");
});

/// Bounded channel with Go chan semantics.
pub fn Channel(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Channel capacity must be > 0");

    return struct {
        const Self = @This();

        handle: c.QueueHandle_t,
        closed: std.atomic.Value(bool),

        /// Initialize a new channel
        pub fn init() Self {
            const handle = c.xQueueCreate(capacity, @sizeOf(T));
            return .{
                .handle = handle,
                .closed = std.atomic.Value(bool).init(false),
            };
        }

        /// Release channel resources
        pub fn deinit(self: *Self) void {
            if (self.handle != null) {
                c.vQueueDelete(self.handle);
                self.handle = null;
            }
        }

        /// Send item to channel (blocking).
        pub fn send(self: *Self, item: T) error{Closed}!void {
            if (self.closed.load(.acquire)) return error.Closed;

            const result = c.xQueueSend(self.handle, &item, c.portMAX_DELAY);
            if (result != c.pdTRUE) return error.Closed;
        }

        /// Try to send item (non-blocking).
        pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void {
            if (self.closed.load(.acquire)) return error.Closed;

            const result = c.xQueueSend(self.handle, &item, 0);
            if (result != c.pdTRUE) return error.Full;
        }

        /// Receive item from channel (blocking).
        pub fn recv(self: *Self) ?T {
            var item: T = undefined;

            while (true) {
                const result = c.xQueueReceive(self.handle, &item, c.portMAX_DELAY);
                if (result == c.pdTRUE) {
                    return item;
                }

                if (self.closed.load(.acquire)) {
                    if (c.xQueueReceive(self.handle, &item, 0) == c.pdTRUE) {
                        return item;
                    }
                    return null;
                }
            }
        }

        /// Try to receive item (non-blocking).
        pub fn tryRecv(self: *Self) ?T {
            var item: T = undefined;
            if (c.xQueueReceive(self.handle, &item, 0) == c.pdTRUE) {
                return item;
            }
            return null;
        }

        /// Close the channel.
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }

        /// Check if channel is closed
        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }

        /// Get number of items currently in channel
        pub fn count(self: *Self) usize {
            return @intCast(c.uxQueueMessagesWaiting(self.handle));
        }

        /// Check if channel is empty
        pub fn isEmpty(self: *Self) bool {
            return c.uxQueueMessagesWaiting(self.handle) == 0;
        }

        /// Get the FreeRTOS queue handle for Selector usage.
        pub fn queueHandle(self: *const Self) c.QueueHandle_t {
            return self.handle;
        }
    };
}
