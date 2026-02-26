//! Selector — std platform implementation
//!
//! Multi-channel wait using kqueue (macOS/BSD) or epoll (Linux).
//! Allows waiting on multiple channels simultaneously.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const channel_impl = @import("channel.zig");

/// Convert EPOLL constants to u32.
/// Handles comptime ints, runtime ints, and packed struct(u32) flags.
inline fn epollToU32(val: anytype) u32 {
    const T = @TypeOf(val);
    const info = @typeInfo(T);
    // Handle both runtime int and compile-time int
    if (info == .int or info == .comptime_int) {
        return @as(u32, @intCast(val));
    }
    // For other types (like packed struct), use bitCast
    return @as(u32, @bitCast(val));
}

/// Convert EPOLL constants to i32 (for syscall op/flags args).
inline fn epollToI32(val: anytype) i32 {
    // First convert to u32, then cast to i32
    const u32_val: u32 = epollToU32(val);
    return @as(i32, @intCast(u32_val));
}

const is_kqueue = builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd;
const is_epoll = builtin.os.tag == .linux;

/// Source entry for tracking registered channels
const SourceEntry = struct {
    fd: posix.fd_t,
    logical_index: usize,
};

/// Selector — wait on multiple channels with optional timeout.
///
/// `max_sources` is the maximum number of channels that can be registered.
/// `max_events` is ignored on std platform (kept for API compatibility with FreeRTOS).
/// Timeout is handled separately in wait() call.
pub fn Selector(comptime max_sources: usize, comptime max_events: usize) type {
    _ = max_events; // Unused on std platform
    return struct {
        const Self = @This();

        entries: [max_sources]SourceEntry,
        recv_count: usize,
        source_count: usize,
        poll_fd: posix.fd_t, // kqueue fd or epoll fd
        timeout_enabled: bool,
        timeout_ms: u32,
        timeout_index: usize,

        fn createPollFd() !posix.fd_t {
            if (is_kqueue) {
                const fd: posix.fd_t = posix.system.kqueue();
                if (fd < 0) return error.PollCreateFailed;
                return fd;
            }

            if (is_epoll) {
                const flags: c_uint = @intCast(linux.EPOLL.CLOEXEC);
                const fd: posix.fd_t = posix.epoll_create1(flags) catch {
                    return error.PollCreateFailed;
                };
                if (fd < 0) return error.PollCreateFailed;
                return fd;
            }

            @compileError("Unsupported platform for Selector");
        }

        /// Initialize a new Selector
        pub fn init() !Self {
            const poll_fd = try createPollFd();

            return .{
                .entries = undefined,
                .recv_count = 0,
                .source_count = 0,
                .poll_fd = poll_fd,
                .timeout_enabled = false,
                .timeout_ms = 0,
                .timeout_index = max_sources,
            };
        }

        /// Release selector resources
        pub fn deinit(self: *Self) void {
            if (self.poll_fd >= 0) {
                posix.close(self.poll_fd);
                self.poll_fd = -1;
            }
        }

        /// Add a channel to wait on.
        /// Returns the index of the added source.
        /// Returns error.TooMany if max_sources is reached.
        pub fn addRecv(self: *Self, channel: anytype) error{ TooMany, PollCtlFailed }!usize {
            if (self.source_count >= max_sources) return error.TooMany;
            if (self.poll_fd < 0) return error.PollCtlFailed;

            const fd = channel.selectFd();
            const logical_index = self.source_count;
            const recv_index = self.recv_count;

            self.entries[recv_index] = .{
                .fd = fd,
                .logical_index = logical_index,
            };

            if (is_kqueue) {
                var ev: posix.Kevent = .{
                    .ident = @intCast(fd),
                    .filter = posix.system.EVFILT.READ,
                    .flags = posix.system.EV.ADD,
                    .fflags = 0,
                    .data = 0,
                    .udata = logical_index,
                };
                const rc = posix.system.kevent(
                    self.poll_fd,
                    @ptrCast(&ev),
                    1,
                    @ptrCast(&ev),
                    0,
                    null,
                );
                if (rc < 0) return error.PollCtlFailed;
            } else if (is_epoll) {
                var ev: posix.system.epoll_event = .{
                    .events = @intCast(linux.EPOLL.IN),
                    .data = .{ .u64 = logical_index },
                };
                const rc = posix.system.epoll_ctl(
                    self.poll_fd,
                    @intCast(linux.EPOLL.CTL_ADD),
                    fd,
                    &ev,
                );
                if (rc < 0) return error.PollCtlFailed;
            }

            self.recv_count += 1;
            self.source_count += 1;
            return logical_index;
        }

        /// Add a timeout source.
        /// This is a placeholder - the actual timeout is passed to wait().
        /// Note: This is kept for trait compatibility but timeout_ms should be passed to wait().
        pub fn addTimeout(self: *Self, timeout_ms: u32) error{TooMany}!usize {
            if (self.timeout_enabled) {
                self.timeout_ms = timeout_ms;
                return self.timeout_index;
            }
            if (self.source_count >= max_sources) return error.TooMany;

            self.timeout_enabled = true;
            self.timeout_ms = timeout_ms;
            self.timeout_index = self.source_count;
            self.source_count += 1;
            return self.timeout_index;
        }

        /// Wait for any channel to be ready or timeout.
        /// Returns the index of the ready source.
        /// Returns error.Empty if no sources were added.
        /// Returns max_sources if timeout occurred.
        pub fn wait(self: *Self, timeout_ms: ?u32) error{ Empty, PollWaitFailed, Interrupted }!usize {
            if (self.source_count == 0) return error.Empty;
            if (self.poll_fd < 0) return error.PollWaitFailed;

            const effective_timeout_ms = if (timeout_ms != null)
                timeout_ms
            else if (self.timeout_enabled)
                self.timeout_ms
            else
                null;

            if (is_kqueue) {
                return self.waitKqueue(effective_timeout_ms);
            } else if (is_epoll) {
                return self.waitEpoll(effective_timeout_ms);
            } else {
                @compileError("Unsupported platform for Selector");
            }
        }

        fn timeoutResult(self: *const Self) usize {
            if (self.timeout_enabled) return self.timeout_index;
            return max_sources;
        }

        fn waitKqueue(self: *Self, timeout_ms: ?u32) error{ PollWaitFailed, Interrupted }!usize {
            var event: posix.Kevent = undefined;
            var empty_change: [0]posix.Kevent = .{};
            var ts: posix.timespec = undefined;
            const timeout_ptr: ?*const posix.timespec = if (timeout_ms) |ms| blk: {
                ts = .{
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
                return switch (posix.errno(n)) {
                    .INTR => error.Interrupted,
                    else => error.PollWaitFailed,
                };
            }

            if (n == 0) {
                return self.timeoutResult();
            }

            // Return the index stored in udata
            return @intCast(event.udata);
        }

        fn waitEpoll(self: *Self, timeout_ms: ?u32) error{ PollWaitFailed, Interrupted }!usize {
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
                return switch (posix.errno(n)) {
                    .INTR => error.Interrupted,
                    else => error.PollWaitFailed,
                };
            }

            if (n == 0) {
                // Timeout
                return self.timeoutResult();
            }

            // Return the index stored in data.u64
            return @intCast(event.data.u64);
        }

        /// Reset the selector, clearing all registered sources.
        pub fn reset(self: *Self) void {
            // Re-create poll fd first. If creation fails, keep current selector state.
            // This avoids transitioning into a broken `poll_fd = -1` state.
            const new_poll_fd = createPollFd() catch return;

            if (self.poll_fd >= 0) {
                posix.close(self.poll_fd);
            }
            self.poll_fd = new_poll_fd;

            self.recv_count = 0;
            self.source_count = 0;
            self.timeout_enabled = false;
            self.timeout_ms = 0;
            self.timeout_index = max_sources;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Selector init/deinit" {
    const Sel = Selector(4, 16);
    var sel = try Sel.init();
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 0), sel.recv_count);
}

test "Selector reports explicit errors when poll fd is invalid" {
    const Ch = channel_impl.Channel(u32, 2);
    const Sel = Selector(2, 4);

    var ch1 = try Ch.init();
    defer ch1.deinit();
    var ch2 = try Ch.init();
    defer ch2.deinit();

    var sel = try Sel.init();
    defer sel.deinit();

    _ = try sel.addRecv(&ch1);

    // Simulate broken state after a failed low-level reset/recreate.
    sel.poll_fd = -1;

    try std.testing.expectError(error.PollWaitFailed, sel.wait(0));
    try std.testing.expectError(error.PollCtlFailed, sel.addRecv(&ch2));
}
