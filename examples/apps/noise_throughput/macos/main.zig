//! Noise + KCP Throughput Test — Mac initiator
//!
//! Connects to ESP32 over UDP, performs Noise IK handshake,
//! then uses KCP reliable transport for echo throughput measurement.
//!
//! Usage:
//!   zig build run -- <peer_ip> [port] [total_kb] [rounds]

const std = @import("std");
const posix = std.posix;
const crypto_suite = @import("crypto");
const zgrnet = @import("zgrnet");
const kcp_mod = zgrnet.kcp;

/// Desktop Crypto with all algorithms for both cipher suites.
const DesktopCrypto = struct {
    pub const Blake2s256 = crypto_suite.Blake2s256;
    pub const Sha256 = crypto_suite.Sha256;
    pub const ChaCha20Poly1305 = crypto_suite.ChaCha20Poly1305;
    pub const Aes256Gcm = crypto_suite.Aes256Gcm;
    pub const X25519 = crypto_suite.X25519;
    pub const Rng = crypto_suite.Rng;
};

const Noise = zgrnet.noise.Protocol(DesktopCrypto);
const Key = Noise.Key;
const KP = Noise.KeyPair;
const tag_size = zgrnet.tag_size;
const key_size = zgrnet.key_size;
const Kcp = kcp_mod.Kcp;

const default_port: u16 = 9999;
const default_total_kb: usize = 256;
const default_rounds: usize = 3;
const max_pkt: usize = 2048;

// Global state for KCP output callback
var g_sock: posix.socket_t = undefined;
var g_dest_addr: *const posix.sockaddr = undefined;
var g_dest_len: posix.socklen_t = undefined;
var g_send_cs: *Noise.CipherState = undefined;
var g_mutex: std.Thread.Mutex = .{};

fn kcpOutput(data: []const u8, _: ?*anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    // Noise encrypt + UDP send
    var ct: [max_pkt]u8 = undefined;
    g_send_cs.encrypt(data, "", ct[0 .. data.len + tag_size]);
    _ = posix.sendto(g_sock, ct[0 .. data.len + tag_size], 0, g_dest_addr, g_dest_len) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: noise_throughput <peer_ip> [port] [total_kb] [rounds]\n", .{});
        return;
    }

    const peer_ip = args[1];
    const port = if (args.len > 2) std.fmt.parseInt(u16, args[2], 10) catch default_port else default_port;
    const total_kb = if (args.len > 3) std.fmt.parseInt(usize, args[3], 10) catch default_total_kb else default_total_kb;
    const rounds = if (args.len > 4) std.fmt.parseInt(usize, args[4], 10) catch default_rounds else default_rounds;
    const total_bytes = total_kb * 1024;

    std.debug.print("\n=== Noise + KCP Throughput Test (Initiator) ===\n", .{});
    std.debug.print("Peer: {s}:{d}, Data: {d}KB x {d} rounds\n\n", .{ peer_ip, port, total_kb, rounds });

    // Generate keypair
    var seed: [32]u8 = undefined;
    DesktopCrypto.Rng.fill(&seed);
    const local_kp = KP.fromSeed(seed);
    std.debug.print("Local key: {s}...\n", .{&local_kp.public.shortHex()});

    // UDP socket
    const peer_addr = try std.net.Address.parseIp4(peer_ip, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    const timeout = posix.timeval{ .sec = 5, .usec = 0 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    const buf_size: u32 = 256 * 1024;
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&buf_size));
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&buf_size));

    const dest_addr: *const posix.sockaddr = @ptrCast(&peer_addr.any);
    const dest_len = peer_addr.getOsSockLen();

    // === Phase 1: Key exchange ===
    std.debug.print("Key exchange...\n", .{});
    _ = try posix.sendto(sock, &local_kp.public.data, 0, dest_addr, dest_len);

    var peer_pk_buf: [32]u8 = undefined;
    const pk_len = posix.recvfrom(sock, &peer_pk_buf, 0, null, null) catch {
        std.debug.print("ERROR: No response. Is responder running?\n", .{});
        return;
    };
    if (pk_len != 32) { std.debug.print("ERROR: Bad key len\n", .{}); return; }
    const peer_pk = Key.fromBytes(peer_pk_buf);
    std.debug.print("Peer key: {s}...\n", .{&peer_pk.shortHex()});

    // === Phase 2: Noise IK Handshake ===
    std.debug.print("Noise IK handshake...\n", .{});
    var hs = Noise.HandshakeState.init(.{
        .pattern = .IK,
        .initiator = true,
        .local_static = local_kp,
        .remote_static = peer_pk,
    }) catch { std.debug.print("ERROR: HS init\n", .{}); return; };

    var msg1_buf: [256]u8 = undefined;
    const msg1_len = hs.writeMessage("", &msg1_buf) catch { std.debug.print("ERROR: HS write\n", .{}); return; };
    _ = try posix.sendto(sock, msg1_buf[0..msg1_len], 0, dest_addr, dest_len);

    var msg2_buf: [256]u8 = undefined;
    const msg2_len = posix.recvfrom(sock, &msg2_buf, 0, null, null) catch { std.debug.print("ERROR: HS recv\n", .{}); return; };
    var payload_buf: [64]u8 = undefined;
    _ = hs.readMessage(msg2_buf[0..msg2_len], &payload_buf) catch { std.debug.print("ERROR: HS read\n", .{}); return; };

    if (!hs.isFinished()) { std.debug.print("ERROR: HS not done\n", .{}); return; }
    var send_cs, var recv_cs = hs.split() catch { std.debug.print("ERROR: split\n", .{}); return; };
    std.debug.print("Handshake OK!\n\n", .{});

    // === Phase 3: KCP setup ===
    g_sock = sock;
    g_dest_addr = dest_addr;
    g_dest_len = dest_len;
    g_send_cs = &send_cs;

    var kcp_inst = try Kcp.create(allocator, 1, kcpOutput, null);
    defer {
        kcp_inst.deinit();
        allocator.destroy(kcp_inst);
    }
    kcp_inst.setDefaultConfig();

    // Set short recv timeout for KCP loop (1ms for fast KCP updates)
    const short_timeout = posix.timeval{ .sec = 0, .usec = 1_000 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&short_timeout));

    // === Phase 4: KCP Echo Throughput ===
    const chunk_size: usize = 1024;
    var plaintext: [chunk_size]u8 = undefined;
    for (&plaintext, 0..) |*b, i| b.* = @intCast(i % 256);

    var total_throughput: u64 = 0;

    for (0..rounds) |round| {
        std.debug.print("Round {d}/{d}: {d}KB via KCP...\n", .{ round + 1, rounds, total_kb });

        var bytes_sent: usize = 0;
        var bytes_recv: usize = 0;
        const start = std.time.milliTimestamp();
        var last_update: i64 = start;

        while (bytes_recv < total_bytes) {
            const now = std.time.milliTimestamp();

            // KCP update
            if (now - last_update >= 1) {
                kcp_inst.update(@intCast(@as(u64, @intCast(now)) & 0xFFFFFFFF));
                last_update = now;
            }

            // Send 1 chunk per iteration (interleave with recv for flow control)
            if (bytes_sent < total_bytes and kcp_inst.waitSnd() < 128) {
                const ret = kcp_inst.send(&plaintext);
                if (ret >= 0) bytes_sent += chunk_size;
            }

            // Drain all pending UDP packets + decrypt + KCP input
            while (true) {
                var udp_buf: [max_pkt]u8 = undefined;
                const udp_len = posix.recvfrom(sock, &udp_buf, 0, null, null) catch break;
                if (udp_len > tag_size) {
                    var pt: [max_pkt]u8 = undefined;
                    recv_cs.decrypt(udp_buf[0..udp_len], "", pt[0 .. udp_len - tag_size]) catch continue;
                    _ = kcp_inst.input(pt[0 .. udp_len - tag_size]);
                }
            }

            // Drain all KCP recv
            while (true) {
                var recv_buf: [chunk_size]u8 = undefined;
                const kcp_len = kcp_inst.recv(&recv_buf);
                if (kcp_len <= 0) break;
                bytes_recv += @intCast(kcp_len);
            }

            // Timeout check
            if (now - start > 30000) {
                std.debug.print("  TIMEOUT after 30s\n", .{});
                break;
            }
        }

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
        const throughput = if (elapsed > 0) ((bytes_sent + bytes_recv) * 1000) / elapsed / 1024 else 0;
        std.debug.print("  Sent: {d}KB, Recv: {d}KB, Time: {d}ms, Throughput: {d} KB/s\n", .{
            bytes_sent / 1024, bytes_recv / 1024, elapsed, throughput,
        });
        total_throughput += throughput;
    }

    std.debug.print("\nAverage: {d} KB/s\n", .{total_throughput / rounds});
    std.debug.print("=== Done ===\n\n", .{});
}
