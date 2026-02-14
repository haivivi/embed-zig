const std = @import("std");
const std_impl = @import("std_impl");
const posix = std.posix;

pub const log = struct {
    pub fn info(comptime fmt: []const u8, args: anytype) void { std.debug.print("[INFO] " ++ fmt ++ "\n", args); }
    pub fn err(comptime fmt: []const u8, args: anytype) void { std.debug.print("[ERR]  " ++ fmt ++ "\n", args); }
    pub fn warn(comptime fmt: []const u8, args: anytype) void { std.debug.print("[WARN] " ++ fmt ++ "\n", args); }
    pub fn debug(comptime fmt: []const u8, args: anytype) void { std.debug.print("[DBG]  " ++ fmt ++ "\n", args); }
};

pub const Socket = std_impl.socket.Socket;

/// TCP echo server using std.posix (platform-specific helper for tests)
pub const TcpEchoServer = struct {
    fd: posix.socket_t,
    thread: std.Thread,
    port: u16,

    pub fn start(ip: [4]u8) !TcpEchoServer {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        const addr = posix.sockaddr.in{
            .port = 0,
            .addr = @bitCast(ip),
        };
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 1);

        var bound: posix.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound), &len);
        const port = std.mem.bigToNative(u16, bound.port);

        const thread = try std.Thread.spawn(.{}, echoOnce, .{fd});

        return .{ .fd = fd, .thread = thread, .port = port };
    }

    pub fn stop(self: *TcpEchoServer) void {
        self.thread.join();
        posix.close(self.fd);
    }

    fn echoOnce(server_fd: posix.socket_t) void {
        var client_addr: posix.sockaddr.in = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const client = posix.accept(server_fd, @ptrCast(&client_addr), &client_len, 0) catch return;
        defer posix.close(client);
        var buf: [64]u8 = undefined;
        const n = posix.read(client, &buf) catch return;
        _ = posix.write(client, buf[0..n]) catch {};
    }
};
