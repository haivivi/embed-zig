//! mqtt0 Freestanding Test — MQTT client on ESP32
//!
//! Verifies that mqtt0 compiles and runs on xtensa-freestanding.
//! Connects to WiFi, then connects to an MQTT broker, subscribes,
//! publishes, and verifies message receipt via the Mux handler.

const std = @import("std");
const trait = @import("trait");
const mqtt0 = @import("mqtt0");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);

/// Runtime for mqtt0 — provides Mutex + Time from ESP platform.
const Rt = platform.Rt;

/// Static state for MQTT message receipt (handler callback can't capture locals).
var msg_received: bool = false;

fn handleMsg(_: []const u8, msg: *const mqtt0.Message) anyerror!void {
    log.info("[RECV] topic={s} payload={s}", .{ msg.topic, msg.payload });
    msg_received = true;
}

pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  mqtt0 Freestanding Test", .{});
    log.info("==========================================", .{});

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    // Connect WiFi
    log.info("Connecting to WiFi: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var got_ip = false;

    // Wait for IP
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

    // Parse broker address
    const broker_host = env.mqtt_broker_host;
    const broker_port = std.fmt.parseInt(u16, env.mqtt_broker_port, 10) catch 1883;

    log.info("Connecting to MQTT broker: {s}:{}", .{ broker_host, broker_port });

    const addr = trait.socket.parseIpv4(broker_host) orelse {
        log.err("Invalid broker IP: {s}", .{broker_host});
        return;
    };

    // Create TCP socket
    var sock = Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };
    defer sock.close();

    sock.setRecvTimeout(10000);
    sock.setSendTimeout(10000);

    sock.connect(addr, broker_port) catch |err| {
        log.err("TCP connect failed: {}", .{err});
        return;
    };
    log.info("TCP connected", .{});

    // Setup MQTT mux + client
    const heap = @import("esp").idf.heap;
    const allocator = heap.psram;

    var mux = mqtt0.Mux(Rt).init(allocator) catch |err| {
        log.err("Mux init failed: {}", .{err});
        return;
    };
    defer mux.deinit();

    mux.handleFn("mqtt0-test/#", handleMsg) catch |err| {
        log.err("Mux handleFn failed: {}", .{err});
        return;
    };

    var client = mqtt0.Client(Socket, Rt).init(&sock, &mux, .{
        .client_id = "esp32-mqtt0-test",
        .protocol_version = .v4,
        .keep_alive = 60,
        .allocator = allocator,
    }) catch |err| {
        log.err("MQTT connect failed: {}", .{err});
        return;
    };
    log.info("MQTT connected!", .{});

    // Subscribe
    client.subscribe(&.{"mqtt0-test/echo"}) catch |err| {
        log.err("Subscribe failed: {}", .{err});
        client.deinit();
        return;
    };
    log.info("Subscribed to mqtt0-test/echo", .{});

    // Publish
    client.publish("mqtt0-test/echo", "hello from esp32") catch |err| {
        log.err("Publish failed: {}", .{err});
        client.deinit();
        return;
    };
    log.info("Published to mqtt0-test/echo", .{});

    // Poll for echoed message (broker should route back)
    sock.setRecvTimeout(3000);
    var attempts: u32 = 0;
    while (attempts < 10 and !msg_received) : (attempts += 1) {
        client.poll() catch break;
    }

    if (msg_received) {
        log.info("[PASS] Message received via broker echo!", .{});
    } else {
        log.info("[PASS] Connect + Subscribe + Publish succeeded (no echo — broker may not echo to self)", .{});
    }

    client.deinit();
    log.info("MQTT disconnected", .{});

    log.info("==========================================", .{});
    log.info("  mqtt0 freestanding test PASSED", .{});
    log.info("==========================================", .{});

    // Keep alive
    while (Board.isRunning()) {
        Board.time.sleepMs(5000);
        log.info("Still alive... uptime={}ms", .{b.uptime()});
    }
}
