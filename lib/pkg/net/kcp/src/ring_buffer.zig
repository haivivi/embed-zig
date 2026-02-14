//! RingBuffer - A generic O(1) FIFO ring buffer implementation.
//!
//! Used by Stream for buffering received data from KCP.

const std = @import("std");

/// RingBuffer - O(1) read/write from head/tail with dynamic growth.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .buf = &[_]T{},
                .head = 0,
                .tail = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.buf.len > 0) {
                self.allocator.free(self.buf);
            }
        }

        pub fn readableLength(self: *const Self) usize {
            if (self.tail >= self.head) {
                return self.tail - self.head;
            } else {
                return self.buf.len - self.head + self.tail;
            }
        }

        pub fn read(self: *Self, dest: []T) usize {
            const to_read = @min(dest.len, self.readableLength());
            if (to_read == 0) return 0;

            const head = self.head;
            const cap = self.buf.len;

            const part1_len = @min(to_read, cap - head);
            @memcpy(dest[0..part1_len], self.buf[head..][0..part1_len]);

            const part2_len = to_read - part1_len;
            if (part2_len > 0) {
                @memcpy(dest[part1_len..][0..part2_len], self.buf[0..part2_len]);
            }

            self.head = (head + to_read) % cap;
            return to_read;
        }

        pub fn write(self: *Self, src: []const T) !void {
            const needed = self.readableLength() + src.len + 1;
            if (needed > self.buf.len) {
                try self.grow(needed);
            }

            const tail = self.tail;
            const cap = self.buf.len;
            const part1_len = @min(src.len, cap - tail);
            @memcpy(self.buf[tail..][0..part1_len], src[0..part1_len]);

            const part2_len = src.len - part1_len;
            if (part2_len > 0) {
                @memcpy(self.buf[0..part2_len], src[part1_len..][0..part2_len]);
            }

            self.tail = (tail + src.len) % cap;
        }

        fn grow(self: *Self, min_cap: usize) !void {
            var new_cap = if (self.buf.len == 0) 64 else self.buf.len;
            while (new_cap < min_cap) {
                new_cap *= 2;
            }

            const new_buf = try self.allocator.alloc(T, new_cap);
            const len = self.readableLength();

            if (len > 0) {
                const head = self.head;
                const cap = self.buf.len;
                const part1_len = @min(len, cap - head);
                @memcpy(new_buf[0..part1_len], self.buf[head..][0..part1_len]);

                const part2_len = len - part1_len;
                if (part2_len > 0) {
                    @memcpy(new_buf[part1_len..][0..part2_len], self.buf[0..part2_len]);
                }
            }

            if (self.buf.len > 0) {
                self.allocator.free(self.buf);
            }

            self.buf = new_buf;
            self.head = 0;
            self.tail = len;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "RingBuffer basic write and read" {
    const allocator = std.testing.allocator;
    var rb = RingBuffer(u8).init(allocator);
    defer rb.deinit();

    try rb.write("hello");
    try std.testing.expectEqual(@as(usize, 5), rb.readableLength());

    var buf: [16]u8 = undefined;
    const n = rb.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    try std.testing.expectEqual(@as(usize, 0), rb.readableLength());
}

test "RingBuffer wrap around" {
    const allocator = std.testing.allocator;
    var rb = RingBuffer(u8).init(allocator);
    defer rb.deinit();

    // Write and read to advance head past start
    try rb.write("AAAA");
    var tmp: [4]u8 = undefined;
    _ = rb.read(&tmp);

    // Now write data that wraps around
    try rb.write("BBBBCCCC");
    try std.testing.expectEqual(@as(usize, 8), rb.readableLength());

    var buf: [16]u8 = undefined;
    const n = rb.read(&buf);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualStrings("BBBBCCCC", buf[0..8]);
}

test "RingBuffer auto grow" {
    const allocator = std.testing.allocator;
    var rb = RingBuffer(u8).init(allocator);
    defer rb.deinit();

    // Write more than initial capacity (64)
    const data = "A" ** 100;
    try rb.write(data);
    try std.testing.expectEqual(@as(usize, 100), rb.readableLength());

    var buf: [128]u8 = undefined;
    const n = rb.read(&buf);
    try std.testing.expectEqual(@as(usize, 100), n);
    try std.testing.expectEqualStrings(data, buf[0..100]);
}

test "RingBuffer empty read" {
    const allocator = std.testing.allocator;
    var rb = RingBuffer(u8).init(allocator);
    defer rb.deinit();

    var buf: [16]u8 = undefined;
    const n = rb.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}
