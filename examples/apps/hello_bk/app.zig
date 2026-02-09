//! Hello BK7258 — WiFi + DNS Test
//!
//! Connects to WiFi, gets IP via DHCP, resolves DNS names.

const bk = @import("bk");
const armino = bk.armino;
const board = bk.boards.bk7258;

const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";

/// Zig entry point — called from Armino cp_main.c
export fn zig_main() void {
    armino.log.info("ZIG", "========================================");
    armino.log.info("ZIG", "=== BK7258 WiFi + DNS Test           ===");
    armino.log.info("ZIG", "========================================");

    // Initialize WiFi event system
    armino.log.info("ZIG", "Registering WiFi events...");
    armino.wifi.init() catch {
        armino.log.err("ZIG", "WiFi init failed!");
        return;
    };

    // Connect to WiFi
    armino.log.logFmt("ZIG", "Connecting to: {s}", .{WIFI_SSID});
    armino.wifi.connect(WIFI_SSID, WIFI_PASSWORD) catch {
        armino.log.err("ZIG", "WiFi connect failed!");
        return;
    };

    // Wait for connection + IP
    armino.log.info("ZIG", "Waiting for WiFi events...");
    var got_ip = false;
    var timeout: u32 = 0;

    while (!got_ip and timeout < 30000) {
        while (armino.wifi.popEvent()) |event| {
            switch (event) {
                .connected => armino.log.info("ZIG", "WiFi connected! Waiting for IP..."),
                .disconnected => armino.log.warn("ZIG", "WiFi disconnected"),
                .got_ip => |ip_info| {
                    armino.log.logFmt("ZIG", "Got IP: {d}.{d}.{d}.{d}", .{
                        ip_info.ip[0], ip_info.ip[1], ip_info.ip[2], ip_info.ip[3],
                    });
                    armino.log.logFmt("ZIG", "DNS: {d}.{d}.{d}.{d}", .{
                        ip_info.dns[0], ip_info.dns[1], ip_info.dns[2], ip_info.dns[3],
                    });
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
        armino.log.err("ZIG", "WiFi connection timeout after 30s");
        return;
    }

    // DNS test — resolve domains using UDP socket
    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== DNS Resolution Test (UDP) ===");

    const domains = [_][]const u8{
        "www.google.com",
        "www.baidu.com",
        "github.com",
    };

    for (domains) |domain| {
        const start = armino.time.nowMs();
        if (dnsResolveUdp(domain)) |ip| {
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

    // Keep alive
    var count: i32 = 0;
    while (true) {
        armino.log.logFmt("ZIG", "alive count={}", .{count});
        count += 1;
        armino.time.sleepMs(5000);
    }
}

// ============================================================================
// Minimal DNS resolver (UDP, single query, no lib/pkg/dns needed)
// ============================================================================

fn dnsResolveUdp(domain: []const u8) ?[4]u8 {
    const Socket = armino.socket.Socket;

    // Create UDP socket
    var sock = Socket.udp() catch return null;
    defer sock.close();

    sock.setRecvTimeout(5000);

    // Build DNS query (simplified)
    var query_buf: [512]u8 = undefined;
    const query_len = buildDnsQuery(domain, &query_buf) catch return null;

    // Send to AliDNS (223.5.5.5:53)
    const dns_server = [4]u8{ 223, 5, 5, 5 };
    _ = sock.sendTo(dns_server, 53, query_buf[0..query_len]) catch return null;

    // Receive response
    var resp_buf: [512]u8 = undefined;
    const resp_len = sock.recvFrom(&resp_buf) catch return null;

    // Parse A record from response
    return parseDnsResponse(resp_buf[0..resp_len]);
}

fn buildDnsQuery(domain: []const u8, buf: []u8) !usize {
    if (buf.len < 512) return error.BufferTooSmall;

    // Header: ID=0x1234, flags=0x0100 (standard query), QDCOUNT=1
    buf[0] = 0x12;
    buf[1] = 0x34; // ID
    buf[2] = 0x01;
    buf[3] = 0x00; // Flags: standard query, recursion desired
    buf[4] = 0x00;
    buf[5] = 0x01; // QDCOUNT = 1
    buf[6] = 0x00;
    buf[7] = 0x00; // ANCOUNT = 0
    buf[8] = 0x00;
    buf[9] = 0x00; // NSCOUNT = 0
    buf[10] = 0x00;
    buf[11] = 0x00; // ARCOUNT = 0

    // Question: encode domain name
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
    // Last label
    const last_len = domain.len - start;
    buf[pos] = @intCast(last_len);
    pos += 1;
    @memcpy(buf[pos..][0..last_len], domain[start..]);
    pos += last_len;
    buf[pos] = 0; // null terminator
    pos += 1;

    // QTYPE = A (1), QCLASS = IN (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01; // Type A
    buf[pos + 2] = 0x00;
    buf[pos + 3] = 0x01; // Class IN
    pos += 4;

    return pos;
}

fn parseDnsResponse(resp: []const u8) ?[4]u8 {
    if (resp.len < 12) return null;

    // Check ANCOUNT > 0
    const ancount = (@as(u16, resp[6]) << 8) | resp[7];
    if (ancount == 0) return null;

    // Skip header (12 bytes) + question section
    var pos: usize = 12;

    // Skip question: name + QTYPE(2) + QCLASS(2)
    while (pos < resp.len and resp[pos] != 0) {
        if (resp[pos] & 0xC0 == 0xC0) {
            pos += 2; // pointer
            break;
        }
        pos += 1 + resp[pos]; // label
    }
    if (pos < resp.len and resp[pos] == 0) pos += 1; // null terminator
    pos += 4; // QTYPE + QCLASS

    // Parse answers
    var i: u16 = 0;
    while (i < ancount and pos + 10 < resp.len) : (i += 1) {
        // Name (may be pointer)
        if (resp[pos] & 0xC0 == 0xC0) {
            pos += 2;
        } else {
            while (pos < resp.len and resp[pos] != 0) pos += 1 + resp[pos];
            pos += 1;
        }

        if (pos + 10 > resp.len) return null;

        const rtype = (@as(u16, resp[pos]) << 8) | resp[pos + 1];
        const rdlength = (@as(u16, resp[pos + 8]) << 8) | resp[pos + 9];
        pos += 10;

        if (rtype == 1 and rdlength == 4 and pos + 4 <= resp.len) {
            return .{ resp[pos], resp[pos + 1], resp[pos + 2], resp[pos + 3] };
        }

        pos += rdlength;
    }

    return null;
}
