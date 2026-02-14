//! StdRuntime — Runtime implementation using Zig standard library
//!
//! Provides Mutex, Condition, and spawn for cross-platform async packages.
//! This is the "glue" that makes Channel, WaitGroup, etc. work on desktop/POSIX.
//!
//! ## Usage
//!
//! ```zig
//! const std_impl = @import("std_impl");
//! const Rt = std_impl.runtime;
//!
//! const MyChannel = channel.Channel(u32, 16, Rt);
//! const MyWaitGroup = waitgroup.WaitGroup(Rt);
//! ```

const std = @import("std");

/// Mutex — wraps std.Thread.Mutex with init/deinit interface
pub const Mutex = struct {
    inner: std.Thread.Mutex,

    pub fn init() Mutex {
        return .{ .inner = .{} };
    }

    pub fn deinit(self: *Mutex) void {
        _ = self;
    }

    pub fn lock(self: *Mutex) void {
        self.inner.lock();
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

/// Condition — wraps std.Thread.Condition, paired with our Mutex type
pub const Condition = struct {
    inner: std.Thread.Condition,

    pub fn init() Condition {
        return .{ .inner = .{} };
    }

    pub fn deinit(self: *Condition) void {
        _ = self;
    }

    /// Atomically unlock mutex, wait for signal, re-lock mutex
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.wait(&mutex.inner);
    }

    /// Wake one waiting thread
    pub fn signal(self: *Condition) void {
        self.inner.signal();
    }

    /// Wake all waiting threads
    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast();
    }
};

/// Task spawn options
pub const Options = struct {
    /// Stack size in bytes (advisory on std, OS manages)
    stack_size: u32 = 8192,
    /// Task priority (advisory on std)
    priority: u8 = 16,
    /// CPU core affinity (-1 = any core)
    core: i8 = -1,
};

/// Task function signature
pub const TaskFn = *const fn (?*anyopaque) void;

/// Spawn a detached thread that runs independently
///
/// The thread is detached (fire-and-forget). Use WaitGroup if you need
/// to wait for completion.
pub fn spawn(name: [:0]const u8, func: TaskFn, ctx: ?*anyopaque, opts: Options) !void {
    _ = name;
    _ = opts;
    const thread = try std.Thread.spawn(.{}, struct {
        fn wrapper(f: TaskFn, c: ?*anyopaque) void {
            f(c);
        }
    }.wrapper, .{ func, ctx });
    thread.detach();
}

// ============================================================================
// Thread — Joinable thread (wraps std.Thread)
// ============================================================================

/// Joinable thread — wraps std.Thread for trait.spawner compatibility
pub const Thread = std.Thread;

// ============================================================================
// Time
// ============================================================================

/// Get current time in milliseconds
pub fn nowMs() u64 {
    return @intCast(std.time.milliTimestamp());
}

// ============================================================================
// CPU Info
// ============================================================================

/// Get CPU core count
pub fn getCpuCount() !usize {
    return std.Thread.getCpuCount() catch |err| {
        // std.Thread.getCpuCount() can fail on some platforms
        return err;
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Mutex basic" {
    var mutex = Mutex.init();
    defer mutex.deinit();

    mutex.lock();
    mutex.unlock();
}

test "Condition signal" {
    var mutex = Mutex.init();
    defer mutex.deinit();
    var cond = Condition.init();
    defer cond.deinit();

    var ready = false;

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(m: *Mutex, c: *Condition, r: *bool) void {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            m.lock();
            r.* = true;
            c.signal();
            m.unlock();
        }
    }.run, .{ &mutex, &cond, &ready });

    mutex.lock();
    while (!ready) {
        cond.wait(&mutex);
    }
    mutex.unlock();

    thread.join();
    try std.testing.expect(ready);
}

test "spawn fire and forget" {
    var done = std.atomic.Value(bool).init(false);

    try spawn("test", struct {
        fn run(ctx: ?*anyopaque) void {
            const d: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx));
            d.store(true, .release);
        }
    }.run, &done, .{});

    // Wait for thread to complete
    while (!done.load(.acquire)) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(done.load(.acquire));
}

test "Thread joinable spawn" {
    var called = std.atomic.Value(bool).init(false);

    const t = try std.Thread.spawn(.{}, struct {
        fn run(c: *std.atomic.Value(bool)) void {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            c.store(true, .release);
        }
    }.run, .{&called});

    t.join();
    try std.testing.expect(called.load(.acquire));
}

test "nowMs returns positive" {
    const ms = nowMs();
    try std.testing.expect(ms > 0);
}

test "getCpuCount returns at least 1" {
    const count = try getCpuCount();
    try std.testing.expect(count >= 1);
}
