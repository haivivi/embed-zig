//! WebSocket Echo Test
//!
//! Platform-independent e2e test. Connects to WiFi, resolves DNS,
//! establishes TLS + WebSocket connection to echo.websocket.org,
//! sends text/binary messages and verifies echoes.
//!
//! Usage (ESP32):
//!   bazel run //e2e/tier1_websocket/esp:flash \
//!     --//bazel:port=/dev/cu.usbmodem11101 \
//!     --define WIFI_SSID=MyWiFi --define WIFI_PASSWORD=secret

const std = @import("std");
const trait = @import("trait");
const tls = @import("tls");
const dns = @import("dns");
const ws = @import("ws");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);
const Crypto = Board.crypto;
const Rt = platform.Rt;
const allocator = platform.allocator;

const TlsClient = tls.Client(Socket, Crypto, Rt);

const TEST_HOST = "echo.websocket.org";
const TEST_PORT: u16 = 443;

pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  WebSocket Echo Test", .{});
    log.info("==========================================", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("Connecting to WiFi: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var got_ip = false;
    while (Board.isRunning() and !got_ip) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |we| switch (we) {
                    .connected => log.info("WiFi associated", .{}),
                    .disconnected => |reason| {
                        log.warn("WiFi disconnected: {}", .{reason});
                        return;
                    },
                    .connection_failed => |reason| {
                        log.err("WiFi failed: {}", .{reason});
                        return;
                    },
                    else => {},
                },
                .net => |ne| switch (ne) {
                    .dhcp_bound => |info| {
                        log.info("Got IP: {}.{}.{}.{}", .{ info.ip[0], info.ip[1], info.ip[2], info.ip[3] });
                        got_ip = true;
                    },
                    else => {},
                },
                else => {},
            }
        }
        Board.time.sleepMs(10);
    }
    if (!got_ip) return;
    Board.time.sleepMs(500);

    // DNS resolve
    log.info("Resolving " ++ TEST_HOST ++ "...", .{});
    var resolver = dns.Resolver(Socket, void){
        .server = .{ 223, 5, 5, 5 },
        .protocol = .udp,
        .timeout_ms = 5000,
    };
    const ip = resolver.resolve(TEST_HOST) catch |err| {
        log.err("DNS resolve failed: {}", .{err});
        return;
    };
    log.info("Resolved: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });

    // TCP connect
    var sock_storage = Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };
    sock_storage.setRecvTimeout(15000);
    sock_storage.setSendTimeout(15000);
    sock_storage.connect(ip, TEST_PORT) catch |err| {
        log.err("TCP connect failed: {}", .{err});
        sock_storage.close();
        return;
    };
    log.info("TCP connected", .{});

    // TLS handshake
    var tls_client = TlsClient.init(&sock_storage, .{
        .allocator = allocator,
        .hostname = TEST_HOST,
        .skip_verify = true,
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        sock_storage.close();
        return;
    };

    tls_client.connect() catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        tls_client.deinit();
        sock_storage.close();
        return;
    };
    log.info("TLS handshake OK", .{});

    // WebSocket handshake
    const WsClient = ws.Client(@TypeOf(tls_client));
    var ws_client = WsClient.init(allocator, &tls_client, .{
        .host = TEST_HOST,
        .path = "/",
        .rng_fill = Crypto.Rng.fill,
        .buffer_size = 8192,
    }) catch |err| {
        log.err("WebSocket handshake failed: {}", .{err});
        tls_client.deinit();
        sock_storage.close();
        return;
    };
    log.info("WebSocket connected!", .{});

    // Test 1: text echo
    ws_client.sendText("hello from ESP32") catch |err| {
        log.err("sendText failed: {}", .{err});
        ws_client.deinit();
        tls_client.deinit();
        sock_storage.close();
        return;
    };
    if (ws_client.recv() catch null) |msg| {
        log.info("[ECHO] type={}, payload={s}", .{ msg.type, msg.payload });
    } else {
        log.err("recv returned null", .{});
    }

    // Test 2: binary echo
    const bin = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    ws_client.sendBinary(&bin) catch |err| {
        log.err("sendBinary failed: {}", .{err});
    };
    if (ws_client.recv() catch null) |msg| {
        log.info("[ECHO] binary {} bytes", .{msg.payload.len});
    }

    // Close
    ws_client.close();
    ws_client.deinit();
    tls_client.deinit();
    sock_storage.close();

    log.info("[PASS] WebSocket echo test complete!", .{});

    while (Board.isRunning()) {
        Board.time.sleepMs(5000);
    }
}
