//! TCP Speed Test — BK7258
//!
//! Tests raw TCP throughput: connect to a server and measure transfer speed.
//! Requires a TCP echo/speed server running on the local network.
//! Use: iperf3 -s on your PC, then set TEST_SERVER_IP below.

const bk = @import("bk");
const armino = bk.armino;

const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";

// TCP speed test server (run: iperf3 -s on this machine)
const TEST_SERVER_IP = [4]u8{ 192, 168, 4, 1 }; // Router/gateway
const TEST_PORT: u16 = 5201;

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "       TCP Speed Test (BK7258)");
    armino.log.info("ZIG", "==========================================");

    armino.wifi.init() catch return;
    var ssid_buf: [33:0]u8 = @splat(0);
    var pass_buf: [65:0]u8 = @splat(0);
    @memcpy(ssid_buf[0..WIFI_SSID.len], WIFI_SSID);
    @memcpy(pass_buf[0..WIFI_PASSWORD.len], WIFI_PASSWORD);
    armino.wifi.connect(&ssid_buf, &pass_buf) catch return;

    // Wait for IP
    var timeout: u32 = 0;
    while (timeout < 30000) {
        while (armino.wifi.popEvent()) |ev| {
            switch (ev) { .got_ip => { timeout = 30000; }, else => {} }
        }
        armino.time.sleepMs(100);
        timeout += 100;
    }

    armino.log.info("ZIG", "WiFi connected!");
    armino.log.logFmt("ZIG", "Connecting to {d}.{d}.{d}.{d}:{d}...", .{
        TEST_SERVER_IP[0], TEST_SERVER_IP[1], TEST_SERVER_IP[2], TEST_SERVER_IP[3], TEST_PORT,
    });

    // TCP send test
    const Socket = armino.socket.Socket;
    var sock = Socket.tcp() catch {
        armino.log.err("ZIG", "Socket create failed");
        return;
    };
    defer sock.close();
    sock.setRecvTimeout(5000);
    sock.setSendTimeout(5000);

    sock.connect(TEST_SERVER_IP, TEST_PORT) catch {
        armino.log.err("ZIG", "Connect failed (is iperf3 -s running?)");
        armino.log.info("ZIG", "Skipping TCP test. Done.");
        while (true) { armino.time.sleepMs(10000); }
        return;
    };

    armino.log.info("ZIG", "Connected! Sending data...");

    // Send 64KB of data, measure throughput
    var send_buf: [1024]u8 = undefined;
    @memset(&send_buf, 0xAA);

    const total_bytes: usize = 65536;
    var sent: usize = 0;
    const start = armino.time.nowMs();

    while (sent < total_bytes) {
        const n = sock.send(&send_buf) catch break;
        sent += n;
    }

    const elapsed = armino.time.nowMs() - start;
    const kbps = if (elapsed > 0) sent * 8 / @as(usize, @intCast(elapsed)) else 0;

    armino.log.logFmt("ZIG", "TCP TX: {d} bytes in {d}ms ({d} kbps)", .{ sent, elapsed, kbps });
    armino.log.info("ZIG", "=== TCP Speed Test Done ===");

    while (true) { armino.time.sleepMs(10000); }
}
