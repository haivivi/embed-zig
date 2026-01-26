//! Queue - Thread-safe FIFO Queue
//!
//! Cross-platform thread-safe queue for inter-task communication.
//! Supports blocking, non-blocking, and timeout-based operations.
//!
//! This is a bounded queue with a fixed capacity specified at compile time.
//! Suitable for producer-consumer patterns and event passing.
//!
//! Example:
//!   const EventQueue = sal.Queue(Event, 32);
//!   var queue = EventQueue.init();
//!   defer queue.deinit();
//!
//!   // Producer
//!   try queue.send(.{ .button = .{ .id = .vol_up, .action = .press } });
//!
//!   // Consumer
//!   if (queue.receive()) |event| {
//!       handleEvent(event);
//!   }

const std = @import("std");

/// Create a thread-safe bounded queue type
///
/// Args:
///   - T: Element type stored in the queue
///   - capacity: Maximum number of elements (must be > 0)
///
/// Returns: Queue type with thread-safe operations
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

        /// Platform-specific implementation data
        impl: Impl,

        const Impl = opaque {};

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize queue
        pub fn init() Self {
            @compileError("sal.Queue.init requires platform implementation");
        }

        /// Release queue resources
        pub fn deinit(self: *Self) void {
            _ = self;
            @compileError("sal.Queue.deinit requires platform implementation");
        }

        // ====================================================================
        // Send Operations (Producer)
        // ====================================================================

        /// Send item to queue (blocking)
        ///
        /// Blocks until space is available in the queue.
        pub fn send(self: *Self, item: T) void {
            _ = self;
            _ = item;
            @compileError("sal.Queue.send requires platform implementation");
        }

        /// Send item to queue with timeout
        ///
        /// Returns true if sent, false if timeout
        pub fn sendTimeout(self: *Self, item: T, timeout_ms: u32) bool {
            _ = self;
            _ = item;
            _ = timeout_ms;
            @compileError("sal.Queue.sendTimeout requires platform implementation");
        }

        /// Try to send item (non-blocking)
        ///
        /// Returns true if sent, false if queue is full
        pub fn trySend(self: *Self, item: T) bool {
            _ = self;
            _ = item;
            @compileError("sal.Queue.trySend requires platform implementation");
        }

        /// Send item from ISR context (platform-specific)
        ///
        /// Returns true if a higher priority task was woken
        pub fn sendFromIsr(self: *Self, item: T) bool {
            _ = self;
            _ = item;
            @compileError("sal.Queue.sendFromIsr requires platform implementation");
        }

        // ====================================================================
        // Receive Operations (Consumer)
        // ====================================================================

        /// Receive item from queue (blocking)
        ///
        /// Blocks until an item is available.
        pub fn receive(self: *Self) T {
            _ = self;
            @compileError("sal.Queue.receive requires platform implementation");
        }

        /// Receive item from queue with timeout
        ///
        /// Returns item if received, null if timeout
        pub fn receiveTimeout(self: *Self, timeout_ms: u32) ?T {
            _ = self;
            _ = timeout_ms;
            @compileError("sal.Queue.receiveTimeout requires platform implementation");
        }

        /// Try to receive item (non-blocking)
        ///
        /// Returns item if available, null if queue is empty
        pub fn tryReceive(self: *Self) ?T {
            _ = self;
            @compileError("sal.Queue.tryReceive requires platform implementation");
        }

        /// Peek at front item without removing (non-blocking)
        ///
        /// Returns item if available, null if queue is empty
        pub fn peek(self: *Self) ?T {
            _ = self;
            @compileError("sal.Queue.peek requires platform implementation");
        }

        // ====================================================================
        // Status Operations
        // ====================================================================

        /// Get number of items currently in queue
        pub fn count(self: *Self) usize {
            _ = self;
            @compileError("sal.Queue.count requires platform implementation");
        }

        /// Check if queue is empty
        pub fn isEmpty(self: *Self) bool {
            _ = self;
            @compileError("sal.Queue.isEmpty requires platform implementation");
        }

        /// Check if queue is full
        pub fn isFull(self: *Self) bool {
            _ = self;
            @compileError("sal.Queue.isFull requires platform implementation");
        }

        /// Get available space in queue
        pub fn availableSpace(self: *Self) usize {
            _ = self;
            @compileError("sal.Queue.availableSpace requires platform implementation");
        }

        /// Clear all items from queue
        pub fn reset(self: *Self) void {
            _ = self;
            @compileError("sal.Queue.reset requires platform implementation");
        }
    };
}
