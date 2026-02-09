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

/// epoll-based I/O service implementing the IOService trait contract.
pub const EpollIO = struct {
    const Self = @This();
    const max_events = 64;

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

    epfd: posix.fd_t,
    wake_fd: posix.fd_t, // eventfd for cross-thread wake
    allocator: Allocator,
    registrations: std.AutoHashMap(posix.fd_t, Entry),
    events: [max_events]linux.epoll_event,

    pub fn init(allocator: Allocator) !Self {
        const epfd = try posix.epoll_create1(.{ .CLOEXEC = true });
        errdefer posix.close(epfd);

        // Create eventfd for wake() signaling
        const wake_fd = try posix.eventfd(0, .{ .CLOEXEC = true, .NONBLOCK = true });
        errdefer posix.close(wake_fd);

        // Register eventfd with epoll
        var wake_event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = wake_fd },
        };
        try posix.epoll_ctl(epfd, .ADD, wake_fd, &wake_event);

        return .{
            .epfd = epfd,
            .wake_fd = wake_fd,
            .allocator = allocator,
            .registrations = std.AutoHashMap(posix.fd_t, Entry).init(allocator),
            .events = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.wake_fd);
        posix.close(self.epfd);
        self.registrations.deinit();
    }

    /// Register a file descriptor for read readiness.
    pub fn registerRead(self: *Self, fd: posix.fd_t, callback: ReadyCallback) void {
        self.registerEvents(fd, linux.EPOLL.IN, callback, true);
    }

    /// Register a file descriptor for write readiness.
    pub fn registerWrite(self: *Self, fd: posix.fd_t, callback: ReadyCallback) void {
        self.registerEvents(fd, linux.EPOLL.OUT, callback, false);
    }

    /// Shared implementation for registering events on a file descriptor.
    fn registerEvents(self: *Self, fd: posix.fd_t, event_flag: u32, callback: ReadyCallback, is_read: bool) void {
        const result = self.registrations.getOrPut(fd) catch |err| {
            std.log.err("EpollIO: failed to update registration map for fd {d}: {s}", .{ fd, @errorName(err) });
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
            const op: u32 = if (is_new) @intFromEnum(linux.EPOLL.CTL_ADD) else @intFromEnum(linux.EPOLL.CTL_MOD);
            posix.epoll_ctl(self.epfd, @enumFromInt(op), fd, &ev) catch |err| {
                std.log.err("EpollIO: failed to register fd {d} with epoll: {s}", .{ fd, @errorName(err) });
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
        if (self.registrations.fetchRemove(fd)) |_| {
            posix.epoll_ctl(self.epfd, .DEL, fd, null) catch |err| {
                std.log.err("EpollIO: failed to unregister fd {d}: {s}", .{ fd, @errorName(err) });
            };
        }
    }

    /// Poll for I/O events and invoke callbacks.
    /// Pass -1 for timeout_ms to block indefinitely.
    /// Returns the number of events processed.
    pub fn poll(self: *Self, timeout_ms: i32) usize {
        const n = posix.epoll_wait(self.epfd, &self.events, timeout_ms) catch return 0;

        var processed: usize = 0;
        for (self.events[0..n]) |event| {
            const fd = event.data.fd;

            // Skip wake events — just drain the eventfd
            if (fd == self.wake_fd) {
                var buf: [8]u8 = undefined;
                _ = posix.read(self.wake_fd, &buf) catch {};
                continue;
            }

            if (self.registrations.get(fd)) |entry| {
                if (event.events & linux.EPOLL.IN != 0) {
                    entry.read_cb.call(fd);
                    processed += 1;
                }
                if (event.events & linux.EPOLL.OUT != 0) {
                    entry.write_cb.call(fd);
                    processed += 1;
                }
            }
        }

        return processed;
    }

    /// Interrupt a blocking poll() call from another thread.
    pub fn wake(self: *Self) void {
        const val: [8]u8 = @bitCast(@as(u64, 1));
        _ = posix.write(self.wake_fd, &val) catch |err| {
            std.log.err("EpollIO: failed to wake: {s}", .{@errorName(err)});
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
