//! Net Event Test — BK7258
//!
//! Tests WiFi + Net event chain:
//! Phase 1: Connect → wifi.connected + got_ip
//! Phase 2: Disconnect → wifi.disconnected
//! Phase 3: Reconnect → wifi.connected + got_ip

const bk = @import("bk");
const armino = bk.armino;

const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";
const TIMEOUT_MS: u32 = 30000;

const TestResult = enum { pending, pass, fail };

fn symbol(r: TestResult) []const u8 {
    return switch (r) {
        .pending => "...",
        .pass => "PASS",
        .fail => "FAIL",
    };
}

fn connectAndWaitIp() struct { ok: bool, ip: [4]u8, dns: [4]u8 } {
    var ssid_buf: [33:0]u8 = @splat(0);
    var pass_buf: [65:0]u8 = @splat(0);
    @memcpy(ssid_buf[0..WIFI_SSID.len], WIFI_SSID);
    @memcpy(pass_buf[0..WIFI_PASSWORD.len], WIFI_PASSWORD);
    armino.wifi.connect(&ssid_buf, &pass_buf) catch return .{ .ok = false, .ip = .{0,0,0,0}, .dns = .{0,0,0,0} };

    var got_connected = false;
    var got_ip = false;
    var ip: [4]u8 = .{0,0,0,0};
    var dns: [4]u8 = .{0,0,0,0};
    var t: u32 = 0;

    while (t < TIMEOUT_MS) {
        while (armino.wifi.popEvent()) |ev| {
            switch (ev) {
                .connected => {
                    armino.log.info("ZIG", "  + wifi.connected");
                    got_connected = true;
                },
                .got_ip => |info| {
                    armino.log.logFmt("ZIG", "  + got_ip: {d}.{d}.{d}.{d}", .{info.ip[0], info.ip[1], info.ip[2], info.ip[3]});
                    ip = info.ip;
                    dns = info.dns;
                    got_ip = true;
                },
                .disconnected => armino.log.warn("ZIG", "  ! disconnected"),
                .dhcp_timeout => armino.log.err("ZIG", "  ! DHCP timeout"),
                .scan_done => {},
            }
        }
        if (got_connected and got_ip) return .{ .ok = true, .ip = ip, .dns = dns };
        armino.time.sleepMs(100);
        t += 100;
    }
    return .{ .ok = false, .ip = ip, .dns = dns };
}

fn disconnectAndWait() bool {
    armino.wifi.disconnect() catch return false;
    var got_disconnect = false;
    var t: u32 = 0;

    while (t < 10000) {
        while (armino.wifi.popEvent()) |ev| {
            switch (ev) {
                .disconnected => {
                    armino.log.info("ZIG", "  + wifi.disconnected");
                    got_disconnect = true;
                },
                else => {},
            }
        }
        if (got_disconnect) return true;
        armino.time.sleepMs(100);
        t += 100;
    }
    return false;
}

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "       Net Event Test (BK7258)");
    armino.log.info("ZIG", "==========================================");

    armino.wifi.init() catch {
        armino.log.err("ZIG", "WiFi init failed!");
        return;
    };

    var r1: TestResult = .pending;
    var r2: TestResult = .pending;
    var r3: TestResult = .pending;

    // Phase 1: Connect
    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "=== Phase 1: Connect ===");
    armino.log.logFmt("ZIG", "Connecting to {s}...", .{WIFI_SSID});
    const c1 = connectAndWaitIp();
    r1 = if (c1.ok) .pass else .fail;
    armino.log.logFmt("ZIG", "Phase 1: {s}", .{symbol(r1)});

    if (r1 == .pass) {
        armino.time.sleepMs(1000);

        // Phase 2: Disconnect
        armino.log.info("ZIG", "");
        armino.log.info("ZIG", "=== Phase 2: Disconnect ===");
        r2 = if (disconnectAndWait()) .pass else .fail;
        armino.log.logFmt("ZIG", "Phase 2: {s}", .{symbol(r2)});

        armino.time.sleepMs(2000);

        // Phase 3: Reconnect
        armino.log.info("ZIG", "");
        armino.log.info("ZIG", "=== Phase 3: Reconnect ===");
        const c3 = connectAndWaitIp();
        r3 = if (c3.ok) .pass else .fail;
        armino.log.logFmt("ZIG", "Phase 3: {s}", .{symbol(r3)});
    }

    // Report
    armino.log.info("ZIG", "");
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "          TEST SUMMARY");
    armino.log.info("ZIG", "==========================================");
    armino.log.logFmt("ZIG", "Phase 1 (Connect):    {s}", .{symbol(r1)});
    armino.log.logFmt("ZIG", "Phase 2 (Disconnect): {s}", .{symbol(r2)});
    armino.log.logFmt("ZIG", "Phase 3 (Reconnect):  {s}", .{symbol(r3)});
    armino.log.info("ZIG", "==========================================");

    while (true) { armino.time.sleepMs(10000); }
}
