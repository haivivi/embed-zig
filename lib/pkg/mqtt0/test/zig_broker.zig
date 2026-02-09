//! Standalone Zig MQTT broker for cross-testing.
//!
//! Listens for connections, handles MQTT protocol, logs messages.
//! Designed to be started by test scripts and killed when done.
//!
//! Usage:
//!   zig build run-broker -- --port 18833

const std = @import("std");
const mqtt0 = @import("mqtt0");
const posix = std.posix;

const TestRt = struct {
    pub const Mutex = struct {
        inner: std.Thread.Mutex = .{},
        pub fn init() @This() { return .{ .inner = .{} }; }
        pub fn deinit(_: *@This()) void {}
        pub fn lock(self: *@This()) void { self.inner.lock(); }
        pub fn unlock(self: *@This()) void { self.inner.unlock(); }
    };
};

const TcpSocket = struct {
    fd: posix.socket_t,

    pub fn send(self: *TcpSocket, data: []const u8) !usize {
        return posix.send(self.fd, data, 0) catch return error.SendFailed;
    }

    pub fn recv(self: *TcpSocket, buf: []u8) !usize {
        const n = posix.recv(self.fd, buf, 0) catch return error.RecvFailed;
        if (n == 0) return error.ConnectionClosed;
        return n;
    }

    pub fn close(self: *TcpSocket) void {
        posix.close(self.fd);
    }
};

var msg_count: usize = 0;

fn handler(_: []const u8, msg: *const mqtt0.Message) anyerror!void {
    msg_count += 1;
    std.debug.print("[BROKER] msg #{d}: topic={s} payload={s}\n", .{
        msg_count,
        msg.topic,
        msg.payload,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Parse args
    var port: u16 = 18833;
    var max_clients: usize = 1;

    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |p| {
                port = std.fmt.parseInt(u16, p, 10) catch 18833;
            }
        } else if (std.mem.eql(u8, arg, "--clients")) {
            if (args.next()) |c| {
                max_clients = std.fmt.parseInt(usize, c, 10) catch 1;
            }
        }
    }

    // Setup broker
    var mux = try mqtt0.Mux(TestRt).init(allocator);
    defer mux.deinit();
    try mux.handleFn("#", handler);

    var broker = try mqtt0.Broker(TcpSocket, TestRt).init(allocator, mux.handler(), .{});
    defer broker.deinit();

    // Create listener
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    const enable: u32 = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
    };
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(fd, 5);

    std.debug.print("Zig MQTT broker listening on :{d} (v3.1.1 + v5.0, max {d} clients)\n", .{ port, max_clients });

    // Signal ready
    std.debug.print("READY\n", .{});

    // Accept connections
    var clients_served: usize = 0;
    while (clients_served < max_clients) {
        const client_fd = try posix.accept(fd, null, null, 0);
        clients_served += 1;
        std.debug.print("[BROKER] Client #{d} connected\n", .{clients_served});

        // Handle in a thread
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(b: *mqtt0.Broker(TcpSocket, TestRt), cfd: posix.socket_t) void {
                var conn = TcpSocket{ .fd = cfd };
                defer conn.close();
                b.serveConn(&conn);
            }
        }.run, .{ &broker, client_fd });

        // For single-client mode, wait for it to finish
        if (max_clients == 1) {
            thread.join();
        } else {
            thread.detach();
        }
    }

    // Give time for threads to finish
    std.Thread.sleep(100 * std.time.ns_per_ms);

    std.debug.print("[BROKER] Served {d} clients, {d} messages. Exiting.\n", .{ clients_served, msg_count });
}
