//! Synchronization Primitives
//!
//! Cross-platform synchronization abstractions:
//! - Mutex: Mutual exclusion lock
//! - Semaphore: Counting semaphore
//! - Event: Event flags / condition variable
//!
//! Example:
//!   var mutex = sal.Mutex.init();
//!   defer mutex.deinit();
//!
//!   {
//!       mutex.lock();
//!       defer mutex.unlock();
//!       // critical section
//!   }

const std = @import("std");

// ============================================================================
// Mutex - Mutual Exclusion Lock
// ============================================================================

/// Mutual exclusion lock
///
/// Provides exclusive access to a shared resource.
/// Only one thread can hold the mutex at a time.
pub const Mutex = struct {
    /// Platform-specific implementation data
    impl: Impl,

    const Impl = opaque {};

    /// Initialize mutex
    pub fn init() Mutex {
        @compileError("sal.Mutex.init requires platform implementation");
    }

    /// Initialize mutex with custom allocator
    /// Some platforms may need to allocate internal structures
    pub fn initWithAllocator(allocator: std.mem.Allocator) !Mutex {
        _ = allocator;
        @compileError("sal.Mutex.initWithAllocator requires platform implementation");
    }

    /// Release mutex resources
    pub fn deinit(self: *Mutex) void {
        _ = self;
        @compileError("sal.Mutex.deinit requires platform implementation");
    }

    /// Acquire the mutex (blocking)
    pub fn lock(self: *Mutex) void {
        _ = self;
        @compileError("sal.Mutex.lock requires platform implementation");
    }

    /// Try to acquire the mutex (non-blocking)
    /// Returns true if acquired, false if already held
    pub fn tryLock(self: *Mutex) bool {
        _ = self;
        @compileError("sal.Mutex.tryLock requires platform implementation");
    }

    /// Release the mutex
    pub fn unlock(self: *Mutex) void {
        _ = self;
        @compileError("sal.Mutex.unlock requires platform implementation");
    }

    /// RAII-style scoped lock
    ///
    /// Example:
    ///   {
    ///       const held = mutex.acquire();
    ///       defer held.release();
    ///       // critical section
    ///   }
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

/// Counting semaphore
///
/// Allows up to N concurrent accesses to a resource.
/// Useful for resource pooling and producer-consumer patterns.
pub const Semaphore = struct {
    impl: Impl,

    const Impl = opaque {};

    /// Initialize semaphore with initial count
    pub fn init(initial_count: u32) Semaphore {
        _ = initial_count;
        @compileError("sal.Semaphore.init requires platform implementation");
    }

    /// Initialize binary semaphore (max count = 1)
    pub fn initBinary() Semaphore {
        @compileError("sal.Semaphore.initBinary requires platform implementation");
    }

    /// Release semaphore resources
    pub fn deinit(self: *Semaphore) void {
        _ = self;
        @compileError("sal.Semaphore.deinit requires platform implementation");
    }

    /// Wait (decrement) - blocks if count is 0
    pub fn wait(self: *Semaphore) void {
        _ = self;
        @compileError("sal.Semaphore.wait requires platform implementation");
    }

    /// Wait with timeout
    /// Returns true if acquired, false if timeout
    pub fn waitTimeout(self: *Semaphore, timeout_ms: u32) bool {
        _ = self;
        _ = timeout_ms;
        @compileError("sal.Semaphore.waitTimeout requires platform implementation");
    }

    /// Try wait (non-blocking)
    /// Returns true if acquired, false if would block
    pub fn tryWait(self: *Semaphore) bool {
        _ = self;
        @compileError("sal.Semaphore.tryWait requires platform implementation");
    }

    /// Signal (increment) - wakes one waiting thread
    pub fn signal(self: *Semaphore) void {
        _ = self;
        @compileError("sal.Semaphore.signal requires platform implementation");
    }

    /// Get current count (for debugging)
    pub fn getCount(self: *Semaphore) u32 {
        _ = self;
        @compileError("sal.Semaphore.getCount requires platform implementation");
    }
};

// ============================================================================
// Event - Event Flags / Condition
// ============================================================================

/// Event flags
///
/// Allows threads to wait for specific conditions/events.
/// Multiple flags can be set and waited on.
pub const Event = struct {
    impl: Impl,

    const Impl = opaque {};

    /// Wait mode for multi-flag waits
    pub const WaitMode = enum {
        /// Wait for ANY of the specified flags
        any,
        /// Wait for ALL of the specified flags
        all,
    };

    /// Initialize event
    pub fn init() Event {
        @compileError("sal.Event.init requires platform implementation");
    }

    /// Release event resources
    pub fn deinit(self: *Event) void {
        _ = self;
        @compileError("sal.Event.deinit requires platform implementation");
    }

    /// Set event flags
    pub fn set(self: *Event, flags: u32) void {
        _ = self;
        _ = flags;
        @compileError("sal.Event.set requires platform implementation");
    }

    /// Clear event flags
    pub fn clear(self: *Event, flags: u32) void {
        _ = self;
        _ = flags;
        @compileError("sal.Event.clear requires platform implementation");
    }

    /// Wait for event flags
    /// Returns the flags that were set
    pub fn wait(self: *Event, flags: u32, mode: WaitMode, clear_on_exit: bool) u32 {
        _ = self;
        _ = flags;
        _ = mode;
        _ = clear_on_exit;
        @compileError("sal.Event.wait requires platform implementation");
    }

    /// Wait for event flags with timeout
    /// Returns null on timeout, otherwise the flags that were set
    pub fn waitTimeout(self: *Event, flags: u32, mode: WaitMode, clear_on_exit: bool, timeout_ms: u32) ?u32 {
        _ = self;
        _ = flags;
        _ = mode;
        _ = clear_on_exit;
        _ = timeout_ms;
        @compileError("sal.Event.waitTimeout requires platform implementation");
    }

    /// Get current flags (non-blocking, no clear)
    pub fn getFlags(self: *Event) u32 {
        _ = self;
        @compileError("sal.Event.getFlags requires platform implementation");
    }
};
