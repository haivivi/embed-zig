//! Selector — std platform implementation
//!
//! Multi-channel wait using kqueue (macOS/BSD) or epoll (Linux).
//! Allows waiting on multiple channels simultaneously.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

fn epollToU32(flags: anytype) u32 {
    return @as(u32, @bitCast(flags));
}

const is_kqueue = builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd;
const is_epoll = builtin.os.tag == .linux;

/// Source entry for tracking registered channels
const SourceEntry = struct {
    fd: posix.fd_t,
    channel_ptr: ?*anyopaque,
};

/// Selector — wait on multiple channels with optional timeout.
///
/// `max_sources` is the maximum number of channels that can be registered.
/// Timeout is handled separately in wait() call.
pub fn Selector(comptime max_sources: usize) type {
    return struct {
        const Self = @This();

        entries: [max_sources]SourceEntry,
        count: usize,
        poll_fd: posix.fd_t, // kqueue fd or epoll fd

        /// Initialize a new Selector
        pub fn init() !Self {
            const poll_fd = blk: {
                if (is_kqueue) {
                    const fd = posix.system.kqueue();
                    if (fd < 0) return error.PollCreateFailed;
                    break :blk fd;
                } else if (is_epoll) {
                    const fd = posix.system.epoll_create1(epollToU32(linux.EPOLL.CLOEXEC));
                    if (fd < 0) return error.PollCreateFailed;
                    break :blk fd;
                } else {
                    @compileError("Unsupported platform for Selector");
                }
            };

            return .{
                .entries = undefined,
                .count = 0,
                .poll_fd = poll_fd,
            };
        }

        /// Release selector resources
        pub fn deinit(self: *Self) void {
            posix.close(self.poll_fd);
        }

        /// Add a channel to wait on.
        /// Returns the index of the added source.
        /// Returns error.TooMany if max_sources is reached.
        pub fn addRecv(self: *Self, channel: anytype) error{TooMany}!usize {
            if (self.count >= max_sources) return error.TooMany;

            const fd = channel.selectFd();
            const idx = self.count;

            self.entries[idx] = .{
                .fd = fd,
                .channel_ptr = @ptrCast(channel),
            };

            if (is_kqueue) {
                var ev: posix.Kevent = .{
                    .ident = @intCast(fd),
                    .filter = posix.system.EVFILT.READ,
                    .flags = posix.system.EV.ADD,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intCast(idx),
                };
                _ = posix.system.kevent(
                    self.poll_fd,
                    @ptrCast(&ev),
                    1,
                    @ptrCast(&ev), // Use same buffer for output (not used here)
                    0, // No output events expected
                    null,
                );
                // Ignore errors - if kevent fails, we'll notice on wait()
            } else if (is_epoll) {
                var ev: posix.system.epoll_event = .{
                    .events = epollToU32(linux.EPOLL.IN),
                    .data = .{ .u64 = idx },
                };
                _ = posix.system.epoll_ctl(
                    self.poll_fd,
                    epollToU32(linux.EPOLL.CTL_ADD),
                    fd,
                    &ev,
                );
                // Ignore errors - if epoll_ctl fails, we'll notice on wait()
            }

            self.count += 1;
            return idx;
        }

        /// Add a timeout source.
        /// This is a placeholder - the actual timeout is passed to wait().
        /// Note: This is kept for trait compatibility but timeout_ms should be passed to wait().
        pub fn addTimeout(self: *Self, timeout_ms: u32) error{TooMany}!usize {
            _ = self;
            _ = timeout_ms;
            // Timeout is handled internally in wait(), not as a separate fd source.
            // Return a special index indicating timeout
            return max_sources; // Special timeout index
        }

        /// Wait for any channel to be ready or timeout.
        /// Returns the index of the ready source.
        /// Returns error.Empty if no sources were added.
        /// Returns max_sources if timeout occurred.
        pub fn wait(self: *Self, timeout_ms: ?u32) error{Empty}!usize {
            if (self.count == 0) return error.Empty;

            if (is_kqueue) {
                return self.waitKqueue(timeout_ms);
            } else if (is_epoll) {
                return self.waitEpoll(timeout_ms);
            } else {
                @compileError("Unsupported platform for Selector");
            }
        }

        fn waitKqueue(self: *Self, timeout_ms: ?u32) error{Empty}!usize {
            var event: posix.Kevent = undefined;
            var empty_change: [0]posix.Kevent = .{};

            const timeout_ptr: ?*const posix.timespec = if (timeout_ms) |ms| blk: {
                const ts = posix.timespec{
                    .sec = @intCast(ms / 1000),
                    .nsec = @intCast((ms % 1000) * 1_000_000),
                };
                break :blk &ts;
            } else null;

            const n = posix.system.kevent(
                self.poll_fd,
                @ptrCast(&empty_change),
                0,
                @ptrCast(&event),
                1,
                timeout_ptr,
            );

            if (n < 0) {
                // Error or signal interruption
                return max_sources; // Treat as timeout for simplicity
            }

            if (n == 0) {
                // Timeout
                return max_sources;
            }

            // Return the index stored in udata
            return @intCast(event.udata);
        }

        fn waitEpoll(self: *Self, timeout_ms: ?u32) error{Empty}!usize {
            var event: posix.system.epoll_event = undefined;

            const timeout_int: i32 = if (timeout_ms) |ms|
                @intCast(ms)
            else
                -1; // Infinite wait

            const n = posix.system.epoll_wait(
                self.poll_fd,
                &event,
                1,
                timeout_int,
            );

            if (n < 0) {
                // Error
                return max_sources; // Treat as timeout for simplicity
            }

            if (n == 0) {
                // Timeout
                return max_sources;
            }

            // Return the index stored in data.u64
            return @intCast(event.data.u64);
        }

        /// Reset the selector, clearing all registered sources.
        pub fn reset(self: *Self) void {
            self.count = 0;

            // Close and re-create the poll fd
            posix.close(self.poll_fd);
            self.poll_fd = blk: {
                if (is_kqueue) {
                    const fd = posix.system.kqueue();
                    if (fd >= 0) break :blk fd;
                } else if (is_epoll) {
                    const fd = posix.system.epoll_create1(epollToU32(linux.EPOLL.CLOEXEC));
                    if (fd >= 0) break :blk fd;
                }
                // If re-creation fails, use invalid fd (will error on next use)
                break :blk -1;
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Selector init/deinit" {
    const Sel = Selector(4);
    var sel = try Sel.init();
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 0), sel.count);
}
