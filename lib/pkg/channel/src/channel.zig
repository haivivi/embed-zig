//! Channel — Go-style typed communication channel
//!
//! Bounded, thread-safe FIFO channel with Go `chan` semantics.
//! Generic over element type T, buffer capacity N, and Runtime Rt.
//!
//! ## Features
//!
//! - **Blocking send/recv** — goroutine-safe producer/consumer
//! - **Non-blocking trySend/tryRecv** — for poll-style usage
//! - **Close semantics** — close() signals "no more data", recv returns null
//! - **Signal** — Channel(void, 1, Rt) convenience for event notification
//!
//! ## Usage
//!
//! ```zig
//! const Rt = @import("std_sal").runtime;
//! const Ch = channel.Channel(u32, 16, Rt);
//!
//! var ch = Ch.init();
//! defer ch.deinit();
//!
//! // Producer
//! ch.send(42) catch |err| switch (err) {
//!     error.Closed => return,
//! };
//!
//! // Consumer
//! while (ch.recv()) |item| {
//!     // process item
//! }
//! // recv returned null → channel closed and drained
//! ```

const trait = @import("trait");

/// Bounded channel with Go chan semantics.
///
/// - `T`: element type
/// - `N`: buffer capacity (must be > 0)
/// - `Rt`: Runtime type providing Mutex, Condition (validated via trait.sync)
pub fn Channel(comptime T: type, comptime N: usize, comptime Rt: type) type {
    // Validate Runtime at comptime
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
    }

    if (N == 0) @compileError("Channel capacity must be > 0");

    return struct {
        const Self = @This();

        mutex: Rt.Mutex,
        not_empty: Rt.Condition,
        not_full: Rt.Condition,
        buffer: [N]T,
        head: usize,
        tail: usize,
        size: usize,
        closed: bool,

        /// Initialize a new channel
        pub fn init() Self {
            return .{
                .mutex = Rt.Mutex.init(),
                .not_empty = Rt.Condition.init(),
                .not_full = Rt.Condition.init(),
                .buffer = undefined,
                .head = 0,
                .tail = 0,
                .size = 0,
                .closed = false,
            };
        }

        /// Release channel resources
        pub fn deinit(self: *Self) void {
            self.not_full.deinit();
            self.not_empty.deinit();
            self.mutex.deinit();
        }

        // ================================================================
        // Send Operations (Producer)
        // ================================================================

        /// Send item to channel (blocking).
        /// Blocks until space is available or channel is closed.
        /// Returns error.Closed if channel was closed.
        pub fn send(self: *Self, item: T) error{Closed}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.size >= N and !self.closed) {
                self.not_full.wait(&self.mutex);
            }

            if (self.closed) return error.Closed;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % N;
            self.size += 1;

            self.not_empty.signal();
        }

        /// Try to send item (non-blocking).
        /// Returns error.Closed if closed, error.Full if buffer is full.
        pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.Closed;
            if (self.size >= N) return error.Full;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % N;
            self.size += 1;

            self.not_empty.signal();
        }

        // ================================================================
        // Receive Operations (Consumer)
        // ================================================================

        /// Receive item from channel (blocking).
        /// Blocks until an item is available.
        /// Returns null when channel is closed AND drained (no more items).
        pub fn recv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.size == 0) {
                if (self.closed) return null;
                self.not_empty.wait(&self.mutex);
            }

            return self.dequeue();
        }

        /// Try to receive item (non-blocking).
        /// Returns null if no items available.
        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.size == 0) return null;

            return self.dequeue();
        }

        // ================================================================
        // Channel Control
        // ================================================================

        /// Close the channel. No more sends allowed.
        /// Pending recv() calls will drain remaining items, then return null.
        /// Idempotent — safe to call multiple times.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;

            // Wake all waiters so they can observe the close
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        /// Check if channel is closed
        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        // ================================================================
        // Status Operations
        // ================================================================

        /// Get number of items currently in channel
        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size;
        }

        /// Check if channel is empty
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size == 0;
        }

        // ================================================================
        // Internal
        // ================================================================

        fn dequeue(self: *Self) T {
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % N;
            self.size -= 1;
            self.not_full.signal();
            return item;
        }
    };
}

/// Signal — lightweight notification channel (Channel(void, 1, Rt))
///
/// Used for simple event signaling between threads:
/// ```zig
/// var sig = Signal(Rt).init();
/// // Waiter:  sig.wait();
/// // Sender:  sig.notify();
/// ```
pub fn Signal(comptime Rt: type) type {
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
    }

    return struct {
        const Self = @This();

        mutex: Rt.Mutex,
        cond: Rt.Condition,
        signaled: bool,

        /// Initialize a new signal (not signaled)
        pub fn init() Self {
            return .{
                .mutex = Rt.Mutex.init(),
                .cond = Rt.Condition.init(),
                .signaled = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        /// Wait for signal (blocking). Resets after wake.
        pub fn wait(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.signaled) {
                self.cond.wait(&self.mutex);
            }
            self.signaled = false;
        }

        /// Send signal, waking one waiter
        pub fn notify(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.signaled = true;
            self.cond.signal();
        }

        /// Send signal, waking all waiters
        pub fn notifyAll(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.signaled = true;
            self.cond.broadcast();
        }

        /// Check if signaled without waiting (non-blocking, consumes signal)
        pub fn tryWait(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.signaled) {
                self.signaled = false;
                return true;
            }
            return false;
        }
    };
}

// ============================================================================
// Tests (using StdRuntime directly to avoid circular deps in build)
// ============================================================================

const std = @import("std");
const TestRt = @import("runtime");

test "Channel basic send/recv" {
    const Ch = Channel(u32, 4, TestRt);
    var ch = Ch.init();
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);

    try std.testing.expectEqual(@as(?u32, 1), ch.recv());
    try std.testing.expectEqual(@as(?u32, 2), ch.recv());
    try std.testing.expectEqual(@as(?u32, 3), ch.recv());
}

test "Channel close drains then returns null" {
    const Ch = Channel(u32, 4, TestRt);
    var ch = Ch.init();
    defer ch.deinit();

    try ch.send(10);
    try ch.send(20);
    ch.close();

    // Drain remaining items
    try std.testing.expectEqual(@as(?u32, 10), ch.recv());
    try std.testing.expectEqual(@as(?u32, 20), ch.recv());

    // Now should return null
    try std.testing.expectEqual(@as(?u32, null), ch.recv());
}

test "Channel send after close returns error" {
    const Ch = Channel(u32, 4, TestRt);
    var ch = Ch.init();
    defer ch.deinit();

    ch.close();

    const result = ch.send(1);
    try std.testing.expectError(error.Closed, result);
}

test "Channel trySend/tryRecv" {
    const Ch = Channel(u32, 2, TestRt);
    var ch = Ch.init();
    defer ch.deinit();

    try ch.trySend(1);
    try ch.trySend(2);

    // Full
    try std.testing.expectError(error.Full, ch.trySend(3));

    try std.testing.expectEqual(@as(?u32, 1), ch.tryRecv());
    try std.testing.expectEqual(@as(?u32, 2), ch.tryRecv());

    // Empty
    try std.testing.expectEqual(@as(?u32, null), ch.tryRecv());
}

test "Channel FIFO order" {
    const Ch = Channel(u32, 8, TestRt);
    var ch = Ch.init();
    defer ch.deinit();

    for (0..5) |i| {
        try ch.send(@intCast(i));
    }
    for (0..5) |i| {
        try std.testing.expectEqual(@as(?u32, @intCast(i)), ch.recv());
    }
}

test "Channel cross-thread producer/consumer" {
    const Ch = Channel(u32, 4, TestRt);
    var ch = Ch.init();
    defer ch.deinit();

    const count = 100;

    // Producer thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ch) void {
            for (0..count) |i| {
                c.send(@intCast(i)) catch return;
            }
            c.close();
        }
    }.run, .{&ch});

    // Consumer (main thread)
    var sum: u64 = 0;
    var received: u32 = 0;
    while (ch.recv()) |item| {
        sum += item;
        received += 1;
    }

    producer.join();

    try std.testing.expectEqual(@as(u32, count), received);
    // Sum of 0..99 = 4950
    try std.testing.expectEqual(@as(u64, 4950), sum);
}

test "Signal basic" {
    const Sig = Signal(TestRt);
    var sig = Sig.init();
    defer sig.deinit();

    try std.testing.expect(!sig.tryWait());

    sig.notify();
    try std.testing.expect(sig.tryWait());

    // Consumed
    try std.testing.expect(!sig.tryWait());
}

test "Signal cross-thread" {
    const Sig = Signal(TestRt);
    var sig = Sig.init();
    defer sig.deinit();

    var done = std.atomic.Value(bool).init(false);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Sig, d: *std.atomic.Value(bool)) void {
            s.wait(); // blocks until signal
            d.store(true, .release);
        }
    }.run, .{ &sig, &done });

    // Small delay to let thread start waiting
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(!done.load(.acquire));

    sig.notify();
    thread.join();

    try std.testing.expect(done.load(.acquire));
}
