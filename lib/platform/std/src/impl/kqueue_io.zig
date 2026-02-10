//! kqueue-based IOService backend for macOS/BSD.
//!
//! Provides efficient event-driven I/O using kqueue. Satisfies the
//! trait.io contract defined in lib/trait/src/io.zig.
//!
//! ## Usage
//!
//! ```zig
//! const std_impl = @import("std_impl");
//! const KqueueIO = std_impl.kqueue_io.KqueueIO;
//!
//! var io = try KqueueIO.init(allocator);
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
const Allocator = std.mem.Allocator;

/// Raw kevent syscall wrapper that handles ALL errnos properly.
///
/// Zig std's `posix.kevent` marks EBADF and unknown errnos as `unreachable`,
/// which causes a panic before any `catch` handler can execute. In concurrent
/// scenarios (e.g., an fd closed by another thread during registration), the
/// kernel legitimately returns EBADF. This wrapper calls the C library's
/// `kevent()` directly and converts every errno to a Zig error.
fn rawKevent(
    kq: i32,
    changelist: []const posix.system.Kevent,
    eventlist: []posix.system.Kevent,
    timeout: ?*const posix.timespec,
) RawKeventError!usize {
    while (true) {
        const rc = posix.system.kevent(
            kq,
            changelist.ptr,
            @intCast(changelist.len),
            eventlist.ptr,
            @intCast(eventlist.len),
            timeout,
        );
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.BadFileDescriptor,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            .SRCH => return error.ProcessNotFound,
            .FAULT => return error.InvalidAddress,
            .INVAL => return error.InvalidArgument,
            else => |e| {
                std.log.warn("KqueueIO: unexpected kevent errno: {d}", .{@intFromEnum(e)});
                return error.Unexpected;
            },
        }
    }
}

const RawKeventError = error{
    BadFileDescriptor,
    AccessDenied,
    EventNotFound,
    SystemResources,
    ProcessNotFound,
    InvalidAddress,
    InvalidArgument,
    Unexpected,
};

/// kqueue-based I/O service implementing the IOService trait contract.
///
/// Thread safety: all public methods are safe to call from any thread.
/// Internally protected by a Mutex. Callbacks are invoked WITHOUT the
/// lock held, so callbacks may safely call registerRead/registerWrite/
/// unregister on the same KqueueIO instance.
pub const KqueueIO = struct {
    const Self = @This();
    const max_events = 64;
    const wake_ident: usize = 0xDEAD;

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
        read_registered: bool,
        write_registered: bool,
    };

    /// Pending callback snapshot — used to invoke callbacks outside the lock.
    const PendingCallback = struct {
        cb: ReadyCallback,
        fd: posix.fd_t,
    };

    kq: posix.fd_t,
    allocator: Allocator,
    registrations: std.AutoHashMap(posix.fd_t, Entry),
    events: [max_events]posix.system.Kevent,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) !Self {
        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        // Register EVFILT_USER event for wake() signaling
        const changelist = [_]posix.system.Kevent{.{
            .ident = wake_ident,
            .filter = posix.system.EVFILT.USER,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        _ = try rawKevent(kq, &changelist, &[_]posix.system.Kevent{}, null);

        return .{
            .kq = kq,
            .allocator = allocator,
            .registrations = std.AutoHashMap(posix.fd_t, Entry).init(allocator),
            .events = undefined,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.kq);
        self.registrations.deinit();
    }

    /// Register a file descriptor for read readiness.
    pub fn registerRead(self: *Self, fd: posix.fd_t, callback: ReadyCallback) void {
        self.registerFilter(fd, posix.system.EVFILT.READ, callback);
    }

    /// Register a file descriptor for write readiness.
    pub fn registerWrite(self: *Self, fd: posix.fd_t, callback: ReadyCallback) void {
        self.registerFilter(fd, posix.system.EVFILT.WRITE, callback);
    }

    /// Shared implementation for registering a filter on a file descriptor.
    fn registerFilter(self: *Self, fd: posix.fd_t, filter: i8, callback: ReadyCallback) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.registrations.getOrPut(fd) catch |err| {
            std.log.warn("KqueueIO: failed to update registration map for fd {d}: {s}", .{ fd, @errorName(err) });
            return;
        };
        const is_new = !result.found_existing;
        if (is_new) {
            result.value_ptr.* = .{
                .fd = fd,
                .read_cb = ReadyCallback.noop,
                .write_cb = ReadyCallback.noop,
                .read_registered = false,
                .write_registered = false,
            };
        }

        const is_read = (filter == posix.system.EVFILT.READ);
        if (is_read) {
            result.value_ptr.read_cb = callback;
        } else {
            result.value_ptr.write_cb = callback;
        }

        const already_registered = if (is_read) result.value_ptr.read_registered else result.value_ptr.write_registered;
        if (!already_registered) {
            // Use level-triggered (no EV_CLEAR). Edge-triggered events
            // require the caller to fully drain the fd on each callback;
            // if it cannot (e.g. pool exhaustion in UDP), remaining data
            // in the socket buffer would never trigger a new event, causing
            // an indefinite stall. Level-triggered keeps firing while the
            // condition holds, so a transient inability to drain is safe.
            const changelist = [_]posix.system.Kevent{.{
                .ident = @intCast(fd),
                .filter = filter,
                .flags = posix.system.EV.ADD,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = rawKevent(self.kq, &changelist, &[_]posix.system.Kevent{}, null) catch |err| {
                std.log.warn("KqueueIO: failed to register fd {d} with kqueue: {s}", .{ fd, @errorName(err) });
                if (is_new) {
                    _ = self.registrations.fetchRemove(fd);
                }
                return;
            };
            if (is_read) {
                result.value_ptr.read_registered = true;
            } else {
                result.value_ptr.write_registered = true;
            }
        }
    }

    /// Unregister a file descriptor from all events.
    pub fn unregister(self: *Self, fd: posix.fd_t) void {
        self.mutex.lock();
        const removed = self.registrations.fetchRemove(fd);
        self.mutex.unlock();

        if (removed) |entry| {
            var changelist: [2]posix.system.Kevent = undefined;
            var count: usize = 0;

            if (entry.value.read_registered) {
                changelist[count] = .{
                    .ident = @intCast(fd),
                    .filter = posix.system.EVFILT.READ,
                    .flags = posix.system.EV.DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };
                count += 1;
            }

            if (entry.value.write_registered) {
                changelist[count] = .{
                    .ident = @intCast(fd),
                    .filter = posix.system.EVFILT.WRITE,
                    .flags = posix.system.EV.DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };
                count += 1;
            }

            if (count > 0) {
                _ = rawKevent(self.kq, changelist[0..count], &[_]posix.system.Kevent{}, null) catch |err| {
                    std.log.warn("KqueueIO: failed to unregister fd {d}: {s}", .{ fd, @errorName(err) });
                };
            }
        }
    }

    /// Poll for I/O events and invoke callbacks.
    /// Pass -1 for timeout_ms to block indefinitely.
    /// Returns the number of events processed.
    ///
    /// Thread safety: kevent runs WITHOUT the lock (allows other threads
    /// to register/unregister while we block). Callbacks are snapshotted
    /// under the lock, then invoked without it (allows callbacks to call
    /// registerRead/registerWrite/unregister).
    pub fn poll(self: *Self, timeout_ms: i32) usize {
        const ts: ?posix.timespec = if (timeout_ms >= 0) .{
            .sec = @intCast(@divFloor(timeout_ms, 1000)),
            .nsec = @intCast(@mod(timeout_ms, 1000) * 1_000_000),
        } else null;

        // kevent without lock — may block, must not hold lock
        const n = rawKevent(
            self.kq,
            &[_]posix.system.Kevent{},
            &self.events,
            if (ts) |*t| t else null,
        ) catch return 0;

        // Snapshot callbacks under lock
        var pending: [max_events]PendingCallback = undefined;
        var pending_count: usize = 0;

        self.mutex.lock();
        for (self.events[0..n]) |event| {
            // Skip wake events — they just interrupt the poll
            if (event.filter == posix.system.EVFILT.USER and event.ident == wake_ident) {
                continue;
            }

            const fd: posix.fd_t = @intCast(event.ident);

            if (self.registrations.get(fd)) |entry| {
                if (event.filter == posix.system.EVFILT.READ) {
                    pending[pending_count] = .{ .cb = entry.read_cb, .fd = fd };
                    pending_count += 1;
                } else if (event.filter == posix.system.EVFILT.WRITE) {
                    pending[pending_count] = .{ .cb = entry.write_cb, .fd = fd };
                    pending_count += 1;
                }
            }
        }
        self.mutex.unlock();

        // Invoke callbacks WITHOUT the lock — callbacks may safely call
        // registerRead/registerWrite/unregister on this KqueueIO instance.
        for (pending[0..pending_count]) |p| {
            p.cb.call(p.fd);
        }

        return pending_count;
    }

    /// Interrupt a blocking poll() call from another thread.
    pub fn wake(self: *Self) void {
        const changelist = [_]posix.system.Kevent{.{
            .ident = wake_ident,
            .filter = posix.system.EVFILT.USER,
            .flags = 0,
            .fflags = posix.system.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        }};
        _ = rawKevent(self.kq, &changelist, &[_]posix.system.Kevent{}, null) catch |err| {
            std.log.warn("KqueueIO: failed to wake: {s}", .{@errorName(err)});
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "KqueueIO basic read" {
    var io = try KqueueIO.init(std.testing.allocator);
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

test "KqueueIO unregister" {
    var io = try KqueueIO.init(std.testing.allocator);
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

test "KqueueIO wake interrupts poll" {
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    io.wake();
    const count = io.poll(1000);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "KqueueIO socket fd read" {
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    // Create a UDP socket (the fd type that triggers the original panic)
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

test "KqueueIO socket fd write readiness" {
    var io = try KqueueIO.init(std.testing.allocator);
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

test "KqueueIO invalid fd does not panic" {
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    // Register a bogus fd — should log an error but NOT panic.
    // Before the rawKevent fix, this would hit `unreachable` in posix.kevent.
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

test "KqueueIO closed fd does not panic" {
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    // Create a socket, register it, then close it — simulates the
    // concurrent shutdown race condition from the original bug.
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);

    io.registerRead(sock, .{
        .ptr = null,
        .callback = struct {
            fn cb(_: ?*anyopaque, _: posix.fd_t) void {}
        }.cb,
    });

    // Close the fd while it's registered
    posix.close(sock);

    // Poll should not panic — kqueue may return EV_ERROR for the closed fd,
    // but our poll() catches errors with `catch return 0`.
    _ = io.poll(1);

    // Unregister should also not panic (EV_DELETE on closed fd returns EBADF)
    io.unregister(sock);
}

test "KqueueIO multi-thread wake" {
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    // Spawn a thread that wakes us after a short delay
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(io_ptr: *KqueueIO) void {
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

test "KqueueIO concurrent register and unregister" {
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    // Create several sockets and register/unregister them rapidly
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

    // Poll to process
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

    // Poll and unregister again
    _ = io.poll(1);
    for (sockets) |s| {
        io.unregister(s);
    }

    // Ensure no registrations leaked
    try std.testing.expectEqual(@as(u32, 0), io.registrations.count());
}

test "KqueueIO write readiness on pipe" {
    var io = try KqueueIO.init(std.testing.allocator);
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

    // Pipe write end should be immediately write-ready
    const count = io.poll(100);
    try std.testing.expect(count > 0);
    try std.testing.expect(write_called);
}

test "KqueueIO read and write on same fd" {
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    var read_called = false;
    var write_called = false;

    // Register both read on read-end and write on write-end
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

    // Write something so read end becomes ready
    _ = try posix.write(pipe_fds[1], "data");

    const count = io.poll(100);
    try std.testing.expect(count >= 2);
    try std.testing.expect(read_called);
    try std.testing.expect(write_called);
}

test "KqueueIO callback re-registers (no deadlock)" {
    // Regression test: callback calls registerRead on the same IO instance.
    // Before Mutex fix, this could deadlock or data-race on the HashMap.
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const pipe2_fds = try posix.pipe();
    defer posix.close(pipe2_fds[0]);
    defer posix.close(pipe2_fds[1]);

    const Ctx = struct {
        io: *KqueueIO,
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

test "KqueueIO concurrent register while polling" {
    // Test thread safety: one thread polls while another registers/unregisters.
    var io = try KqueueIO.init(std.testing.allocator);
    defer io.deinit();

    var stop = std.atomic.Value(bool).init(false);
    var events_seen = std.atomic.Value(u32).init(0);

    // Poller thread
    const poller = try std.Thread.spawn(.{}, struct {
        fn run(io_ptr: *KqueueIO, stop_flag: *std.atomic.Value(bool), seen: *std.atomic.Value(u32)) void {
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
