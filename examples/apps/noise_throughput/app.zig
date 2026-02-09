//! Noise + KCP Throughput Test — ESP32 responder
//!
//! Listens on UDP, performs Noise IK handshake, then uses KCP reliable
//! transport for echo throughput measurement with memory monitoring.

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

/// ESP32-specific Crypto with hardware RNG.
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

/// PSRAM allocator for KCP
const allocator = esp_mod.idf.heap.psram;

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
    log.info("=== Noise + KCP Throughput (Responder) ===", .{});
    printMem("boot");

    // Init board + WiFi
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
                    .disconnected => |r| { log.warn("WiFi disc: {}", .{r}); b.wifi.connect(env.wifi_ssid, env.wifi_password); },
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

    // UDP socket
    var sock = IdfSocket.udp() catch |err| { log.err("Socket: {}", .{err}); return; };
    defer sock.close();
    sock.bind(listen_port) catch |err| { log.err("Bind: {}", .{err}); return; };
    log.info("UDP :{d} ready", .{listen_port});
    printMem("pre-handshake");

    while (Board.isRunning()) {
        log.info("Waiting for peer...", .{});
        handlePeer(&sock) catch |err| {
            log.err("Peer error: {}. Next...", .{err});
        };
    }
}

fn handlePeer(sock: *IdfSocket) !void {
    // Key exchange
    var pk_buf: [max_pkt]u8 = undefined;
    const pk_result = sock.recvFromAddr(&pk_buf) catch return error.RecvFailed;
    if (pk_result.len != 32) return error.InvalidKeyLength;
    _ = Key.fromBytes(pk_buf[0..32].*); // peer_pk received but not needed (handshake gets it)
    const peer_addr = pk_result.addr;
    const peer_port = pk_result.port;
    log.info("Peer: {}.{}.{}.{}:{d}", .{ peer_addr.ipv4[0], peer_addr.ipv4[1], peer_addr.ipv4[2], peer_addr.ipv4[3], peer_port });

    // Generate keypair
    var seed: [32]u8 = undefined;
    EspCryptoChacha.Rng.fill(&seed);
    const local_kp = KP.fromSeed(seed);
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

    // Set short recv timeout (10ms)
    sock.setRecvTimeout(10);

    var total_bytes: usize = 0;
    var total_packets: usize = 0;
    const start = Board.time.getTimeMs();

    while (Board.isRunning()) {
        const now = Board.time.getTimeMs();
        kcp_inst.update(@intCast(now & 0xFFFFFFFF));

        // UDP recv -> Noise decrypt -> KCP input
        var udp_buf: [max_pkt]u8 = undefined;
        const udp_len = sock.recvFrom(&udp_buf) catch |err| {
            if (err == error.Timeout) {
                // Check for session end
                if (total_packets > 0 and (Board.time.getTimeMs() - start) > 5000) {
                    const elapsed = Board.time.getTimeMs() - start;
                    const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
                    log.info("Session done: {d} pkts, {d} KB/s", .{ total_packets, kbps });
                    printMem("done");
                    return;
                }
                continue;
            }
            return error.RecvFailed;
        };

        if (udp_len > tag_size) {
            var pt: [max_pkt]u8 = undefined;
            recv_cs.decrypt(udp_buf[0..udp_len], "", pt[0 .. udp_len - tag_size]) catch continue;
            _ = kcp_inst.input(pt[0 .. udp_len - tag_size]);
        }

        // KCP recv -> echo back via KCP send
        var recv_buf: [max_pkt]u8 = undefined;
        while (true) {
            const kcp_len = kcp_inst.recv(&recv_buf);
            if (kcp_len <= 0) break;
            _ = kcp_inst.send(recv_buf[0..@intCast(kcp_len)]);
            total_bytes += @intCast(kcp_len);
            total_packets += 1;
        }

        if (total_packets > 0 and total_packets % 100 == 0) {
            const elapsed = Board.time.getTimeMs() - start;
            const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
            log.info("{d} pkts, {d} KB/s", .{ total_packets, kbps });
        }
    }
}
