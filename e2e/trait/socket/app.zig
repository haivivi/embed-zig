//! e2e: trait/socket — Verify TCP connect/send/recv, UDP sendTo/recvFrom
//!
//! Tests:
//!   1. TCP: connect to localhost server, send + recv echo
//!   2. UDP: sendTo + recvFromWithAddr on localhost
//!
//! The server side uses std.posix directly (not the trait Socket),
//! because listen/accept are not part of the cross-platform trait.

const std = @import("std");
const posix = std.posix;
const platform = @import("platform.zig");
const log = platform.log;
const Socket = platform.Socket;

fn runTests() !void {
    log.info("[e2e] START: trait/socket", .{});

    try testTcpEcho();
    try testUdpEcho();

    log.info("[e2e] PASS: trait/socket", .{});
}

// Test 1: TCP connect + send + recv via localhost echo server
fn testTcpEcho() !void {
    const localhost: [4]u8 = .{ 127, 0, 0, 1 };

    // Start a raw posix TCP server (listen/accept are not in trait)
    const server_fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch {
        log.err("[e2e] FAIL: trait/socket/tcp — server socket failed", .{});
        return error.TcpServerFailed;
    };
    defer posix.close(server_fd);

    const addr = posix.sockaddr.in{
        .port = 0, // OS picks a port
        .addr = @bitCast(localhost),
    };
    posix.bind(server_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch {
        log.err("[e2e] FAIL: trait/socket/tcp — server bind failed", .{});
        return error.TcpServerFailed;
    };
    posix.listen(server_fd, 1) catch {
        log.err("[e2e] FAIL: trait/socket/tcp — server listen failed", .{});
        return error.TcpServerFailed;
    };

    // Get bound port
    var bound_addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    posix.getsockname(server_fd, @ptrCast(&bound_addr), &addr_len) catch {
        log.err("[e2e] FAIL: trait/socket/tcp — getsockname failed", .{});
        return error.TcpServerFailed;
    };
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Server thread: accept + echo
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: posix.socket_t) void {
            var client_addr: posix.sockaddr.in = undefined;
            var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const client = posix.accept(fd, @ptrCast(&client_addr), &client_len, 0) catch return;
            defer posix.close(client);
            var buf: [64]u8 = undefined;
            const n = posix.read(client, &buf) catch return;
            _ = posix.write(client, buf[0..n]) catch {};
        }
    }.run, .{server_fd});
    defer server_thread.join();

    // Client: use trait Socket
    var client = Socket.tcp() catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — client tcp() failed: {}", .{err});
        return error.TcpClientFailed;
    };
    defer client.close();
    client.setRecvTimeout(2000);

    client.connect(localhost, port) catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — connect failed: {}", .{err});
        return error.TcpConnectFailed;
    };

    const msg = "hello e2e";
    _ = client.send(msg) catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — send failed: {}", .{err});
        return error.TcpSendFailed;
    };

    var buf: [64]u8 = undefined;
    const n = client.recv(&buf) catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — recv failed: {}", .{err});
        return error.TcpRecvFailed;
    };

    if (!std.mem.eql(u8, buf[0..n], msg)) {
        log.err("[e2e] FAIL: trait/socket/tcp — echo mismatch", .{});
        return error.TcpEchoMismatch;
    }
    log.info("[e2e] PASS: trait/socket/tcp — echoed {} bytes", .{n});
}

// Test 2: UDP sendTo + recvFromWithAddr
fn testUdpEcho() !void {
    const localhost: [4]u8 = .{ 127, 0, 0, 1 };

    // UDP receiver
    var receiver = Socket.udp() catch |err| {
        log.err("[e2e] FAIL: trait/socket/udp — receiver failed: {}", .{err});
        return error.UdpReceiverFailed;
    };
    defer receiver.close();
    receiver.bind(localhost, 0) catch |err| {
        log.err("[e2e] FAIL: trait/socket/udp — bind failed: {}", .{err});
        return error.UdpBindFailed;
    };
    receiver.setRecvTimeout(2000);
    const recv_port = receiver.getBoundPort() catch |err| {
        log.err("[e2e] FAIL: trait/socket/udp — getBoundPort failed: {}", .{err});
        return error.UdpGetPortFailed;
    };

    // UDP sender
    var sender = Socket.udp() catch |err| {
        log.err("[e2e] FAIL: trait/socket/udp — sender failed: {}", .{err});
        return error.UdpSenderFailed;
    };
    defer sender.close();

    const msg = "udp e2e";
    _ = sender.sendTo(localhost, recv_port, msg) catch |err| {
        log.err("[e2e] FAIL: trait/socket/udp — sendTo failed: {}", .{err});
        return error.UdpSendFailed;
    };

    var buf: [64]u8 = undefined;
    const result = receiver.recvFromWithAddr(&buf) catch |err| {
        log.err("[e2e] FAIL: trait/socket/udp — recvFromWithAddr failed: {}", .{err});
        return error.UdpRecvFailed;
    };

    if (!std.mem.eql(u8, buf[0..result.len], msg)) {
        log.err("[e2e] FAIL: trait/socket/udp — message mismatch", .{});
        return error.UdpMismatch;
    }
    log.info("[e2e] PASS: trait/socket/udp — {} bytes from port {}", .{ result.len, result.src_port });
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/socket — {}", .{err});
    };
}

test "e2e: trait/socket" {
    try runTests();
}
