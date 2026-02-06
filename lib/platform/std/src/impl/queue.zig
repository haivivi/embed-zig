//! SAL Queue Implementation - Zig std
//!
//! Implements sal.Queue interface using std.Thread primitives.
//! Thread-safe bounded FIFO queue using Mutex + Condition.

const std = @import("std");

/// Create a thread-safe bounded queue type using std.Thread primitives
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

        // Internal state
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,
        buffer: [capacity]T,
        head: usize, // Read position
        tail: usize, // Write position
        size: usize, // Current number of items

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize queue
        pub fn init() Self {
            return .{
                .mutex = .{},
                .not_empty = .{},
                .not_full = .{},
                .buffer = undefined,
                .head = 0,
                .tail = 0,
                .size = 0,
            };
        }

        /// Release queue resources
        pub fn deinit(self: *Self) void {
            _ = self;
            // std.Thread primitives don't need cleanup
        }

        // ====================================================================
        // Send Operations (Producer)
        // ====================================================================

        /// Send item to queue (blocking)
        pub fn send(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait until space is available
            while (self.size >= capacity) {
                self.not_full.wait(&self.mutex);
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;

            // Wake up a waiting consumer
            self.not_empty.signal();
        }

        /// Send item to queue with timeout
        pub fn sendTimeout(self: *Self, item: T, timeout_ms: u32) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

            // Wait until space is available or timeout
            while (self.size >= capacity) {
                self.not_full.timedWait(&self.mutex, timeout_ns) catch {
                    // Timeout
                    return false;
                };
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;

            self.not_empty.signal();
            return true;
        }

        /// Try to send item (non-blocking)
        pub fn trySend(self: *Self, item: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.size >= capacity) {
                return false;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;

            self.not_empty.signal();
            return true;
        }

        /// Send from ISR context - not applicable for std implementation
        /// Just calls trySend since std doesn't have ISR concept
        pub fn sendFromIsr(self: *Self, item: T) bool {
            return self.trySend(item);
        }

        // ====================================================================
        // Receive Operations (Consumer)
        // ====================================================================

        /// Receive item from queue (blocking)
        pub fn receive(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait until item is available
            while (self.size == 0) {
                self.not_empty.wait(&self.mutex);
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.size -= 1;

            // Wake up a waiting producer
            self.not_full.signal();

            return item;
        }

        /// Receive item from queue with timeout
        pub fn receiveTimeout(self: *Self, timeout_ms: u32) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

            // Wait until item is available or timeout
            while (self.size == 0) {
                self.not_empty.timedWait(&self.mutex, timeout_ns) catch {
                    // Timeout
                    return null;
                };
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.size -= 1;

            self.not_full.signal();

            return item;
        }

        /// Try to receive item (non-blocking)
        pub fn tryReceive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.size == 0) {
                return null;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.size -= 1;

            self.not_full.signal();

            return item;
        }

        /// Peek at front item without removing
        pub fn peek(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.size == 0) {
                return null;
            }

            return self.buffer[self.head];
        }

        // ====================================================================
        // Status Operations
        // ====================================================================

        /// Get number of items currently in queue
        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size;
        }

        /// Check if queue is empty
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size == 0;
        }

        /// Check if queue is full
        pub fn isFull(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size >= capacity;
        }

        /// Get available space in queue
        pub fn availableSpace(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return capacity - self.size;
        }

        /// Clear all items from queue
        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.head = 0;
            self.tail = 0;
            self.size = 0;

            // Wake up any waiting producers
            self.not_full.broadcast();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Queue basic operations" {
    const TestQueue = Queue(u32, 4);
    var q = TestQueue.init();
    defer q.deinit();

    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), q.count());
    try std.testing.expectEqual(@as(usize, 4), q.availableSpace());

    // Send items
    try std.testing.expect(q.trySend(1));
    try std.testing.expect(q.trySend(2));
    try std.testing.expect(q.trySend(3));

    try std.testing.expectEqual(@as(usize, 3), q.count());
    try std.testing.expect(!q.isEmpty());
    try std.testing.expect(!q.isFull());

    // Peek
    try std.testing.expectEqual(@as(?u32, 1), q.peek());
    try std.testing.expectEqual(@as(usize, 3), q.count()); // Peek doesn't remove

    // Receive items
    try std.testing.expectEqual(@as(?u32, 1), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, 2), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, 3), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, null), q.tryReceive());

    try std.testing.expect(q.isEmpty());
}

test "Queue full behavior" {
    const TestQueue = Queue(u32, 2);
    var q = TestQueue.init();
    defer q.deinit();

    try std.testing.expect(q.trySend(1));
    try std.testing.expect(q.trySend(2));
    try std.testing.expect(q.isFull());
    try std.testing.expect(!q.trySend(3)); // Should fail - queue full

    _ = q.tryReceive();
    try std.testing.expect(!q.isFull());
    try std.testing.expect(q.trySend(3)); // Should succeed now
}

test "Queue reset" {
    const TestQueue = Queue(u32, 4);
    var q = TestQueue.init();
    defer q.deinit();

    _ = q.trySend(1);
    _ = q.trySend(2);
    _ = q.trySend(3);

    try std.testing.expectEqual(@as(usize, 3), q.count());

    q.reset();

    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), q.count());
}

test "Queue FIFO order" {
    const TestQueue = Queue(u32, 8);
    var q = TestQueue.init();
    defer q.deinit();

    // Send in order
    for (0..5) |i| {
        _ = q.trySend(@intCast(i));
    }

    // Receive in same order (FIFO)
    for (0..5) |i| {
        const item = q.tryReceive();
        try std.testing.expectEqual(@as(?u32, @intCast(i)), item);
    }
}

test "Queue wrap around" {
    const TestQueue = Queue(u32, 3);
    var q = TestQueue.init();
    defer q.deinit();

    // Fill and drain multiple times to test wrap-around
    for (0..10) |round| {
        const base: u32 = @intCast(round * 3);

        _ = q.trySend(base + 0);
        _ = q.trySend(base + 1);
        _ = q.trySend(base + 2);

        try std.testing.expectEqual(@as(?u32, base + 0), q.tryReceive());
        try std.testing.expectEqual(@as(?u32, base + 1), q.tryReceive());
        try std.testing.expectEqual(@as(?u32, base + 2), q.tryReceive());
    }
}

test "Queue with struct type" {
    const Event = struct {
        id: u8,
        value: u32,
    };

    const EventQueue = Queue(Event, 4);
    var q = EventQueue.init();
    defer q.deinit();

    _ = q.trySend(.{ .id = 1, .value = 100 });
    _ = q.trySend(.{ .id = 2, .value = 200 });

    const e1 = q.tryReceive().?;
    try std.testing.expectEqual(@as(u8, 1), e1.id);
    try std.testing.expectEqual(@as(u32, 100), e1.value);

    const e2 = q.tryReceive().?;
    try std.testing.expectEqual(@as(u8, 2), e2.id);
    try std.testing.expectEqual(@as(u32, 200), e2.value);
}

test "Queue timeout operations" {
    const TestQueue = Queue(u32, 2);
    var q = TestQueue.init();
    defer q.deinit();

    // Receive timeout on empty queue
    const result = q.receiveTimeout(10); // 10ms timeout
    try std.testing.expectEqual(@as(?u32, null), result);

    // Fill queue
    _ = q.trySend(1);
    _ = q.trySend(2);

    // Send timeout on full queue
    const sent = q.sendTimeout(3, 10); // 10ms timeout
    try std.testing.expect(!sent);

    // Receive with timeout should succeed
    const item = q.receiveTimeout(10);
    try std.testing.expectEqual(@as(?u32, 1), item);
}
