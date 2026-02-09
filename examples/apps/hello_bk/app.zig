//! Hello BK7258 — WiFi + DNS Test (using hal-compatible drivers)
//!
//! Uses impl.WifiDriver and impl.NetDriver with proper event loop.

const bk = @import("bk");
const armino = bk.armino;
const board = bk.boards.bk7258;

const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";

/// Zig entry point
export fn zig_main() void {
    armino.log.info("ZIG", "========================================");
    armino.log.info("ZIG", "=== BK7258 WiFi + DNS (hal drivers)  ===");
    armino.log.info("ZIG", "========================================");

    // Initialize WiFi driver (hal.wifi compatible)
    var wifi_driver = board.WifiDriver.init() catch {
        armino.log.err("ZIG", "WiFi driver init failed!");
        return;
    };
    defer wifi_driver.deinit();

    // Initialize Net driver (hal.net compatible)
    var net_driver = board.NetDriver.init() catch {
        armino.log.err("ZIG", "Net driver init failed!");
        return;
    };
    defer net_driver.deinit();

    // Connect (non-blocking — results via pollEvent)
    armino.log.logFmt("ZIG", "Connecting to: {s}", .{WIFI_SSID});
    wifi_driver.connect(WIFI_SSID, WIFI_PASSWORD);

    // Event loop — single queue has both wifi and net events
    var got_ip = false;
    var dns_server: [4]u8 = .{ 0, 0, 0, 0 };
    var timeout: u32 = 0;

    while (!got_ip and timeout < 30000) {
        // Poll unified event queue (wifi + net events in one queue)
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
        armino.log.err("ZIG", "WiFi timeout after 30s");
        return;
    }

    // DNS test
    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== DNS Resolution Test (UDP) ===");

    const domains = [_][]const u8{
        "www.google.com",
        "www.baidu.com",
        "github.com",
    };

    for (domains) |domain| {
        const start = armino.time.nowMs();
        if (dnsResolveUdp(domain, dns_server)) |ip| {
            const elapsed = armino.time.nowMs() - start;
            armino.log.logFmt("ZIG", "{s} => {d}.{d}.{d}.{d} ({d}ms)", .{
                domain, ip[0], ip[1], ip[2], ip[3], elapsed,
            });
        } else {
            armino.log.logFmt("ZIG", "{s} => FAILED", .{domain});
        }
    }

    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== All tests done! ===");

    var count: i32 = 0;
    while (true) {
        armino.log.logFmt("ZIG", "alive count={}", .{count});
        count += 1;
        armino.time.sleepMs(5000);
    }
}

// ============================================================================
// Minimal DNS resolver (UDP)
// ============================================================================

fn dnsResolveUdp(domain: []const u8, dns_server: [4]u8) ?[4]u8 {
    const Socket = armino.socket.Socket;

    var sock = Socket.udp() catch return null;
    defer sock.close();
    sock.setRecvTimeout(5000);

    var query_buf: [512]u8 = undefined;
    const query_len = buildDnsQuery(domain, &query_buf) catch return null;

    _ = sock.sendTo(dns_server, 53, query_buf[0..query_len]) catch return null;

    var resp_buf: [512]u8 = undefined;
    const resp_len = sock.recvFrom(&resp_buf) catch return null;

    return parseDnsResponse(resp_buf[0..resp_len]);
}

fn buildDnsQuery(domain: []const u8, buf: []u8) !usize {
    // Header
    buf[0] = 0x12; buf[1] = 0x34;
    buf[2] = 0x01; buf[3] = 0x00;
    buf[4] = 0x00; buf[5] = 0x01;
    buf[6] = 0; buf[7] = 0; buf[8] = 0; buf[9] = 0; buf[10] = 0; buf[11] = 0;

    var pos: usize = 12;
    var start: usize = 0;
    for (domain, 0..) |ch, i| {
        if (ch == '.') {
            const label_len = i - start;
            buf[pos] = @intCast(label_len);
            pos += 1;
            @memcpy(buf[pos..][0..label_len], domain[start..i]);
            pos += label_len;
            start = i + 1;
        }
    }
    const last_len = domain.len - start;
    buf[pos] = @intCast(last_len);
    pos += 1;
    @memcpy(buf[pos..][0..last_len], domain[start..]);
    pos += last_len;
    buf[pos] = 0; pos += 1;
    buf[pos] = 0; buf[pos+1] = 1; buf[pos+2] = 0; buf[pos+3] = 1;
    pos += 4;
    return pos;
}

fn parseDnsResponse(resp: []const u8) ?[4]u8 {
    if (resp.len < 12) return null;
    const ancount = (@as(u16, resp[6]) << 8) | resp[7];
    if (ancount == 0) return null;

    var pos: usize = 12;
    // Skip question
    while (pos < resp.len and resp[pos] != 0) {
        if (resp[pos] & 0xC0 == 0xC0) { pos += 2; break; }
        pos += 1 + resp[pos];
    }
    if (pos < resp.len and resp[pos] == 0) pos += 1;
    pos += 4;

    // Parse answers
    var i: u16 = 0;
    while (i < ancount and pos + 10 < resp.len) : (i += 1) {
        if (resp[pos] & 0xC0 == 0xC0) { pos += 2; } else {
            while (pos < resp.len and resp[pos] != 0) pos += 1 + resp[pos];
            pos += 1;
        }
        if (pos + 10 > resp.len) return null;
        const rtype = (@as(u16, resp[pos]) << 8) | resp[pos + 1];
        const rdlength = (@as(u16, resp[pos + 8]) << 8) | resp[pos + 9];
        pos += 10;
        if (rtype == 1 and rdlength == 4 and pos + 4 <= resp.len) {
            return .{ resp[pos], resp[pos+1], resp[pos+2], resp[pos+3] };
        }
        pos += rdlength;
    }
    return null;
}
