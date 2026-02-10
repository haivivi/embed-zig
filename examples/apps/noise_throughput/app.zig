//! Noise + KCP Resilience Test — ESP32 responder
//!
//! Listens on UDP, performs Noise IK handshake, then uses KCP reliable
//! transport for echo with data integrity verification.
//! Supports WiFi chaos mode: periodic disconnect/reconnect to test KCP resilience.

const std = @import("std");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const crypto_suite = @import("crypto");
const zgrnet = @import("zgrnet");
const kcp_mod = zgrnet.kcp;

const esp_mod = @import("esp");
const IdfSocket = esp_mod.idf.socket.Socket;
const idf_heap = esp_mod.idf.heap;

const EspCryptoChacha = struct {
    pub const Blake2s256 = crypto_suite.Blake2s256;
    pub const ChaCha20Poly1305 = crypto_suite.ChaCha20Poly1305;
    pub const X25519 = crypto_suite.X25519;
    pub const Rng = struct {
        pub fn fill(buf: []u8) void {
            esp_mod.idf.random.fill(buf);
        }
    };
};

const Noise = zgrnet.noise.Protocol(EspCryptoChacha);
const Key = Noise.Key;
const KP = Noise.KeyPair;
const Kcp = kcp_mod.Kcp;
const tag_size = zgrnet.tag_size;
const key_size = zgrnet.key_size;

const listen_port: u16 = 9999;
const max_pkt: usize = 2048;
const allocator = esp_mod.idf.heap.psram;

// WiFi chaos config
const chaos_enabled = false;
const chaos_on_ms: u64 = 3000; // WiFi ON duration
const chaos_off_ms: u64 = 2000; // WiFi OFF duration

fn printMem(label: []const u8) void {
    const internal = idf_heap.heap_caps_get_free_size(idf_heap.MALLOC_CAP_8BIT);
    const psram = idf_heap.heap_caps_get_free_size(idf_heap.MALLOC_CAP_SPIRAM);
    log.info("[mem] {s}: internal={d}KB psram={d}KB", .{ label, internal / 1024, psram / 1024 });
}

// Global state for KCP output callback
var g_send_cs: *Noise.CipherState = undefined;
var g_sock: *IdfSocket = undefined;
var g_peer_addr: esp_mod.idf.socket.Address = undefined;
var g_peer_port: u16 = 0;

fn kcpOutput(data: []const u8, _: ?*anyopaque) void {
    var ct: [max_pkt]u8 = undefined;
    g_send_cs.encrypt(data, "", ct[0 .. data.len + tag_size]);
    _ = g_sock.sendToAddr(g_peer_addr, g_peer_port, ct[0 .. data.len + tag_size]) catch {};
}

pub fn run(env: anytype) void {
    log.info("=== Noise + KCP Resilience Test (Responder) ===", .{});
    if (chaos_enabled) {
        log.info("CHAOS MODE: WiFi {d}ms on / {d}ms off", .{ chaos_on_ms, chaos_off_ms });
    }
    printMem("boot");

    var b: Board = undefined;
    b.init() catch |err| { log.err("Board init: {}", .{err}); return; };
    defer b.deinit();

    log.info("WiFi: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var got_ip = false;
    while (Board.isRunning() and !got_ip) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |we| switch (we) {
                    .connected => log.info("WiFi connected", .{}),
                    .disconnected => |r| {
                        log.warn("WiFi disc: {}", .{r});
                        b.wifi.connect(env.wifi_ssid, env.wifi_password);
                    },
                    else => {},
                },
                .net => |ne| switch (ne) {
                    .dhcp_bound, .dhcp_renewed => |info| {
                        const ip = info.ip;
                        log.info("IP: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
                        got_ip = true;
                    },
                    else => {},
                },
                else => {},
            }
        }
        Board.time.sleepMs(100);
    }
    if (!got_ip) return;

    var sock = IdfSocket.udp() catch |err| { log.err("Socket: {}", .{err}); return; };
    defer sock.close();
    sock.bind(listen_port) catch |err| { log.err("Bind: {}", .{err}); return; };
    log.info("UDP :{d} ready", .{listen_port});
    printMem("pre-handshake");

    while (Board.isRunning()) {
        log.info("Waiting for peer...", .{});
        handlePeer(&sock, &b, env) catch |err| {
            log.err("Peer error: {}. Next...", .{err});
        };
    }
}

fn handlePeer(sock: *IdfSocket, b: *Board, env: anytype) !void {
    // Key exchange
    var pk_buf: [max_pkt]u8 = undefined;
    const pk_result = sock.recvFromAddr(&pk_buf) catch return error.RecvFailed;
    if (pk_result.len != 32) return error.InvalidKeyLength;
    _ = Key.fromBytes(pk_buf[0..32].*);
    const peer_addr = pk_result.addr;
    const peer_port = pk_result.port;
    log.info("Peer: {}.{}.{}.{}:{d}", .{ peer_addr.ipv4[0], peer_addr.ipv4[1], peer_addr.ipv4[2], peer_addr.ipv4[3], peer_port });

    var seed_buf: [32]u8 = undefined;
    EspCryptoChacha.Rng.fill(&seed_buf);
    const local_kp = KP.fromSeed(seed_buf);
    _ = sock.sendToAddr(peer_addr, peer_port, &local_kp.public.data) catch return error.SendFailed;

    // Noise handshake
    var hs = try Noise.HandshakeState.init(.{ .pattern = .IK, .initiator = false, .local_static = local_kp });
    var msg1_buf: [max_pkt]u8 = undefined;
    const msg1_result = sock.recvFromAddr(&msg1_buf) catch return error.RecvFailed;
    var p1: [64]u8 = undefined;
    _ = try hs.readMessage(msg1_buf[0..msg1_result.len], &p1);
    var msg2_buf: [256]u8 = undefined;
    const msg2_len = try hs.writeMessage("", &msg2_buf);
    _ = sock.sendToAddr(peer_addr, peer_port, msg2_buf[0..msg2_len]) catch return error.SendFailed;
    if (!hs.isFinished()) return error.HandshakeNotFinished;

    var send_cs, var recv_cs = try hs.split();
    log.info("Handshake OK!", .{});
    printMem("post-handshake");

    // KCP setup
    g_send_cs = &send_cs;
    g_sock = sock;
    g_peer_addr = peer_addr;
    g_peer_port = peer_port;

    var kcp_inst = Kcp.create(allocator, 1, kcpOutput, null) catch return error.KcpCreateFailed;
    defer {
        kcp_inst.deinit();
        allocator.destroy(kcp_inst);
    }
    kcp_inst.setDefaultConfig();

    log.info("KCP echo loop...", .{});
    printMem("kcp-ready");

    sock.setRecvTimeout(10);

    var total_bytes: usize = 0;
    var total_packets: usize = 0;
    var disconnect_count: u32 = 0;
    const start = Board.time.getTimeMs();

    // Chaos state
    var wifi_is_on = true;
    var chaos_next_toggle = start + chaos_on_ms;

    while (Board.isRunning()) {
        const now = Board.time.getTimeMs();
        kcp_inst.update(@intCast(now & 0xFFFFFFFF));

        // WiFi chaos: periodic disconnect/reconnect
        if (chaos_enabled and now >= chaos_next_toggle) {
            if (wifi_is_on) {
                // Disconnect WiFi
                b.wifi.disconnect();
                wifi_is_on = false;
                disconnect_count += 1;
                chaos_next_toggle = now + chaos_off_ms;
                log.warn("[chaos] WiFi OFF (#{d})", .{disconnect_count});
            } else {
                // Reconnect WiFi
                b.wifi.connect(env.wifi_ssid, env.wifi_password);
                wifi_is_on = true;
                chaos_next_toggle = now + chaos_on_ms;
                log.info("[chaos] WiFi ON", .{});
            }
        }

        // Drain WiFi events (handle reconnect)
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |we| switch (we) {
                    .connected => log.info("WiFi reconnected", .{}),
                    .disconnected => {},
                    else => {},
                },
                .net => |ne| switch (ne) {
                    .dhcp_bound, .dhcp_renewed => |info| {
                        const ip = info.ip;
                        log.info("IP restored: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
                    },
                    else => {},
                },
                else => {},
            }
        }

        // UDP recv → Noise decrypt → KCP input
        var udp_buf: [max_pkt]u8 = undefined;
        const udp_len = sock.recvFrom(&udp_buf) catch |err| {
            if (err == error.Timeout) {
                // Session end: 10s no data after first packet
                if (total_packets > 0 and (now - start) > 10000) {
                    const elapsed = now - start;
                    const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
                    log.info("Session done: {d} pkts, {d} KB/s, {d} disconnects", .{ total_packets, kbps, disconnect_count });
                    printMem("done");
                    return;
                }
                continue;
            }
            continue; // Ignore other errors during chaos
        };

        if (udp_len > tag_size) {
            var pt: [max_pkt]u8 = undefined;
            recv_cs.decrypt(udp_buf[0..udp_len], "", pt[0 .. udp_len - tag_size]) catch continue;
            _ = kcp_inst.input(pt[0 .. udp_len - tag_size]);
        }

        // KCP recv → echo back
        var recv_buf: [max_pkt]u8 = undefined;
        while (true) {
            const kcp_len = kcp_inst.recv(&recv_buf);
            if (kcp_len <= 0) break;
            _ = kcp_inst.send(recv_buf[0..@intCast(kcp_len)]);
            total_bytes += @intCast(kcp_len);
            total_packets += 1;
        }

        if (total_packets > 0 and total_packets % 50 == 0) {
            const elapsed = now - start;
            const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
            log.info("{d} pkts, {d} KB/s, disc={d}", .{ total_packets, kbps, disconnect_count });
        }
    }
}
