//! Noise Throughput Test — ESP32 responder
//!
//! Listens on UDP port for Noise IK handshake from Mac peer,
//! then echoes encrypted data for throughput measurement.
//!
//! Protocol:
//! 1. Key exchange: receive peer public key, send ours
//! 2. Noise IK handshake (2 messages)
//! 3. Echo loop: receive encrypted, decrypt, re-encrypt, send back

const std = @import("std");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const crypto_suite = @import("crypto");
const zgrnet = @import("zgrnet");

/// ESP32-specific Crypto with hardware RNG.
/// Uses pure Zig crypto (Blake2s, ChaCha20, X25519) + ESP hardware RNG.
const EspCryptoChacha = struct {
    pub const Blake2s256 = crypto_suite.Blake2s256;
    pub const ChaCha20Poly1305 = crypto_suite.ChaCha20Poly1305;
    pub const X25519 = crypto_suite.X25519;
    pub const Rng = EspRng;
};

/// ESP32-specific Crypto with hardware AES-GCM acceleration.
/// Uses ESP mbedTLS for AES-GCM (HW accel) + pure Zig SHA-256.
const EspCryptoAesGcm = struct {
    pub const Sha256 = crypto_suite.Sha256;
    pub const Aes256Gcm = @import("esp").impl.crypto.Suite.Aes256Gcm;
    pub const X25519 = crypto_suite.X25519;
    pub const Rng = EspRng;
};

const EspRng = struct {
    pub fn fill(buf: []u8) void {
        const esp_mod2 = @import("esp");
        esp_mod2.idf.random.fill(buf);
    }
};

/// Toggle this to switch cipher suites for benchmarking.
const use_aesgcm = false;

const Noise = if (use_aesgcm)
    zgrnet.noise.ProtocolWithSuite(EspCryptoAesGcm, .AESGCM_SHA256)
else
    zgrnet.noise.Protocol(EspCryptoChacha);
const Key = Noise.Key;
const KP = Noise.KeyPair;
const tag_size = zgrnet.tag_size;
const key_size = zgrnet.key_size;

const listen_port: u16 = 9999;
const max_packet: usize = 2048;
/// Chunk size near MTU for optimal UDP throughput.
/// MTU=1500, IP=20, UDP=8, so max UDP payload=1472.
/// Minus 16-byte AEAD tag = 1456 max plaintext.
const default_chunk_size: usize = 1400;

pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  Noise Throughput Test (Responder)", .{});
    log.info("==========================================", .{});

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    // Connect to WiFi
    log.info("Connecting to WiFi...", .{});
    log.info("SSID: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    // Wait for WiFi IP
    var got_ip = false;
    while (Board.isRunning() and !got_ip) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    switch (wifi_event) {
                        .connected => log.info("WiFi connected (waiting for IP...)", .{}),
                        .disconnected => |reason| {
                            log.warn("WiFi disconnected: {}", .{reason});
                            b.wifi.connect(env.wifi_ssid, env.wifi_password);
                        },
                        else => {},
                    }
                },
                .net => |net_event| {
                    switch (net_event) {
                        .dhcp_bound, .dhcp_renewed => |info| {
                            const ip = info.ip;
                            log.info("Got IP: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
                            got_ip = true;
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        Board.time.sleepMs(100);
    }

    if (!got_ip) return;

    // Generate keypair using ESP hardware RNG
    var seed: [32]u8 = undefined;
    EspRng.fill(&seed);
    const local_kp = KP.fromSeed(seed);
    log.info("Local public key: {s}...", .{&local_kp.public.shortHex()});
    log.info("Listening on UDP :{d}", .{listen_port});

    // Create UDP socket
    var sock = esp_mod.idf.socket.Socket.udp() catch |err| {
        log.err("UDP socket failed: {}", .{err});
        return;
    };
    defer sock.close();

    sock.bind(listen_port) catch |err| {
        log.err("Bind failed: {}", .{err});
        return;
    };

    // Main loop — handle peers
    while (Board.isRunning()) {
        log.info("Waiting for peer...", .{});
        handlePeer(&sock, local_kp) catch |err| {
            log.err("Peer session error: {}. Waiting for next...", .{err});
        };
    }
}

const esp_mod = @import("esp");
const IdfSocket = esp_mod.idf.socket.Socket;
const Address = esp_mod.idf.socket.Address;

fn handlePeer(sock: *IdfSocket, local_kp: KP) !void {
    // Phase 1: Key exchange
    var pk_buf: [max_packet]u8 = undefined;
    const pk_result = sock.recvFromAddr(&pk_buf) catch return error.RecvFailed;
    if (pk_result.len != 32) return error.InvalidKeyLength;

    const peer_pk = Key.fromBytes(pk_buf[0..32].*);
    const peer_addr = pk_result.addr;
    const peer_port = pk_result.port;
    log.info("Peer: {}.{}.{}.{}:{d}", .{ peer_addr.ipv4[0], peer_addr.ipv4[1], peer_addr.ipv4[2], peer_addr.ipv4[3], peer_port });
    log.info("Peer public key: {s}...", .{&peer_pk.shortHex()});

    _ = sock.sendToAddr(peer_addr, peer_port, &local_kp.public.data) catch return error.SendFailed;

    // Phase 2: Noise IK Handshake
    log.info("Noise IK handshake...", .{});

    var hs = try Noise.HandshakeState.init(.{
        .pattern = .IK,
        .initiator = false,
        .local_static = local_kp,
    });

    var msg1_buf: [max_packet]u8 = undefined;
    const msg1_result = sock.recvFromAddr(&msg1_buf) catch return error.RecvFailed;

    var payload1: [64]u8 = undefined;
    _ = try hs.readMessage(msg1_buf[0..msg1_result.len], &payload1);

    var msg2_buf: [256]u8 = undefined;
    const msg2_len = try hs.writeMessage("", &msg2_buf);

    _ = sock.sendToAddr(peer_addr, peer_port, msg2_buf[0..msg2_len]) catch return error.SendFailed;

    if (!hs.isFinished()) return error.HandshakeNotFinished;

    var send_cs, var recv_cs = try hs.split();
    log.info("Handshake OK! Echo loop...", .{});

    // Phase 3: Echo loop
    var total_bytes: usize = 0;
    var total_packets: usize = 0;
    const start = Board.time.getTimeMs();

    while (Board.isRunning()) {
        var recv_buf: [max_packet]u8 = undefined;
        const recv_len = sock.recvFrom(&recv_buf) catch |err| {
            if (err == error.Timeout) {
                if (total_packets > 0) {
                    const elapsed = Board.time.getTimeMs() - start;
                    const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
                    log.info("{d} pkts, {d} KB/s", .{ total_packets, kbps });
                    return; // Session done
                }
                continue;
            }
            return error.RecvFailed;
        };

        if (recv_len < tag_size) continue;

        const pt_len = recv_len - tag_size;
        var plaintext: [max_packet]u8 = undefined;
        recv_cs.decrypt(recv_buf[0..recv_len], "", plaintext[0..pt_len]) catch continue;

        var echo_buf: [max_packet]u8 = undefined;
        send_cs.encrypt(plaintext[0..pt_len], "", echo_buf[0 .. pt_len + tag_size]);

        _ = sock.sendToAddr(peer_addr, peer_port, echo_buf[0 .. pt_len + tag_size]) catch continue;

        total_bytes += pt_len;
        total_packets += 1;

        if (total_packets % 100 == 0) {
            const elapsed = Board.time.getTimeMs() - start;
            const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
            log.info("{d} pkts, {d} KB/s", .{ total_packets, kbps });
        }
    }
}
