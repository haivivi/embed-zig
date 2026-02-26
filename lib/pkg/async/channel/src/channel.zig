//! Generic runtime-backed channel compatibility layer.
//!
//! NOTE: New code should prefer platform `channel.Channel(T, N)` directly.
//! This module is retained for existing packages that depend on the old API:
//! `channel.Channel(T, N, Rt)`.

const std = @import("std");

pub fn Channel(comptime T: type, comptime capacity: usize, comptime Rt: type) type {
    if (capacity == 0) @compileError("Channel capacity must be > 0");

    return struct {
        const Self = @This();

        mutex: Rt.Mutex,
        not_empty: Rt.Condition,
        not_full: Rt.Condition,
        closed: bool,
        head: usize,
        tail: usize,
        count_: usize,
        buf: [capacity]T,

        pub fn init() Self {
            return .{
                .mutex = Rt.Mutex.init(),
                .not_empty = Rt.Condition.init(),
                .not_full = Rt.Condition.init(),
                .closed = false,
                .head = 0,
                .tail = 0,
                .count_ = 0,
                .buf = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            self.not_empty.deinit();
            self.not_full.deinit();
            self.mutex.deinit();
        }

        pub fn send(self: *Self, item: T) error{Closed}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count_ == capacity and !self.closed) {
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return error.Closed;

            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count_ += 1;
            self.not_empty.signal();
        }

        pub fn trySend(self: *Self, item: T) error{ Closed, Full }!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.Closed;
            if (self.count_ == capacity) return error.Full;

            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count_ += 1;
            self.not_empty.signal();
        }

        pub fn recv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count_ == 0 and !self.closed) {
                self.not_empty.wait(&self.mutex);
            }
            if (self.count_ == 0) return null;

            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.count_ -= 1;
            self.not_full.signal();
            return item;
        }

        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count_ == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.count_ -= 1;
            self.not_full.signal();
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return;
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count_;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.count() == 0;
        }
    };
}

test "channel basic send/recv" {
    const Rt = struct {
        pub const Mutex = struct {
            inner: std.Thread.Mutex = .{},
            pub fn init() @This() {
                return .{};
            }
            pub fn deinit(_: *@This()) void {}
            pub fn lock(self: *@This()) void {
                self.inner.lock();
            }
            pub fn unlock(self: *@This()) void {
                self.inner.unlock();
            }
        };

        pub const Condition = struct {
            inner: std.Thread.Condition = .{},
            pub fn init() @This() {
                return .{};
            }
            pub fn deinit(_: *@This()) void {}
            pub fn wait(self: *@This(), m: *Mutex) void {
                self.inner.wait(&m.inner);
            }
            pub fn signal(self: *@This()) void {
                self.inner.signal();
            }
            pub fn broadcast(self: *@This()) void {
                self.inner.broadcast();
            }
        };
    };

    const Ch = Channel(u32, 4, Rt);
    var ch = Ch.init();
    defer ch.deinit();

    try ch.send(42);
    try std.testing.expectEqual(@as(?u32, 42), ch.recv());
}
