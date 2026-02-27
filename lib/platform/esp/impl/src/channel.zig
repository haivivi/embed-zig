//! Channel — ESP32/FreeRTOS implementation
//!
//! Bounded, thread-safe FIFO channel using FreeRTOS xQueue.
//! For select support, uses xQueueSet (native FreeRTOS mechanism).

const std = @import("std");
const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/queue.h");
    @cInclude("freertos/task.h");
});

/// Bounded channel with Go chan semantics.
///
/// - `T`: element type
/// - `capacity`: buffer capacity (must be > 0)
pub fn Channel(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Channel capacity must be > 0");

    return struct {
        const Self = @This();

        /// Number of slots this channel occupies in a QueueSet.
        /// This is capacity (data queue) + 1 (close notification queue).
        /// Use this to calculate Selector's max_events parameter.
        pub const queue_set_slots = capacity + 1;

        handle: c.QueueHandle_t,
        closed: std.atomic.Value(bool),
        /// Serialize send attempts with close to avoid post-close send success race.
        send_gate: std.atomic.Value(bool),
        /// Close notification queue for selector support.
        /// When channel is closed, a byte is sent to this queue to wake up selectors.
        close_notify: c.QueueHandle_t,

        /// Initialize a new channel
        pub fn init() !Self {
            const handle = c.xQueueCreate(capacity, @sizeOf(T));
            if (handle == null) return error.QueueCreateFailed;

            // Create close notification queue (capacity 1, size 1 byte)
            // This allows selectors to be notified when the channel is closed
            const close_notify = c.xQueueCreate(1, 1);
            if (close_notify == null) {
                c.vQueueDelete(handle);
                return error.QueueCreateFailed;
            }

            return .{
                .handle = handle,
                .closed = std.atomic.Value(bool).init(false),
                .send_gate = std.atomic.Value(bool).init(false),
                .close_notify = close_notify,
            };
        }

        inline fn acquireSendGate(self: *Self) void {
            while (self.send_gate.cmpxchgWeak(false, true, .acq_rel, .acquire) != null) {
                c.vTaskDelay(1);
            }
        }

        inline fn releaseSendGate(self: *Self) void {
            self.send_gate.store(false, .release);
        }

        /// Release channel resources
        pub fn deinit(self: *Self) void {
            if (self.close_notify != null) {
                c.vQueueDelete(self.close_notify);
                self.close_notify = null;
            }
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
            while (true) {
                self.acquireSendGate();
                if (self.closed.load(.acquire)) {
                    self.releaseSendGate();
                    return error.Closed;
                }

                // Non-blocking attempt under send gate. This guarantees close can
                // atomically flip `closed` between attempts and prevent post-close sends.
                const result = c.xQueueSend(self.handle, &item, 0);
                self.releaseSendGate();

                if (result == c.pdTRUE) return;
                if (self.closed.load(.acquire)) return error.Closed;

                // Preserve blocking semantics while still allowing close to take effect.
                c.vTaskDelay(1);
            }
        }

        /// Try to send item (non-blocking).
        /// Returns error.Closed if closed, error.Full if buffer is full.
        pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void {
            self.acquireSendGate();
            defer self.releaseSendGate();

            if (self.closed.load(.acquire)) return error.Closed;
            const result = c.xQueueSend(self.handle, &item, 0);
            if (result == c.pdTRUE) return;

            // If close happened concurrently around this attempt, surface Closed
            // instead of Full to avoid masking close semantics.
            if (self.closed.load(.acquire)) return error.Closed;
            return error.Full;
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
            self.acquireSendGate();
            defer self.releaseSendGate();

            // Only close and notify if not already closed
            if (self.closed.load(.acquire)) return;

            self.closed.store(true, .release);

            // Send notification to wake up any selectors waiting on this channel.
            // This ensures that S2.3 (close wakes up selector) works on FreeRTOS.
            // Use 0 timeout since we only need to signal, not block.
            const notify_byte: u8 = 1;
            _ = c.xQueueSend(self.close_notify, &notify_byte, 0);
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

        /// Get the close notification queue handle for Selector.
        /// This allows selectors to be notified when the channel is closed.
        pub fn closeNotifyHandle(self: *const Self) c.QueueHandle_t {
            return self.close_notify;
        }

        /// Check if this queue has items available (for Selector).
        /// Returns true if messages are waiting.
        pub fn hasMessages(self: *const Self) bool {
            return c.uxQueueMessagesWaiting(self.handle) > 0;
        }
    };
}
