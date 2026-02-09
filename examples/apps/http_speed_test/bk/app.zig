//! HTTP Speed Test — BK7258
//!
//! Tests HTTP GET throughput over WiFi.

const bk = @import("bk");
const armino = bk.armino;

const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";

// Test server: httpbin.org (or any HTTP server)
const TEST_HOST = "httpbin.org";
const TEST_IP = [4]u8{ 54, 208, 94, 11 }; // httpbin.org IP (may change)
const TEST_PORT: u16 = 80;
const TEST_PATH = "/bytes/4096"; // Download 4KB

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "       HTTP Speed Test (BK7258)");
    armino.log.info("ZIG", "==========================================");

    armino.wifi.init() catch return;
    var ssid_buf: [33:0]u8 = @splat(0);
    var pass_buf: [65:0]u8 = @splat(0);
    @memcpy(ssid_buf[0..WIFI_SSID.len], WIFI_SSID);
    @memcpy(pass_buf[0..WIFI_PASSWORD.len], WIFI_PASSWORD);
    armino.wifi.connect(&ssid_buf, &pass_buf) catch return;

    // Wait for IP
    var timeout: u32 = 0;
    var dns_server: [4]u8 = .{0,0,0,0};
    while (timeout < 30000) {
        while (armino.wifi.popEvent()) |ev| {
            switch (ev) { .got_ip => |info| { dns_server = info.dns; timeout = 30000; }, else => {} }
        }
        armino.time.sleepMs(100);
        timeout += 100;
    }
    if (dns_server[0] == 0) { armino.log.err("ZIG", "WiFi timeout"); return; }

    armino.log.info("ZIG", "WiFi connected!");
    armino.log.info("ZIG", "");

    // Resolve test host
    armino.log.logFmt("ZIG", "Resolving {s}...", .{TEST_HOST});
    const ip = dnsResolve(TEST_HOST, dns_server) orelse {
        armino.log.err("ZIG", "DNS failed, using hardcoded IP");
        doHttpTest(TEST_IP);
        return;
    };
    armino.log.logFmt("ZIG", "Resolved: {d}.{d}.{d}.{d}", .{ip[0], ip[1], ip[2], ip[3]});

    // Run HTTP tests
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        doHttpTest(ip);
        armino.time.sleepMs(1000);
    }

    armino.log.info("ZIG", "=== HTTP Speed Test Done ===");
    while (true) { armino.time.sleepMs(10000); }
}

fn doHttpTest(ip: [4]u8) void {
    const Socket = armino.socket.Socket;
    var sock = Socket.tcp() catch {
        armino.log.err("ZIG", "Socket create failed");
        return;
    };
    defer sock.close();
    sock.setRecvTimeout(10000);

    sock.connect(ip, TEST_PORT) catch {
        armino.log.err("ZIG", "Connect failed");
        return;
    };

    // Send HTTP GET
    const req = "GET " ++ TEST_PATH ++ " HTTP/1.1\r\nHost: " ++ TEST_HOST ++ "\r\nConnection: close\r\n\r\n";
    _ = sock.send(req) catch {
        armino.log.err("ZIG", "Send failed");
        return;
    };

    // Receive response
    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    const start = armino.time.nowMs();

    while (true) {
        const n = sock.recv(&buf) catch break;
        total += n;
    }

    const elapsed = armino.time.nowMs() - start;
    const kbps = if (elapsed > 0) total * 8 / @as(usize, @intCast(elapsed)) else 0;
    armino.log.logFmt("ZIG", "HTTP GET: {d} bytes in {d}ms ({d} kbps)", .{ total, elapsed, kbps });
}

fn dnsResolve(domain: []const u8, server: [4]u8) ?[4]u8 {
    const Socket = armino.socket.Socket;
    var sock = Socket.udp() catch return null;
    defer sock.close();
    sock.setRecvTimeout(5000);
    var buf: [512]u8 = undefined;
    const qlen = buildQuery(domain, &buf) catch return null;
    _ = sock.sendTo(server, 53, buf[0..qlen]) catch return null;
    var resp: [512]u8 = undefined;
    const rlen = sock.recvFrom(&resp) catch return null;
    return parseResponse(resp[0..rlen]);
}

fn buildQuery(domain: []const u8, buf: []u8) !usize {
    buf[0] = 0x12; buf[1] = 0x34; buf[2] = 0x01; buf[3] = 0x00;
    buf[4] = 0x00; buf[5] = 0x01; @memset(buf[6..12], 0);
    var pos: usize = 12;
    var start: usize = 0;
    for (domain, 0..) |ch, i| {
        if (ch == '.') {
            const l = i - start;
            buf[pos] = @intCast(l); pos += 1;
            @memcpy(buf[pos..][0..l], domain[start..i]); pos += l;
            start = i + 1;
        }
    }
    const l = domain.len - start;
    buf[pos] = @intCast(l); pos += 1;
    @memcpy(buf[pos..][0..l], domain[start..]); pos += l;
    buf[pos] = 0; pos += 1;
    buf[pos] = 0; buf[pos+1] = 1; buf[pos+2] = 0; buf[pos+3] = 1; pos += 4;
    return pos;
}

fn parseResponse(resp: []const u8) ?[4]u8 {
    if (resp.len < 12) return null;
    const ancount = (@as(u16, resp[6]) << 8) | resp[7];
    if (ancount == 0) return null;
    var pos: usize = 12;
    while (pos < resp.len and resp[pos] != 0) {
        if (resp[pos] & 0xC0 == 0xC0) { pos += 2; break; }
        pos += 1 + resp[pos];
    }
    if (pos < resp.len and resp[pos] == 0) pos += 1;
    pos += 4;
    var i: u16 = 0;
    while (i < ancount and pos + 10 < resp.len) : (i += 1) {
        if (resp[pos] & 0xC0 == 0xC0) { pos += 2; } else {
            while (pos < resp.len and resp[pos] != 0) pos += 1 + resp[pos];
            pos += 1;
        }
        if (pos + 10 > resp.len) return null;
        const rtype = (@as(u16, resp[pos]) << 8) | resp[pos + 1];
        const rdlen = (@as(u16, resp[pos + 8]) << 8) | resp[pos + 9];
        pos += 10;
        if (rtype == 1 and rdlen == 4 and pos + 4 <= resp.len)
            return .{ resp[pos], resp[pos+1], resp[pos+2], resp[pos+3] };
        pos += rdlen;
    }
    return null;
}
