//! Channel — ESP32/FreeRTOS implementation
//!
//! Bounded, thread-safe FIFO channel using FreeRTOS xQueue.
//! For select support, uses xQueueSet (native FreeRTOS mechanism).

const std = @import("std");
const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/queue.h");
});

/// Bounded channel with Go chan semantics.
///
/// - `T`: element type
/// - `capacity`: buffer capacity (must be > 0)
pub fn Channel(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Channel capacity must be > 0");

    return struct {
        const Self = @This();

        handle: c.QueueHandle_t,
        closed: std.atomic.Value(bool),

        /// Initialize a new channel
        pub fn init() !Self {
            const handle = c.xQueueCreate(capacity, @sizeOf(T));
            if (handle == null) return error.QueueCreateFailed;
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

        // ================================================================
        // Send Operations (Producer)
        // ================================================================

        /// Send item to channel (blocking).
        /// Blocks until space is available or channel is closed.
        /// Returns error.Closed if channel was closed.
        pub fn send(self: *Self, item: T) error{Closed}!void {
            if (self.closed.load(.acquire)) return error.Closed;

            const result = c.xQueueSend(self.handle, &item, c.portMAX_DELAY);
            if (result != c.pdTRUE) return error.Closed;
        }

        /// Try to send item (non-blocking).
        /// Returns error.Closed if closed, error.Full if buffer is full.
        pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void {
            if (self.closed.load(.acquire)) return error.Closed;

            const result = c.xQueueSend(self.handle, &item, 0);
            if (result != c.pdTRUE) return error.Full;
        }

        // ================================================================
        // Receive Operations (Consumer)
        // ================================================================

        /// Receive item from channel (blocking).
        /// Blocks until an item is available.
        /// Returns null when channel is closed AND drained (no more items).
        pub fn recv(self: *Self) ?T {
            var item: T = undefined;

            while (true) {
                // Use 100ms timeout to periodically check closed status
                // This allows us to wake up and check if channel was closed
                const result = c.xQueueReceive(self.handle, &item, 100 / c.portTICK_PERIOD_MS);
                if (result == c.pdTRUE) {
                    return item;
                }

                // Check if closed - if so, try to drain remaining items
                if (self.closed.load(.acquire)) {
                    // Try once more with zero timeout to drain remaining items
                    if (c.xQueueReceive(self.handle, &item, 0) == c.pdTRUE) {
                        return item;
                    }
                    return null;
                }
                // Otherwise, loop and wait again (channel not closed, just empty)
            }
        }

        /// Try to receive item (non-blocking).
        /// Returns null if no items available.
        pub fn tryRecv(self: *Self) ?T {
            var item: T = undefined;
            if (c.xQueueReceive(self.handle, &item, 0) == c.pdTRUE) {
                return item;
            }
            return null;
        }

        // ================================================================
        // Channel Control
        // ================================================================

        /// Close the channel. No more sends allowed.
        /// Pending recv() calls will drain remaining items, then return null.
        /// Idempotent — safe to call multiple times.
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }

        /// Check if channel is closed
        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.acquire);
        }

        // ================================================================
        // Status Operations
        // ================================================================

        /// Get number of items currently in channel
        pub fn count(self: *Self) usize {
            return @intCast(c.uxQueueMessagesWaiting(self.handle));
        }

        /// Check if channel is empty
        pub fn isEmpty(self: *Self) bool {
            return c.uxQueueMessagesWaiting(self.handle) == 0;
        }

        // ================================================================
        // Selector Support
        // ================================================================

        /// Get the FreeRTOS queue handle for xQueueSet usage.
        /// This allows the channel to be used with Selector.
        pub fn queueHandle(self: *const Self) c.QueueHandle_t {
            return self.handle;
        }

        /// Check if this queue has items available (for Selector).
        /// Returns true if messages are waiting.
        pub fn hasMessages(self: *const Self) bool {
            return c.uxQueueMessagesWaiting(self.handle) > 0;
        }
    };
}
