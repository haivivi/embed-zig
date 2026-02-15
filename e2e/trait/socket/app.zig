//! e2e: trait/socket — Verify TCP connect/send/recv/listen/accept, UDP sendTo/recvFrom
//!
//! Tests:
//!   1. TCP: listen + accept + echo via trait Socket (all localhost)
//!   2. UDP: sendTo + recvFromWithAddr on localhost
//!
//! Both server and client use trait Socket — fully cross-platform.

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;
const Socket = platform.Socket;
const Rt = platform.runtime;

fn runTests() !void {
    log.info("[e2e] START: trait/socket", .{});

    try testTcpEcho();
    try testUdpEcho();

    log.info("[e2e] PASS: trait/socket", .{});
}

// Test 1: TCP listen + accept + echo — all using trait Socket
fn testTcpEcho() !void {
    const localhost: [4]u8 = .{ 127, 0, 0, 1 };

    // Server: bind + listen
    var server = Socket.tcp() catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — server tcp() failed: {}", .{err});
        return error.TcpServerFailed;
    };
    errdefer server.close();

    server.bind(localhost, 0) catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — bind failed: {}", .{err});
        return error.TcpBindFailed;
    };
    const port = server.getBoundPort() catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — getBoundPort failed: {}", .{err});
        return error.TcpGetPortFailed;
    };
    server.listen() catch |err| {
        log.err("[e2e] FAIL: trait/socket/tcp — listen failed: {}", .{err});
        return error.TcpListenFailed;
    };

    // Echo server in background thread
    const thread = try Rt.Thread.spawn(.{}, struct {
        fn run(srv: *Socket) void {
            var client = srv.accept() catch return;
            defer client.close();
            var buf: [64]u8 = undefined;
            const n = client.recv(&buf) catch return;
            _ = client.send(buf[0..n]) catch {};
        }
    }.run, .{&server});
    // join AFTER server.close in defer stack (LIFO: close unblocks accept, then join)
    defer thread.join();
    defer server.close();

    // Client: connect + send + recv
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
