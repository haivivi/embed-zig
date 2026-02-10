//! epoll-based IOService backend for Linux.
//!
//! Provides efficient event-driven I/O using epoll. Satisfies the
//! trait.io contract defined in lib/trait/src/io.zig.
//!
//! ## Usage
//!
//! ```zig
//! const std_impl = @import("std_impl");
//! const EpollIO = std_impl.io_service.EpollIO;
//!
//! var io = try EpollIO.init(allocator);
//! defer io.deinit();
//!
//! io.registerRead(socket_fd, .{ .ptr = ctx, .callback = onReady });
//!
//! while (running) {
//!     _ = io.poll(-1);  // block until events
//! }
//!
//! // From another thread:
//! io.wake();  // interrupts blocking poll()
//! ```

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// Raw epoll_ctl wrapper that handles ALL errnos properly.
///
/// Zig std's `posix.epoll_ctl` marks EBADF and EINVAL as `unreachable`,
/// which causes a panic before any `catch` handler can execute. In concurrent
/// scenarios (e.g., an fd closed by another thread during registration), the
/// kernel legitimately returns EBADF. This wrapper calls the Linux syscall
/// directly and converts every errno to a Zig error.
fn rawEpollCtl(epfd: i32, op: u32, fd: i32, event: ?*linux.epoll_event) RawEpollCtlError!void {
    const rc = linux.epoll_ctl(epfd, op, fd, event);
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFileDescriptor,
        .EXIST => return error.FileDescriptorAlreadyPresentInSet,
        .INVAL => return error.InvalidArgument,
        .LOOP => return error.OperationCausesCircularLoop,
        .NOENT => return error.FileDescriptorNotRegistered,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.UserResourceLimitReached,
        .PERM => return error.FileDescriptorIncompatibleWithEpoll,
        else => |e| {
            std.log.warn("EpollIO: unexpected epoll_ctl errno: {d}", .{@intFromEnum(e)});
            return error.Unexpected;
        },
    }
}

const RawEpollCtlError = error{
    BadFileDescriptor,
    FileDescriptorAlreadyPresentInSet,
    InvalidArgument,
    OperationCausesCircularLoop,
    FileDescriptorNotRegistered,
    SystemResources,
    UserResourceLimitReached,
    FileDescriptorIncompatibleWithEpoll,
    Unexpected,
};

/// Raw epoll_wait wrapper that handles ALL errnos properly.
///
/// Zig std's `posix.epoll_wait` marks EBADF and unknown errnos as
/// `unreachable`. This wrapper handles them as proper errors.
fn rawEpollWait(epfd: i32, events: []linux.epoll_event, timeout: i32) usize {
    while (true) {
        const rc = linux.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF, .INVAL, .FAULT => return 0,
            else => |e| {
                std.log.warn("EpollIO: unexpected epoll_wait errno: {d}", .{@intFromEnum(e)});
                return 0;
            },
        }
    }
}

/// Helper: convert linux.EPOLL constants to u32.
///
/// Depending on the Zig version / target, EPOLL constants may be:
///   - comptime_int (e.g. CLOEXEC = 0x80000, CTL_ADD = 1)
///   - u32 / other runtime int
///   - packed struct(u32) (event flags like IN, OUT in some Zig versions)
///
/// This helper handles all three via comptime type dispatch.
inline fn epollToU32(val: anytype) u32 {
    return switch (@typeInfo(@TypeOf(val))) {
        .comptime_int, .int => val,
        else => @bitCast(val),
    };
}

/// epoll-based I/O service implementing the IOService trait contract.
///
/// Thread safety: all public methods are safe to call from any thread.
/// Internally protected by a Mutex. Callbacks are invoked WITHOUT the
/// lock held, so callbacks may safely call registerRead/registerWrite/
/// unregister on the same EpollIO instance.
pub const EpollIO = struct {
    const Self = @This();
    const max_events = 64;

    // Pre-computed u32 constants for EPOLL flags.
    // linux.EPOLL.IN/OUT are packed struct(u32) in Zig 0.14+; we convert
    // once here so the rest of the code uses plain u32 arithmetic.
    const EPOLL_IN: u32 = epollToU32(linux.EPOLL.IN);
    const EPOLL_OUT: u32 = epollToU32(linux.EPOLL.OUT);
    const EPOLL_ERR: u32 = epollToU32(linux.EPOLL.ERR);
    const EPOLL_HUP: u32 = epollToU32(linux.EPOLL.HUP);
    const EPOLL_CTL_ADD: u32 = epollToU32(linux.EPOLL.CTL_ADD);
    const EPOLL_CTL_MOD: u32 = epollToU32(linux.EPOLL.CTL_MOD);
    const EPOLL_CTL_DEL: u32 = epollToU32(linux.EPOLL.CTL_DEL);

    /// Callback invoked when a file descriptor is ready for I/O.
    pub const ReadyCallback = struct {
        /// Opaque pointer to callback context
        ptr: ?*anyopaque,
        /// Callback function
        callback: *const fn (ptr: ?*anyopaque, fd: posix.fd_t) void,

        /// Invoke the callback.
        pub fn call(self: @This(), fd: posix.fd_t) void {
            self.callback(self.ptr, fd);
        }

        /// A no-op callback.
        pub const noop: @This() = .{
            .ptr = null,
            .callback = struct {
                fn cb(_: ?*anyopaque, _: posix.fd_t) void {}
            }.cb,
        };
    };

    /// Internal registration entry
    const Entry = struct {
        fd: posix.fd_t,
        read_cb: ReadyCallback,
        write_cb: ReadyCallback,
        events: u32, // EPOLLIN | EPOLLOUT bitmask
    };

    /// Pending callback snapshot — used to invoke callbacks outside the lock.
    const PendingCallback = struct {
        cb: ReadyCallback,
        fd: posix.fd_t,
    };

    epfd: posix.fd_t,
    wake_fd: posix.fd_t, // eventfd for cross-thread wake
    allocator: Allocator,
    registrations: std.AutoHashMap(posix.fd_t, Entry),
    events: [max_events]linux.epoll_event,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) !Self {
        // EPOLL_CLOEXEC — linux.EPOLL.CLOEXEC is packed struct(u32) in Zig 0.14+
        const epfd = try posix.epoll_create1(epollToU32(linux.EPOLL.CLOEXEC));
        errdefer posix.close(epfd);

        // EFD_CLOEXEC | EFD_NONBLOCK — same packed struct conversion
        const wake_fd = try posix.eventfd(0, epollToU32(linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
        errdefer posix.close(wake_fd);

        // Register eventfd with epoll
        var wake_event = linux.epoll_event{
            .events = EPOLL_IN,
            .data = .{ .fd = wake_fd },
        };
        try rawEpollCtl(epfd, EPOLL_CTL_ADD, wake_fd, &wake_event);

        return .{
            .epfd = epfd,
            .wake_fd = wake_fd,
            .allocator = allocator,
            .registrations = std.AutoHashMap(posix.fd_t, Entry).init(allocator),
            .events = undefined,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.wake_fd);
        posix.close(self.epfd);
        self.registrations.deinit();
    }

    /// Register a file descriptor for read readiness.
    pub fn registerRead(self: *Self, fd: posix.fd_t, callback: ReadyCallback) void {
        self.registerEvents(fd, EPOLL_IN, callback, true);
    }

    /// Register a file descriptor for write readiness.
    pub fn registerWrite(self: *Self, fd: posix.fd_t, callback: ReadyCallback) void {
        self.registerEvents(fd, EPOLL_OUT, callback, false);
    }

    /// Shared implementation for registering events on a file descriptor.
    fn registerEvents(self: *Self, fd: posix.fd_t, event_flag: u32, callback: ReadyCallback, is_read: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.registrations.getOrPut(fd) catch |err| {
            std.log.warn("EpollIO: failed to update registration map for fd {d}: {s}", .{ fd, @errorName(err) });
            return;
        };
        const is_new = !result.found_existing;
        if (is_new) {
            result.value_ptr.* = .{
                .fd = fd,
                .read_cb = ReadyCallback.noop,
                .write_cb = ReadyCallback.noop,
                .events = 0,
            };
        }

        if (is_read) {
            result.value_ptr.read_cb = callback;
        } else {
            result.value_ptr.write_cb = callback;
        }

        const new_events = result.value_ptr.events | event_flag;
        const events_changed = new_events != result.value_ptr.events;

        if (events_changed) {
            // Level-triggered (no EPOLLET). Same rationale as kqueue:
            // edge-triggered requires fully draining the fd on each callback;
            // if it cannot (e.g. pool exhaustion in UDP), remaining data
            // would never trigger a new event, causing an indefinite stall.
            var ev = linux.epoll_event{
                .events = new_events,
                .data = .{ .fd = fd },
            };
            const op: u32 = if (is_new) EPOLL_CTL_ADD else EPOLL_CTL_MOD;
            rawEpollCtl(self.epfd, op, fd, &ev) catch |err| {
                std.log.warn("EpollIO: failed to register fd {d} with epoll: {s}", .{ fd, @errorName(err) });
                if (is_new) {
                    _ = self.registrations.fetchRemove(fd);
                }
                return;
            };
            // Only update events after successful epoll_ctl
            result.value_ptr.events = new_events;
        }
    }

    /// Unregister a file descriptor from all events.
    pub fn unregister(self: *Self, fd: posix.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.registrations.fetchRemove(fd)) |_| {
            // Hold lock through kernel call to prevent race with concurrent
            // registerRead/registerWrite on the same fd: without the lock,
            // a concurrent register could ADD the fd to epoll, then our
            // stale DELETE would silently remove it — leaving the fd in the
            // HashMap but not monitored by the kernel.
            // epoll_ctl DELETE is non-blocking, so holding the lock is safe.
            rawEpollCtl(self.epfd, EPOLL_CTL_DEL, fd, null) catch |err| {
                std.log.warn("EpollIO: failed to unregister fd {d}: {s}", .{ fd, @errorName(err) });
            };
        }
    }

    /// Poll for I/O events and invoke callbacks.
    /// Pass -1 for timeout_ms to block indefinitely.
    /// Returns the number of events processed.
    ///
    /// Thread safety: epoll_wait runs WITHOUT the lock (allows other
    /// threads to register/unregister while we block). Callbacks are
    /// snapshotted under the lock, then invoked without it (allows
    /// callbacks to call registerRead/registerWrite/unregister).
    pub fn poll(self: *Self, timeout_ms: i32) usize {
        // epoll_wait without lock — may block, must not hold lock
        const n = rawEpollWait(self.epfd, &self.events, timeout_ms);

        // Snapshot callbacks under lock
        var pending: [max_events * 2]PendingCallback = undefined;
        var pending_count: usize = 0;

        self.mutex.lock();
        for (self.events[0..n]) |event| {
            const fd = event.data.fd;
            const ev = @as(u32, @bitCast(event.events));

            // Skip wake events — just drain the eventfd
            if (fd == self.wake_fd) {
                var buf: [8]u8 = undefined;
                _ = posix.read(self.wake_fd, &buf) catch {};
                continue;
            }

            // EPOLLERR and EPOLLHUP are always reported by the kernel even
            // if not explicitly requested. Route them to BOTH read and write
            // callbacks so that write-only registrations (e.g. non-blocking
            // connect()) are notified of errors — matching kqueue's behavior
            // where EV_EOF/errors are delivered on whichever filter is
            // registered, including EVFILT_WRITE.
            const has_error = (ev & EPOLL_ERR != 0) or (ev & EPOLL_HUP != 0);
            const is_read = (ev & EPOLL_IN != 0) or has_error;
            const is_write = (ev & EPOLL_OUT != 0) or has_error;

            if (self.registrations.get(fd)) |entry| {
                if (is_read and (entry.events & EPOLL_IN != 0)) {
                    pending[pending_count] = .{ .cb = entry.read_cb, .fd = fd };
                    pending_count += 1;
                }
                if (is_write and (entry.events & EPOLL_OUT != 0)) {
                    pending[pending_count] = .{ .cb = entry.write_cb, .fd = fd };
                    pending_count += 1;
                }
            }
        }
        self.mutex.unlock();

        // Invoke callbacks WITHOUT the lock — callbacks may safely call
        // registerRead/registerWrite/unregister on this EpollIO instance.
        //
        // Design note: unlike the pre-Mutex code, we do NOT re-lookup
        // registrations between read and write callbacks for the same fd.
        // If a read callback calls unregister(fd), the snapshotted write
        // callback still fires. This is the standard pattern for thread-safe
        // event loops (libuv, tokio): snapshot-then-fire. The alternative
        // (re-lookup under lock per callback) adds overhead and still has
        // TOCTOU races. Callbacks must handle closed/reused fds gracefully.
        for (pending[0..pending_count]) |p| {
            p.cb.call(p.fd);
        }

        return pending_count;
    }

    /// Interrupt a blocking poll() call from another thread.
    pub fn wake(self: *Self) void {
        const val: [8]u8 = @bitCast(@as(u64, 1));
        _ = posix.write(self.wake_fd, &val) catch |err| {
            std.log.warn("EpollIO: failed to wake: {s}", .{@errorName(err)});
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EpollIO basic read" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    var read_called = false;
    var read_fd: posix.fd_t = -1;

    const Ctx = struct {
        called: *bool,
        fd: *posix.fd_t,
    };

    var ctx = Ctx{
        .called = &read_called,
        .fd = &read_fd,
    };

    io.registerRead(pipe_fds[0], .{
        .ptr = @ptrCast(&ctx),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, fd: posix.fd_t) void {
                const c: *Ctx = @ptrCast(@alignCast(ptr.?));
                c.called.* = true;
                c.fd.* = fd;
            }
        }.cb,
    });

    _ = try posix.write(pipe_fds[1], "hello");

    const count = io.poll(100);
    try std.testing.expect(count > 0);
    try std.testing.expect(read_called);
    try std.testing.expectEqual(pipe_fds[0], read_fd);
}

test "EpollIO unregister" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    var called = false;

    io.registerRead(pipe_fds[0], .{
        .ptr = @ptrCast(&called),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: posix.fd_t) void {
                const c: *bool = @ptrCast(@alignCast(ptr.?));
                c.* = true;
            }
        }.cb,
    });

    io.unregister(pipe_fds[0]);

    _ = try posix.write(pipe_fds[1], "hello");

    _ = io.poll(10);
    try std.testing.expect(!called);
}

test "EpollIO wake interrupts poll" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    io.wake();
    const count = io.poll(1000);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "EpollIO socket fd read" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    // Create a UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(sock);

    // Bind to ephemeral port
    const addr = posix.sockaddr.in{
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    // Get the assigned port
    var bound_addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(sock, @ptrCast(&bound_addr), &addr_len);

    var read_called = false;
    io.registerRead(sock, .{
        .ptr = @ptrCast(&read_called),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: posix.fd_t) void {
                const c: *bool = @ptrCast(@alignCast(ptr.?));
                c.* = true;
            }
        }.cb,
    });

    // Send data to ourselves
    const msg = "test";
    _ = try posix.sendto(sock, msg, 0, @ptrCast(&bound_addr), @sizeOf(posix.sockaddr.in));

    const count = io.poll(100);
    try std.testing.expect(count > 0);
    try std.testing.expect(read_called);
}

test "EpollIO socket fd write readiness" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    // A UDP socket is always write-ready
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(sock);

    var write_called = false;
    io.registerWrite(sock, .{
        .ptr = @ptrCast(&write_called),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: posix.fd_t) void {
                const c: *bool = @ptrCast(@alignCast(ptr.?));
                c.* = true;
            }
        }.cb,
    });

    const count = io.poll(100);
    try std.testing.expect(count > 0);
    try std.testing.expect(write_called);
}

test "EpollIO invalid fd does not panic" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    // Register a bogus fd — should log an error but NOT panic
    io.registerRead(9999, .{
        .ptr = null,
        .callback = struct {
            fn cb(_: ?*anyopaque, _: posix.fd_t) void {}
        }.cb,
    });

    // fd should not be in registrations (cleanup on error)
    try std.testing.expect(io.registrations.get(9999) == null);

    // poll should work fine
    const count = io.poll(1);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "EpollIO closed fd does not panic" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    // Create a socket, register it, then close it
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);

    io.registerRead(sock, .{
        .ptr = null,
        .callback = struct {
            fn cb(_: ?*anyopaque, _: posix.fd_t) void {}
        }.cb,
    });

    // Close the fd while it's registered
    posix.close(sock);

    // Poll should not panic
    _ = io.poll(1);

    // Unregister should also not panic
    io.unregister(sock);
}

test "EpollIO multi-thread wake" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    // Spawn a thread that wakes us after a short delay
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(io_ptr: *EpollIO) void {
            std.Thread.sleep(10 * std.time.ns_per_ms); // 10ms
            io_ptr.wake();
        }
    }.run, .{&io});

    // poll() should return quickly (not wait the full 5 seconds)
    const start = std.time.milliTimestamp();
    _ = io.poll(5000);
    const elapsed = std.time.milliTimestamp() - start;

    thread.join();

    // Should have returned well before the 5s timeout
    try std.testing.expect(elapsed < 2000);
}

test "EpollIO concurrent register and unregister" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    var sockets: [8]posix.fd_t = undefined;
    for (&sockets) |*s| {
        s.* = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
    }
    defer for (sockets) |s| posix.close(s);

    // Register all
    for (sockets) |s| {
        io.registerRead(s, .{
            .ptr = null,
            .callback = struct {
                fn cb(_: ?*anyopaque, _: posix.fd_t) void {}
            }.cb,
        });
    }

    _ = io.poll(1);

    // Unregister all
    for (sockets) |s| {
        io.unregister(s);
    }

    // Re-register with write
    for (sockets) |s| {
        io.registerWrite(s, .{
            .ptr = null,
            .callback = struct {
                fn cb(_: ?*anyopaque, _: posix.fd_t) void {}
            }.cb,
        });
    }

    _ = io.poll(1);
    for (sockets) |s| {
        io.unregister(s);
    }

    // Ensure no registrations leaked
    try std.testing.expectEqual(@as(u32, 0), io.registrations.count());
}

test "EpollIO write readiness on pipe" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    var write_called = false;
    io.registerWrite(pipe_fds[1], .{
        .ptr = @ptrCast(&write_called),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: posix.fd_t) void {
                const c: *bool = @ptrCast(@alignCast(ptr.?));
                c.* = true;
            }
        }.cb,
    });

    const count = io.poll(100);
    try std.testing.expect(count > 0);
    try std.testing.expect(write_called);
}

test "EpollIO read and write on same fd" {
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    var read_called = false;
    var write_called = false;

    io.registerRead(pipe_fds[0], .{
        .ptr = @ptrCast(&read_called),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: posix.fd_t) void {
                const c: *bool = @ptrCast(@alignCast(ptr.?));
                c.* = true;
            }
        }.cb,
    });

    io.registerWrite(pipe_fds[1], .{
        .ptr = @ptrCast(&write_called),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: posix.fd_t) void {
                const c: *bool = @ptrCast(@alignCast(ptr.?));
                c.* = true;
            }
        }.cb,
    });

    _ = try posix.write(pipe_fds[1], "data");

    const count = io.poll(100);
    try std.testing.expect(count >= 2);
    try std.testing.expect(read_called);
    try std.testing.expect(write_called);
}

test "EpollIO callback re-registers (no deadlock)" {
    // Regression test: callback calls registerRead on the same IO instance.
    // Before Mutex fix, this could deadlock or data-race on the HashMap.
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const pipe2_fds = try posix.pipe();
    defer posix.close(pipe2_fds[0]);
    defer posix.close(pipe2_fds[1]);

    const Ctx = struct {
        io: *EpollIO,
        new_fd: posix.fd_t,
        original_called: bool = false,
        reregistered_called: bool = false,
    };

    var ctx = Ctx{ .io = &io, .new_fd = pipe2_fds[0] };

    // Register read on pipe_fds[0]. The callback registers read on pipe2_fds[0].
    io.registerRead(pipe_fds[0], .{
        .ptr = @ptrCast(&ctx),
        .callback = struct {
            fn cb(ptr: ?*anyopaque, _: posix.fd_t) void {
                const c: *Ctx = @ptrCast(@alignCast(ptr.?));
                c.original_called = true;
                // Re-register from within callback — must not deadlock
                c.io.registerRead(c.new_fd, .{
                    .ptr = @ptrCast(c),
                    .callback = struct {
                        fn cb2(ptr2: ?*anyopaque, _: posix.fd_t) void {
                            const c2: *Ctx = @ptrCast(@alignCast(ptr2.?));
                            c2.reregistered_called = true;
                        }
                    }.cb2,
                });
            }
        }.cb,
    });

    // Trigger the first callback
    _ = try posix.write(pipe_fds[1], "trigger");
    _ = io.poll(100);
    try std.testing.expect(ctx.original_called);

    // Trigger the re-registered callback
    _ = try posix.write(pipe2_fds[1], "trigger2");
    _ = io.poll(100);
    try std.testing.expect(ctx.reregistered_called);
}

test "EpollIO concurrent register while polling" {
    // Test thread safety: one thread polls while another registers/unregisters.
    var io = try EpollIO.init(std.testing.allocator);
    defer io.deinit();

    var stop = std.atomic.Value(bool).init(false);
    var events_seen = std.atomic.Value(u32).init(0);

    // Poller thread
    const poller = try std.Thread.spawn(.{}, struct {
        fn run(io_ptr: *EpollIO, stop_flag: *std.atomic.Value(bool), seen: *std.atomic.Value(u32)) void {
            while (!stop_flag.load(.acquire)) {
                const n = io_ptr.poll(10);
                if (n > 0) _ = seen.fetchAdd(@intCast(n), .monotonic);
            }
        }
    }.run, .{ &io, &stop, &events_seen });

    // Register/unregister from this thread while poller is running
    var sockets: [16]posix.fd_t = undefined;
    for (&sockets) |*s| {
        s.* = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
    }
    defer for (sockets) |s| posix.close(s);

    // Rapid register/unregister cycles
    for (0..10) |_| {
        for (sockets) |s| {
            io.registerWrite(s, .{
                .ptr = null,
                .callback = struct {
                    fn cb(_: ?*anyopaque, _: posix.fd_t) void {}
                }.cb,
            });
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
        for (sockets) |s| {
            io.unregister(s);
        }
    }

    stop.store(true, .release);
    io.wake();
    poller.join();

    // No crash = success. Events seen is a bonus check.
    try std.testing.expectEqual(@as(u32, 0), io.registrations.count());
}
