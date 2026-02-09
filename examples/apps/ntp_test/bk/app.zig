//! NTP Test — BK7258
//!
//! Connects to WiFi, queries NTP servers for time.

const bk = @import("bk");
const armino = bk.armino;

const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";

const ntp_servers = [_]struct { name: []const u8, ip: [4]u8 }{
    .{ .name = "ntp.aliyun.com", .ip = .{ 203, 107, 6, 88 } },
    .{ .name = "time.google.com", .ip = .{ 216, 239, 35, 0 } },
    .{ .name = "pool.ntp.org", .ip = .{ 162, 159, 200, 1 } },
};

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "       NTP Test (BK7258)");
    armino.log.info("ZIG", "==========================================");

    armino.wifi.init() catch return;

    var ssid_buf: [33:0]u8 = @splat(0);
    var pass_buf: [65:0]u8 = @splat(0);
    @memcpy(ssid_buf[0..WIFI_SSID.len], WIFI_SSID);
    @memcpy(pass_buf[0..WIFI_PASSWORD.len], WIFI_PASSWORD);
    armino.wifi.connect(&ssid_buf, &pass_buf) catch return;

    // Wait for IP
    var timeout: u32 = 0;
    var got_ip = false;
    while (!got_ip and timeout < 30000) {
        while (armino.wifi.popEvent()) |ev| {
            switch (ev) {
                .got_ip => { got_ip = true; },
                else => {},
            }
        }
        armino.time.sleepMs(100);
        timeout += 100;
    }
    if (!got_ip) { armino.log.err("ZIG", "WiFi timeout"); return; }

    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== NTP Queries ===");

    for (ntp_servers) |srv| {
        const start = armino.time.nowMs();
        if (ntpQuery(srv.ip)) |ts| {
            const dur = armino.time.nowMs() - start;
            armino.log.logFmt("ZIG", "{s} => epoch={d} ({d}ms)", .{ srv.name, ts, dur });
        } else {
            armino.log.logFmt("ZIG", "{s} => FAILED", .{srv.name});
        }
    }

    armino.log.info("ZIG", "=== NTP Test Done ===");
    while (true) { armino.time.sleepMs(10000); }
}

fn ntpQuery(server: [4]u8) ?u64 {
    const Socket = armino.socket.Socket;
    var sock = Socket.udp() catch return null;
    defer sock.close();
    sock.setRecvTimeout(5000);

    // NTP request (48 bytes, LI=0, VN=4, Mode=3)
    var req: [48]u8 = @splat(0);
    req[0] = 0x23; // LI=0, VN=4, Mode=3

    _ = sock.sendTo(server, 123, &req) catch return null;

    var resp: [48]u8 = undefined;
    _ = sock.recvFrom(&resp) catch return null;

    // Extract transmit timestamp (seconds since 1900-01-01)
    const ntp_secs = @as(u64, resp[40]) << 24 |
        @as(u64, resp[41]) << 16 |
        @as(u64, resp[42]) << 8 |
        @as(u64, resp[43]);

    // Convert to Unix epoch (subtract 70 years in seconds)
    if (ntp_secs > 2208988800) {
        return ntp_secs - 2208988800;
    }
    return ntp_secs;
}
