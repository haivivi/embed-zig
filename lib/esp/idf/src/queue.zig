//! FreeRTOS Queue Wrapper
//!
//! Thread-safe bounded FIFO queue using FreeRTOS xQueue.
//! Supports ISR context operations.

const std = @import("std");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/queue.h");
});

/// Create a thread-safe bounded queue type using FreeRTOS xQueue
pub fn Queue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) {
        @compileError("Queue capacity must be greater than 0");
    }

    return struct {
        const Self = @This();

        /// Element type
        pub const Item = T;

        /// Queue capacity
        pub const len = capacity;

        /// FreeRTOS queue handle
        handle: c.QueueHandle_t,

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize queue
        pub fn init() Self {
            const handle = c.xQueueCreate(capacity, @sizeOf(T));
            return .{ .handle = handle };
        }

        /// Release queue resources
        pub fn deinit(self: *Self) void {
            if (self.handle != null) {
                c.vQueueDelete(self.handle);
                self.handle = null;
            }
        }

        // ====================================================================
        // Send Operations (Producer)
        // ====================================================================

        /// Send item to queue (blocking)
        pub fn send(self: *Self, item: T) void {
            _ = c.xQueueSend(self.handle, &item, c.portMAX_DELAY);
        }

        /// Send item to queue with timeout
        pub fn sendTimeout(self: *Self, item: T, timeout_ms: u32) bool {
            const ticks = msToTicks(timeout_ms);
            return c.xQueueSend(self.handle, &item, ticks) == c.pdTRUE;
        }

        /// Try to send item (non-blocking)
        pub fn trySend(self: *Self, item: T) bool {
            return c.xQueueSend(self.handle, &item, 0) == c.pdTRUE;
        }

        /// Send item from ISR context
        /// Returns true if a higher priority task was woken
        pub fn sendFromIsr(self: *Self, item: T) bool {
            var higher_priority_woken: c.BaseType_t = c.pdFALSE;
            _ = c.xQueueSendFromISR(self.handle, &item, &higher_priority_woken);
            return higher_priority_woken == c.pdTRUE;
        }

        // ====================================================================
        // Receive Operations (Consumer)
        // ====================================================================

        /// Receive item from queue (blocking)
        pub fn receive(self: *Self) T {
            var item: T = undefined;
            _ = c.xQueueReceive(self.handle, &item, c.portMAX_DELAY);
            return item;
        }

        /// Receive item from queue with timeout
        pub fn receiveTimeout(self: *Self, timeout_ms: u32) ?T {
            var item: T = undefined;
            const ticks = msToTicks(timeout_ms);
            if (c.xQueueReceive(self.handle, &item, ticks) == c.pdTRUE) {
                return item;
            }
            return null;
        }

        /// Try to receive item (non-blocking)
        pub fn tryReceive(self: *Self) ?T {
            var item: T = undefined;
            if (c.xQueueReceive(self.handle, &item, 0) == c.pdTRUE) {
                return item;
            }
            return null;
        }

        /// Peek at front item without removing
        pub fn peek(self: *Self) ?T {
            var item: T = undefined;
            if (c.xQueuePeek(self.handle, &item, 0) == c.pdTRUE) {
                return item;
            }
            return null;
        }

        // ====================================================================
        // Status Operations
        // ====================================================================

        /// Get number of items currently in queue
        pub fn count(self: *Self) usize {
            return @intCast(c.uxQueueMessagesWaiting(self.handle));
        }

        /// Check if queue is empty
        pub fn isEmpty(self: *Self) bool {
            return c.uxQueueMessagesWaiting(self.handle) == 0;
        }

        /// Check if queue is full
        pub fn isFull(self: *Self) bool {
            return c.uxQueueSpacesAvailable(self.handle) == 0;
        }

        /// Get available space in queue
        pub fn availableSpace(self: *Self) usize {
            return @intCast(c.uxQueueSpacesAvailable(self.handle));
        }

        /// Clear all items from queue
        pub fn reset(self: *Self) void {
            _ = c.xQueueReset(self.handle);
        }

        // ====================================================================
        // Helper functions
        // ====================================================================

        fn msToTicks(ms: u32) c.TickType_t {
            return ms / c.portTICK_PERIOD_MS;
        }
    };
}
