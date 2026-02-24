//! Channel — std platform implementation
//!
//! Bounded, thread-safe FIFO channel with Go `chan` semantics.
//! Uses pipe (macOS) or eventfd (Linux) for select support.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_kqueue = builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd;
const is_epoll = builtin.os.tag == .linux;

// Use the platform's sync primitives (which wrap std.Thread)
const sync = @import("sync.zig");

// ============================================================================
// Notifier — platform-specific notification fd
// ============================================================================

const Notifier = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    pub fn init() !Notifier {
        if (is_kqueue) {
            const fds = try posix.pipe();
            return .{
                .read_fd = fds[0],
                .write_fd = fds[1],
            };
        } else if (is_epoll) {
            const fd = posix.eventfd(0, posix.EFD.CLOEXEC | posix.EFD.NONBLOCK);
            return .{
                .read_fd = fd,
                .write_fd = fd,
            };
        } else {
            @compileError("Unsupported platform for Channel");
        }
    }

    pub fn deinit(self: *Notifier) void {
        posix.close(self.read_fd);
        if (is_kqueue) {
            posix.close(self.write_fd);
        }
    }

    pub fn notify(self: *Notifier) void {
        if (is_kqueue) {
            _ = posix.write(self.write_fd, &.{1}) catch {};
        } else if (is_epoll) {
            const val: u64 = 1;
            _ = posix.write(self.write_fd, std.mem.asBytes(&val)) catch {};
        }
    }

    pub fn consume(self: *Notifier) void {
        if (is_kqueue) {
            var buf: [256]u8 = undefined;
            while (true) {
                const n = posix.read(self.read_fd, &buf) catch break;
                if (n == 0) break;
            }
        } else if (is_epoll) {
            var val: u64 = undefined;
            _ = posix.read(self.read_fd, std.mem.asBytes(&val)) catch {};
        }
    }

    pub fn getFd(self: *const Notifier) posix.fd_t {
        return self.read_fd;
    }
};

// ============================================================================
// Channel
// ============================================================================

pub fn Channel(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Channel capacity must be > 0");

    return struct {
        const Self = @This();

        mutex: sync.Mutex,
        cond_not_empty: sync.Condition,
        cond_not_full: sync.Condition,
        buffer: [capacity]T,
        head: usize,
        tail: usize,
        size: usize,
        closed: bool,
        notifier: Notifier,

        pub fn init() !Self {
            return .{
                .mutex = sync.Mutex.init(),
                .cond_not_empty = sync.Condition.init(),
                .cond_not_full = sync.Condition.init(),
                .buffer = undefined,
                .head = 0,
                .tail = 0,
                .size = 0,
                .closed = false,
                .notifier = try Notifier.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.notifier.deinit();
        }

        pub fn send(self: *Self, item: T) error{Closed}!void {
            // Phase 1: Hold lock to modify channel state
            self.mutex.lock();

            while (self.size >= capacity and !self.closed) {
                self.cond_not_full.wait(&self.mutex);
            }

            if (self.closed) {
                self.mutex.unlock();
                return error.Closed;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;

            self.cond_not_empty.signal();
            self.mutex.unlock();

            // Phase 2: Notify outside of lock to avoid deadlock
            self.notifier.notify();
        }

        pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.Closed;
            if (self.size >= capacity) return error.Full;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;

            self.cond_not_empty.signal();
        }

        pub fn recv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.size == 0) {
                if (self.closed) return null;
                self.cond_not_empty.wait(&self.mutex);
            }

            return self.dequeue();
        }

        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.size == 0) return null;
            return self.dequeue();
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return;
            self.closed = true;

            self.cond_not_empty.broadcast();
            self.cond_not_full.broadcast();
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size == 0;
        }

        pub fn selectFd(self: *const Self) posix.fd_t {
            return self.notifier.getFd();
        }

        fn dequeue(self: *Self) T {
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.size -= 1;
            self.cond_not_full.signal();
            return item;
        }
    };
}
