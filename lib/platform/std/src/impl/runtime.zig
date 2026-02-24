//! Standard library runtime implementation (Mutex, Condition, Notify, spawn)

const std = @import("std");
const posix = std.posix;

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

/// Condition — wraps std.Thread.Condition with trait-compatible interface
pub const Condition = struct {
    inner: std.Thread.Condition,

    pub const TimedWaitResult = enum {
        signaled,
        timeout,
    };

    pub fn init() Condition {
        return .{
            .inner = .{},
        };
    }

    pub fn deinit(self: *Condition) void {
        _ = self;
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.wait(&mutex.inner);
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) TimedWaitResult {
        const timeout_ms: i32 = if (timeout_ns >= std.math.maxInt(u64))
            -1
        else
            @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(i32)));

        if (timeout_ms < 0) {
            self.inner.wait(&mutex.inner);
            return .signaled;
        }

        const result = self.inner.timedWait(&mutex.inner, timeout_ns);
        return if (result == error.Timeout) .timeout else .signaled;
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal();
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast();
    }
};

/// Notify — lightweight event notification (no Mutex required)
/// Linux: eventfd, macOS/BSD: kqueue + EVFILT_USER
pub const Notify = struct {
    const builtin = @import("builtin");

    fd: posix.fd_t,
    is_kqueue: bool,

    pub fn init() Notify {
        if (comptime builtin.os.tag == .linux) {
            const fd = posix.eventfd(0, std.os.linux.EFD.CLOEXEC) catch
                @panic("Notify: eventfd failed");
            return .{ .fd = fd, .is_kqueue = false };
        } else {
            // macOS/BSD: use kqueue + EVFILT_USER for proper binary semaphore semantics
            const kq = posix.kqueue() catch @panic("Notify: kqueue failed");
            // Register EVFILT_USER event with EV_CLEAR (auto-reset after consume)
            const changelist = [_]posix.system.Kevent{.{
                .ident = 1, // user identifier
                .filter = posix.system.EVFILT.USER,
                .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = posix.kevent(kq, &changelist, &[_]posix.system.Kevent{}, null) catch {
                posix.close(kq);
                @panic("Notify: kevent register failed");
            };
            return .{ .fd = kq, .is_kqueue = true };
        }
    }

    pub fn deinit(self: *Notify) void {
        posix.close(self.fd);
    }

    pub fn signal(self: *Notify) void {
        if (comptime builtin.os.tag == .linux) {
            const val: u64 = 1;
            _ = posix.write(self.fd, std.mem.asBytes(&val)) catch {};
        } else {
            // Trigger EVFILT_USER event with NOTE.TRIGGER
            const changelist = [_]posix.system.Kevent{.{
                .ident = 1,
                .filter = posix.system.EVFILT.USER,
                .flags = 0,
                .fflags = posix.system.NOTE.TRIGGER,
                .data = 0,
                .udata = 0,
            }};
            _ = posix.kevent(self.fd, &changelist, &[_]posix.system.Kevent{}, null) catch {};
        }
    }

    pub fn wait(self: *Notify) void {
        if (comptime builtin.os.tag == .linux) {
            var buf: [8]u8 = undefined;
            _ = posix.read(self.fd, &buf) catch {};
        } else {
            // Wait for EVFILT_USER event (with EV_CLEAR, auto-reset after consume)
            var events: [1]posix.system.Kevent = undefined;
            _ = posix.kevent(self.fd, &[_]posix.system.Kevent{}, &events, null) catch {};
        }
    }

    pub fn timedWait(self: *Notify, timeout_ns: u64) bool {
        const timeout_ms: i32 = if (timeout_ns >= std.math.maxInt(u64))
            -1
        else
            @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(i32)));

        if (comptime builtin.os.tag == .linux) {
            var pfds = [1]posix.pollfd{.{
                .fd = self.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const n = posix.poll(&pfds, timeout_ms) catch return false;
            if (n > 0) {
                var buf: [8]u8 = undefined;
                _ = posix.read(self.fd, &buf) catch {};
                return true;
            }
            return false;
        } else {
            // macOS/BSD: kevent with timeout
            const timeout = posix.timespec{
                .sec = @intCast(@divFloor(timeout_ms, 1000)),
                .nsec = @intCast(@mod(timeout_ms, 1000) * std.time.ns_per_ms),
            };
            var events: [1]posix.system.Kevent = undefined;
            const n = posix.kevent(self.fd, &[_]posix.system.Kevent{}, &events, &timeout) catch return false;
            return n > 0;
        }
    }
};

/// Task spawn options
pub const Options = struct {
    /// Stack size in bytes (advisory on std, OS manages)
    stack_size: u32 = 8192,
    /// Task priority (advisory on std)
    priority: u8 = 16,
    /// CPU core affinity (-1 = any core)
    core_id: i8 = -1,
};

/// Thread — wraps std.Thread with trait-compatible interface
pub const Thread = struct {
    inner: std.Thread,

    pub const SpawnConfig = struct {
        stack_size: usize = 8192,
    };

    pub fn spawn(config: SpawnConfig, comptime func: anytype, args: anytype) !Thread {
        const thread = try std.Thread.spawn(.{ .stack_size = config.stack_size }, func, args);
        return .{ .inner = thread };
    }

    pub fn join(self: Thread) void {
        self.inner.join();
    }

    pub fn detach(self: Thread) void {
        self.inner.detach();
    }
};

/// Spawn a new task/thread
pub fn spawn(comptime func: *const fn (?*anyopaque) void, arg: ?*anyopaque, opts: Options) !void {
    _ = opts;
    const thread = try std.Thread.spawn(.{}, func, .{arg});
    thread.detach();
}

/// Get the number of CPU cores available
pub fn getCpuCount() !u32 {
    return @intCast(std.Thread.getCpuCount() catch |err| return err);
}

// ============================================================================
// Tests
// ============================================================================

test "Mutex lock/unlock" {
    var m = Mutex.init();
    defer m.deinit();

    m.lock();
    m.unlock();
}

test "Condition wait/signal" {
    var m = Mutex.init();
    defer m.deinit();
    var c = Condition.init(&m);
    defer c.deinit();

    // Simple signal test - just verify it compiles and runs
    m.lock();
    c.signal();
    m.unlock();
}

test "Notify signal/wait" {
    var n = Notify.init();
    defer n.deinit();

    // Signal from another thread
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(notify: *Notify) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            notify.signal();
        }
    }.run, .{&n});

    n.wait();
    thread.join();
}

test "Notify timedWait signaled" {
    var n = Notify.init();
    defer n.deinit();

    // Signal immediately before wait
    n.signal();
    const signaled = n.timedWait(100 * std.time.ns_per_ms);
    try std.testing.expect(signaled);
}

test "Notify timedWait timeout" {
    var n = Notify.init();
    defer n.deinit();

    // Wait without signal - should timeout
    const start = std.time.milliTimestamp();
    const signaled = n.timedWait(50 * std.time.ns_per_ms);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(!signaled);
    try std.testing.expect(elapsed >= 40); // Allow some tolerance
}

test "Notify signal from thread" {
    var n = Notify.init();
    defer n.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(notify: *Notify) void {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            notify.signal();
        }
    }.run, .{&n});

    const signaled = n.timedWait(100 * std.time.ns_per_ms);
    thread.join();

    try std.testing.expect(signaled);
}
