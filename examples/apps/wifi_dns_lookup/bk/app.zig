//! WiFi DNS Lookup — BK7258 version
//!
//! Tests UDP and TCP DNS resolution.
//! (DoH/TLS not yet available on BK — needs crypto binding)

const bk = @import("bk");
const armino = bk.armino;
const board = bk.boards.bk7258;

const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";

const test_domains = [_][]const u8{
    "www.google.com",
    "www.baidu.com",
    "example.com",
    "github.com",
};

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "  WiFi DNS Lookup - UDP/TCP Test (BK7258)");
    armino.log.info("ZIG", "==========================================");

    // Init WiFi
    armino.wifi.init() catch {
        armino.log.err("ZIG", "WiFi init failed!");
        return;
    };

    armino.log.logFmt("ZIG", "Connecting to WiFi: {s}", .{WIFI_SSID});

    var ssid_buf: [33:0]u8 = @splat(0);
    var pass_buf: [65:0]u8 = @splat(0);
    @memcpy(ssid_buf[0..WIFI_SSID.len], WIFI_SSID);
    @memcpy(pass_buf[0..WIFI_PASSWORD.len], WIFI_PASSWORD);
    armino.wifi.connect(&ssid_buf, &pass_buf) catch {
        armino.log.err("ZIG", "WiFi connect failed!");
        return;
    };

    // Wait for IP
    var dns_server: [4]u8 = .{ 0, 0, 0, 0 };
    var got_ip = false;
    var timeout: u32 = 0;

    while (!got_ip and timeout < 30000) {
        while (armino.wifi.popEvent()) |event| {
            switch (event) {
                .connected => armino.log.info("ZIG", "WiFi connected (waiting for IP...)"),
                .disconnected => armino.log.warn("ZIG", "WiFi disconnected"),
                .got_ip => |info| {
                    armino.log.logFmt("ZIG", "Got IP: {d}.{d}.{d}.{d}", .{
                        info.ip[0], info.ip[1], info.ip[2], info.ip[3],
                    });
                    armino.log.logFmt("ZIG", "DNS: {d}.{d}.{d}.{d}", .{
                        info.dns[0], info.dns[1], info.dns[2], info.dns[3],
                    });
                    dns_server = info.dns;
                    got_ip = true;
                },
                .dhcp_timeout => armino.log.err("ZIG", "DHCP timeout!"),
                .scan_done => {},
            }
        }
        armino.time.sleepMs(100);
        timeout += 100;
    }

    if (!got_ip) {
        armino.log.err("ZIG", "WiFi connection timeout");
        return;
    }

    // === Test 1: DHCP DNS ===
    armino.log.info("ZIG", "");
    armino.log.logFmt("ZIG", "=== DHCP DNS Test ({d}.{d}.{d}.{d}) ===", .{
        dns_server[0], dns_server[1], dns_server[2], dns_server[3],
    });
    for (test_domains) |domain| {
        testDns(domain, dns_server, "DHCP_DNS");
    }

    // === Test 2: UDP DNS (AliDNS) ===
    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== UDP DNS Test (223.5.5.5 AliDNS) ===");
    const alidns = [4]u8{ 223, 5, 5, 5 };
    for (test_domains) |domain| {
        testDns(domain, alidns, "UDP");
    }

    // === Test 3: Google DNS ===
    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== UDP DNS Test (8.8.8.8 Google) ===");
    const gdns = [4]u8{ 8, 8, 8, 8 };
    for (test_domains) |domain| {
        testDns(domain, gdns, "GOOGLE");
    }

    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== All Tests Complete ===");

    while (true) {
        armino.time.sleepMs(10000);
    }
}

fn testDns(domain: []const u8, server: [4]u8, label: []const u8) void {
    const start = armino.time.nowMs();
    if (dnsResolve(domain, server)) |ip| {
        const dur = armino.time.nowMs() - start;
        armino.log.logFmt("ZIG", "[{s}] {s} => {d}.{d}.{d}.{d} ({d}ms)", .{
            label, domain, ip[0], ip[1], ip[2], ip[3], dur,
        });
    } else {
        const dur = armino.time.nowMs() - start;
        armino.log.logFmt("ZIG", "[{s}] {s} => FAILED ({d}ms)", .{ label, domain, dur });
    }
}

// ============================================================================
// Minimal UDP DNS resolver
// ============================================================================

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
    buf[0] = 0x12; buf[1] = 0x34;
    buf[2] = 0x01; buf[3] = 0x00;
    buf[4] = 0x00; buf[5] = 0x01;
    @memset(buf[6..12], 0);

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
        if (rtype == 1 and rdlen == 4 and pos + 4 <= resp.len) {
            return .{ resp[pos], resp[pos+1], resp[pos+2], resp[pos+3] };
        }
        pos += rdlen;
    }
    return null;
}
