//! Noise + KCP Throughput Test — Mac initiator
//!
//! Usage:
//!   noise_throughput <ip> [port] [kb] [rounds] [loss%] [loss_mode] [kcp_config]
//!     loss_mode: 0=recv-only (default), 1=bilateral
//!     kcp_config: A=current, B=aggressive, C=max-resilience

const std = @import("std");
const posix = std.posix;
const crypto_suite = @import("crypto");
const zgrnet = @import("zgrnet");
const kcp_mod = zgrnet.kcp;

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
const Kcp = kcp_mod.Kcp;

const default_port: u16 = 9999;
const default_total_kb: usize = 64;
const default_rounds: usize = 1;
const max_pkt: usize = 2048;
const chunk_size: usize = 1024;

// Global state
var g_sock: posix.socket_t = undefined;
var g_dest_addr: *const posix.sockaddr = undefined;
var g_dest_len: posix.socklen_t = undefined;
var g_send_cs: *Noise.CipherState = undefined;
var g_mutex: std.Thread.Mutex = .{};
var g_loss_pct: u8 = 0;
var g_loss_bilateral: bool = false; // false = recv-only (default)
var g_pkts_sent: u64 = 0;
var g_pkts_dropped_send: u64 = 0;
var g_pkts_dropped_recv: u64 = 0;

fn shouldDrop() bool {
    if (g_loss_pct == 0) return false;
    var rng_buf: [1]u8 = undefined;
    std.crypto.random.bytes(&rng_buf);
    return rng_buf[0] < @as(u8, @intCast((@as(u16, g_loss_pct) * 256) / 100));
}

fn kcpOutput(data: []const u8, _: ?*anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_loss_bilateral and shouldDrop()) {
        g_pkts_dropped_send += 1;
        return;
    }
    var ct: [max_pkt]u8 = undefined;
    g_send_cs.encrypt(data, "", ct[0 .. data.len + tag_size]);
    _ = posix.sendto(g_sock, ct[0 .. data.len + tag_size], 0, g_dest_addr, g_dest_len) catch {};
    g_pkts_sent += 1;
}

fn fillBlock(buf: []u8, block_num: u32) void {
    for (buf, 0..) |*b, i| b.* = @intCast((block_num ^ @as(u32, @intCast(i))) & 0xFF);
}

fn verifyBlock(buf: []const u8, block_num: u32) bool {
    for (buf, 0..) |b, i| {
        if (b != @as(u8, @intCast((block_num ^ @as(u32, @intCast(i))) & 0xFF))) return false;
    }
    return true;
}

const KcpConfig = enum { A, B, C };

fn applyKcpConfig(kcp_inst: *Kcp, config: KcpConfig) void {
    switch (config) {
        .A => {
            // Set A: current defaults
            kcp_inst.setNodelay(2, 1, 2, 1);
            kcp_inst.setWndSize(4096, 4096);
            kcp_inst.setMtu(1400);
        },
        .B => {
            // Set B: aggressive retransmit
            kcp_inst.setNodelay(2, 1, 1, 1); // fastresend=1
            kcp_inst.setWndSize(4096, 4096);
            kcp_inst.setMtu(1400);
            // Set struct fields directly via C pointer
            kcp_inst.kcp.*.fastlimit = 20; // FASTACK_LIMIT: 5→20
            kcp_inst.kcp.*.dead_link = 100; // DEADLINK: 20→100
        },
        .C => {
            // Set C: max resilience
            kcp_inst.setNodelay(2, 1, 1, 1); // fastresend=1
            kcp_inst.setWndSize(4096, 4096);
            kcp_inst.setMtu(1400);
            kcp_inst.kcp.*.fastlimit = 20;
            kcp_inst.kcp.*.dead_link = 200;
            kcp_inst.kcp.*.ssthresh = 8; // THRESH_INIT: 2→8
            kcp_inst.kcp.*.rx_minrto = 5; // even lower min RTO
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: noise_throughput <ip> [port] [kb] [rounds] [loss%%] [loss_mode] [config]\n", .{});
        std.debug.print("  loss_mode: 0=recv-only (default), 1=bilateral\n", .{});
        std.debug.print("  config: A=current, B=aggressive, C=max-resilience\n", .{});
        return;
    }

    const peer_ip = args[1];
    const port = if (args.len > 2) std.fmt.parseInt(u16, args[2], 10) catch default_port else default_port;
    const total_kb = if (args.len > 3) std.fmt.parseInt(usize, args[3], 10) catch default_total_kb else default_total_kb;
    const rounds = if (args.len > 4) std.fmt.parseInt(usize, args[4], 10) catch default_rounds else default_rounds;
    g_loss_pct = if (args.len > 5) std.fmt.parseInt(u8, args[5], 10) catch 0 else 0;
    g_loss_bilateral = if (args.len > 6) (std.fmt.parseInt(u8, args[6], 10) catch 0) == 1 else false;
    const kcp_config: KcpConfig = if (args.len > 7) switch ((args[7])[0]) {
        'B', 'b' => .B,
        'C', 'c' => .C,
        else => .A,
    } else .A;

    const total_bytes = total_kb * 1024;
    const total_blocks = total_bytes / chunk_size;
    const loss_mode_str = if (g_loss_bilateral) "bilateral" else "recv-only";
    const config_str = switch (kcp_config) {
        .A => "A (current)",
        .B => "B (aggressive)",
        .C => "C (max-resilience)",
    };

    std.debug.print("\n=== KCP Loss Test: {d}%% {s}, Config {s} ===\n", .{ g_loss_pct, loss_mode_str, config_str });
    std.debug.print("{d}KB ({d} blocks) x {d} rounds\n\n", .{ total_kb, total_blocks, rounds });

    // Keypair + socket setup
    var seed: [32]u8 = undefined;
    DesktopCrypto.Rng.fill(&seed);
    const local_kp = KP.fromSeed(seed);

    const peer_addr = try std.net.Address.parseIp4(peer_ip, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    const timeout_val = posix.timeval{ .sec = 5, .usec = 0 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout_val));
    const buf_size: u32 = 256 * 1024;
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&buf_size));
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&buf_size));

    const dest_addr: *const posix.sockaddr = @ptrCast(&peer_addr.any);
    const dest_len = peer_addr.getOsSockLen();

    // Key exchange + handshake
    _ = try posix.sendto(sock, &local_kp.public.data, 0, dest_addr, dest_len);
    var peer_pk_buf: [32]u8 = undefined;
    const pk_len = posix.recvfrom(sock, &peer_pk_buf, 0, null, null) catch {
        std.debug.print("ERROR: No response\n", .{});
        return;
    };
    if (pk_len != 32) return;

    var hs = Noise.HandshakeState.init(.{
        .pattern = .IK,
        .initiator = true,
        .local_static = local_kp,
        .remote_static = Key.fromBytes(peer_pk_buf),
    }) catch return;

    var msg1_buf: [256]u8 = undefined;
    const msg1_len = hs.writeMessage("", &msg1_buf) catch return;
    _ = try posix.sendto(sock, msg1_buf[0..msg1_len], 0, dest_addr, dest_len);

    var msg2_buf: [256]u8 = undefined;
    const msg2_len = posix.recvfrom(sock, &msg2_buf, 0, null, null) catch return;
    var p: [64]u8 = undefined;
    _ = hs.readMessage(msg2_buf[0..msg2_len], &p) catch return;

    if (!hs.isFinished()) return;
    var send_cs, var recv_cs = hs.split() catch return;
    std.debug.print("Handshake OK\n", .{});

    // KCP setup with selected config
    g_sock = sock;
    g_dest_addr = dest_addr;
    g_dest_len = dest_len;
    g_send_cs = &send_cs;
    g_pkts_sent = 0;
    g_pkts_dropped_send = 0;
    g_pkts_dropped_recv = 0;

    var kcp_inst = try Kcp.create(allocator, 1, kcpOutput, null);
    defer {
        kcp_inst.deinit();
        allocator.destroy(kcp_inst);
    }
    applyKcpConfig(kcp_inst, kcp_config);

    const short_timeout = posix.timeval{ .sec = 0, .usec = 1_000 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&short_timeout));

    // Test loop
    var grand_verified: usize = 0;
    var grand_corrupted: usize = 0;
    var grand_throughput: u64 = 0;

    for (0..rounds) |round| {
        var blocks_sent: u32 = 0;
        var blocks_verified: u32 = 0;
        var blocks_corrupted: u32 = 0;
        var next_recv: u32 = 0;
        const start = std.time.milliTimestamp();
        var last_update: i64 = start;

        while (next_recv < total_blocks) {
            const now = std.time.milliTimestamp();
            if (now - last_update >= 1) {
                kcp_inst.update(@intCast(@as(u64, @intCast(now)) & 0xFFFFFFFF));
                last_update = now;
            }

            if (blocks_sent < total_blocks and kcp_inst.waitSnd() < 128) {
                var buf: [chunk_size]u8 = undefined;
                fillBlock(&buf, blocks_sent);
                if (kcp_inst.send(&buf) >= 0) blocks_sent += 1;
            }

            while (true) {
                var udp_buf: [max_pkt]u8 = undefined;
                const udp_len = posix.recvfrom(sock, &udp_buf, 0, null, null) catch break;
                // Recv-only loss (always applied) or bilateral
                if (shouldDrop()) { g_pkts_dropped_recv += 1; continue; }
                if (udp_len > tag_size) {
                    var pt: [max_pkt]u8 = undefined;
                    recv_cs.decrypt(udp_buf[0..udp_len], "", pt[0 .. udp_len - tag_size]) catch continue;
                    _ = kcp_inst.input(pt[0 .. udp_len - tag_size]);
                }
            }

            while (true) {
                var recv_buf: [chunk_size]u8 = undefined;
                const kcp_len = kcp_inst.recv(&recv_buf);
                if (kcp_len <= 0) break;
                if (kcp_len == chunk_size) {
                    if (verifyBlock(recv_buf[0..chunk_size], next_recv)) {
                        blocks_verified += 1;
                    } else {
                        blocks_corrupted += 1;
                    }
                    next_recv += 1;
                }
            }

            if (now - start > 30000) {
                std.debug.print("  TIMEOUT 30s\n", .{});
                break;
            }
        }

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
        const throughput = if (elapsed > 0) (@as(u64, blocks_verified) * chunk_size * 2 * 1000) / elapsed / 1024 else 0;

        if (rounds > 1) {
            std.debug.print("  R{d}: {d}/{d} verified, {d}ms, {d} KB/s\n", .{ round + 1, blocks_verified, total_blocks, elapsed, throughput });
        }

        grand_verified += blocks_verified;
        grand_corrupted += blocks_corrupted;
        grand_throughput += throughput;
    }

    const avg = grand_throughput / rounds;
    const total_dropped = g_pkts_dropped_send + g_pkts_dropped_recv;
    std.debug.print("{d}/{d} verified, {d} corrupt, {d} KB/s, dropped: {d} (send:{d} recv:{d}), integrity: {s}\n", .{
        grand_verified,
        total_blocks * rounds,
        grand_corrupted,
        avg,
        total_dropped,
        g_pkts_dropped_send,
        g_pkts_dropped_recv,
        if (grand_corrupted == 0) "PASS" else "FAIL",
    });
}
