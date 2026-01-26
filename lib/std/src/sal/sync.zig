//! SAL Sync Implementation - Zig std
//!
//! Implements sal.sync interface using std.Thread primitives.

const std = @import("std");

// ============================================================================
// Mutex - Mutual Exclusion Lock
// ============================================================================

/// Mutual exclusion lock using std.Thread.Mutex
pub const Mutex = struct {
    inner: std.Thread.Mutex,

    /// Initialize mutex
    pub fn init() Mutex {
        return .{ .inner = .{} };
    }

    /// Release mutex resources
    pub fn deinit(self: *Mutex) void {
        _ = self;
        // std.Thread.Mutex doesn't need cleanup
    }

    /// Acquire the mutex (blocking)
    pub fn lock(self: *Mutex) void {
        self.inner.lock();
    }

    /// Try to acquire the mutex (non-blocking)
    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }

    /// Release the mutex
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }

    /// RAII-style scoped lock
    pub fn acquire(self: *Mutex) Held {
        self.lock();
        return .{ .mutex = self };
    }

    pub const Held = struct {
        mutex: *Mutex,

        pub fn release(self: Held) void {
            self.mutex.unlock();
        }
    };
};

// ============================================================================
// Semaphore - Counting Semaphore
// ============================================================================

/// Counting semaphore implemented with Mutex + Condition
pub const Semaphore = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    count: i32,
    max_count: i32,

    /// Initialize semaphore with initial count
    pub fn init(initial_count: u32) Semaphore {
        return .{
            .mutex = .{},
            .cond = .{},
            .count = @intCast(initial_count),
            .max_count = std.math.maxInt(i32),
        };
    }

    /// Initialize counting semaphore with max count
    pub fn initCounting(max_count: u32, initial_count: u32) Semaphore {
        return .{
            .mutex = .{},
            .cond = .{},
            .count = @intCast(initial_count),
            .max_count = @intCast(max_count),
        };
    }

    /// Initialize binary semaphore (max count = 1)
    pub fn initBinary() Semaphore {
        return .{
            .mutex = .{},
            .cond = .{},
            .count = 0,
            .max_count = 1,
        };
    }

    /// Release semaphore resources
    pub fn deinit(self: *Semaphore) void {
        _ = self;
        // No cleanup needed for std primitives
    }

    /// Wait (decrement) - blocks if count is 0
    pub fn wait(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count <= 0) {
            self.cond.wait(&self.mutex);
        }
        self.count -= 1;
    }

    /// Wait with timeout (milliseconds)
    /// Returns true if acquired, false if timeout
    pub fn waitTimeout(self: *Semaphore, timeout_ms: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

        while (self.count <= 0) {
            const result = self.cond.timedWait(&self.mutex, timeout_ns);
            if (result == .timed_out) {
                return false;
            }
        }
        self.count -= 1;
        return true;
    }

    /// Try wait (non-blocking)
    pub fn tryWait(self: *Semaphore) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count > 0) {
            self.count -= 1;
            return true;
        }
        return false;
    }

    /// Signal (increment) - wakes one waiting thread
    pub fn signal(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count < self.max_count) {
            self.count += 1;
        }
        self.cond.signal();
    }

    /// Get current count
    pub fn getCount(self: *Semaphore) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.count > 0) @intCast(self.count) else 0;
    }
};

// ============================================================================
// Event - Event Flags
// ============================================================================

/// Event flags implemented with Mutex + Condition
pub const Event = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    flags: u32,

    /// Wait mode for multi-flag waits
    pub const WaitMode = enum {
        any,
        all,
    };

    /// Initialize event
    pub fn init() Event {
        return .{
            .mutex = .{},
            .cond = .{},
            .flags = 0,
        };
    }

    /// Release event resources
    pub fn deinit(self: *Event) void {
        _ = self;
        // No cleanup needed
    }

    /// Set event flags
    pub fn set(self: *Event, flags: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flags |= flags;
        self.cond.broadcast();
    }

    /// Clear event flags
    pub fn clear(self: *Event, flags: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flags &= ~flags;
    }

    /// Wait for event flags
    pub fn wait(self: *Event, flags: u32, mode: WaitMode, clear_on_exit: bool) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (!self.checkFlags(flags, mode)) {
            self.cond.wait(&self.mutex);
        }

        const result = self.flags & flags;
        if (clear_on_exit) {
            self.flags &= ~flags;
        }
        return result;
    }

    /// Wait for event flags with timeout
    pub fn waitTimeout(self: *Event, flags: u32, mode: WaitMode, clear_on_exit: bool, timeout_ms: u32) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

        while (!self.checkFlags(flags, mode)) {
            const result = self.cond.timedWait(&self.mutex, timeout_ns);
            if (result == .timed_out) {
                return null;
            }
        }

        const result = self.flags & flags;
        if (clear_on_exit) {
            self.flags &= ~flags;
        }
        return result;
    }

    /// Get current flags
    pub fn getFlags(self: *Event) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.flags;
    }

    fn checkFlags(self: *Event, flags: u32, mode: WaitMode) bool {
        return switch (mode) {
            .any => (self.flags & flags) != 0,
            .all => (self.flags & flags) == flags,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Mutex basic" {
    var mutex = Mutex.init();
    defer mutex.deinit();

    mutex.lock();
    mutex.unlock();

    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

test "Mutex acquire/release" {
    var mutex = Mutex.init();
    defer mutex.deinit();

    {
        const held = mutex.acquire();
        defer held.release();
        // critical section
    }

    // Mutex should be unlocked now
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

test "Semaphore basic" {
    var sem = Semaphore.init(1);
    defer sem.deinit();

    try std.testing.expectEqual(@as(u32, 1), sem.getCount());

    sem.wait();
    try std.testing.expectEqual(@as(u32, 0), sem.getCount());

    sem.signal();
    try std.testing.expectEqual(@as(u32, 1), sem.getCount());
}

test "Semaphore tryWait" {
    var sem = Semaphore.init(0);
    defer sem.deinit();

    try std.testing.expect(!sem.tryWait()); // Should fail, count is 0

    sem.signal();
    try std.testing.expect(sem.tryWait()); // Should succeed
    try std.testing.expect(!sem.tryWait()); // Should fail again
}

test "Semaphore binary" {
    var sem = Semaphore.initBinary();
    defer sem.deinit();

    sem.signal();
    sem.signal(); // Should not increase count beyond 1
    try std.testing.expectEqual(@as(u32, 1), sem.getCount());
}

test "Event basic" {
    var event = Event.init();
    defer event.deinit();

    try std.testing.expectEqual(@as(u32, 0), event.getFlags());

    event.set(0x01);
    try std.testing.expectEqual(@as(u32, 0x01), event.getFlags());

    event.set(0x02);
    try std.testing.expectEqual(@as(u32, 0x03), event.getFlags());

    event.clear(0x01);
    try std.testing.expectEqual(@as(u32, 0x02), event.getFlags());
}

test "Event wait any" {
    var event = Event.init();
    defer event.deinit();

    event.set(0x02);

    const result = event.wait(0x03, .any, false);
    try std.testing.expectEqual(@as(u32, 0x02), result);
    try std.testing.expectEqual(@as(u32, 0x02), event.getFlags()); // Not cleared
}

test "Event wait all with clear" {
    var event = Event.init();
    defer event.deinit();

    event.set(0x03);

    const result = event.wait(0x03, .all, true);
    try std.testing.expectEqual(@as(u32, 0x03), result);
    try std.testing.expectEqual(@as(u32, 0x00), event.getFlags()); // Cleared
}
