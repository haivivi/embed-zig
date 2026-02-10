//! Noise + KCP Throughput Test — Mac initiator
//!
//! Connects to ESP32 over UDP, performs Noise IK handshake,
//! then uses KCP reliable transport for echo throughput measurement.
//! Verifies data integrity of every echoed block.
//!
//! Usage:
//!   zig build run -- <peer_ip> [port] [total_kb] [rounds]

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
const key_size = zgrnet.key_size;
const Kcp = kcp_mod.Kcp;

const default_port: u16 = 9999;
const default_total_kb: usize = 64;
const default_rounds: usize = 3;
const max_pkt: usize = 2048;
const chunk_size: usize = 1024;

// Global state for KCP output callback
var g_sock: posix.socket_t = undefined;
var g_dest_addr: *const posix.sockaddr = undefined;
var g_dest_len: posix.socklen_t = undefined;
var g_send_cs: *Noise.CipherState = undefined;
var g_mutex: std.Thread.Mutex = .{};
var g_loss_pct: u8 = 0; // packet loss percentage (0-100)
var g_pkts_sent: u64 = 0;
var g_pkts_dropped: u64 = 0;

fn shouldDrop() bool {
    if (g_loss_pct == 0) return false;
    var rng_buf: [1]u8 = undefined;
    std.crypto.random.bytes(&rng_buf);
    return rng_buf[0] < @as(u8, @intCast((@as(u16, g_loss_pct) * 256) / 100));
}

fn kcpOutput(data: []const u8, _: ?*anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    // Simulate packet loss on send
    if (shouldDrop()) {
        g_pkts_dropped += 1;
        return;
    }
    var ct: [max_pkt]u8 = undefined;
    g_send_cs.encrypt(data, "", ct[0 .. data.len + tag_size]);
    _ = posix.sendto(g_sock, ct[0 .. data.len + tag_size], 0, g_dest_addr, g_dest_len) catch {};
    g_pkts_sent += 1;
}

/// Fill a block with a verifiable pattern: byte[i] = (block_num ^ i) & 0xFF
fn fillBlock(buf: []u8, block_num: u32) void {
    for (buf, 0..) |*b, i| {
        b.* = @intCast((block_num ^ @as(u32, @intCast(i))) & 0xFF);
    }
}

/// Verify a block matches the expected pattern. Returns true if OK.
fn verifyBlock(buf: []const u8, block_num: u32) bool {
    for (buf, 0..) |b, i| {
        const expected: u8 = @intCast((block_num ^ @as(u32, @intCast(i))) & 0xFF);
        if (b != expected) return false;
    }
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: noise_throughput <peer_ip> [port] [total_kb] [rounds] [loss_pct]\n", .{});
        std.debug.print("  loss_pct: simulate packet loss 0-100%% (default: 0)\n", .{});
        return;
    }

    const peer_ip = args[1];
    const port = if (args.len > 2) std.fmt.parseInt(u16, args[2], 10) catch default_port else default_port;
    const total_kb = if (args.len > 3) std.fmt.parseInt(usize, args[3], 10) catch default_total_kb else default_total_kb;
    const rounds = if (args.len > 4) std.fmt.parseInt(usize, args[4], 10) catch default_rounds else default_rounds;
    g_loss_pct = if (args.len > 5) std.fmt.parseInt(u8, args[5], 10) catch 0 else 0;
    const total_bytes = total_kb * 1024;
    const total_blocks = total_bytes / chunk_size;

    std.debug.print("\n=== Noise + KCP Resilience Test (Initiator) ===\n", .{});
    std.debug.print("Peer: {s}:{d}, Data: {d}KB ({d} blocks) x {d} rounds\n", .{ peer_ip, port, total_kb, total_blocks, rounds });
    if (g_loss_pct > 0) {
        std.debug.print("Simulated packet loss: {d}%%\n", .{g_loss_pct});
    }
    std.debug.print("Each block: {d}B with verifiable pattern\n\n", .{chunk_size});

    // Generate keypair
    var seed: [32]u8 = undefined;
    DesktopCrypto.Rng.fill(&seed);
    const local_kp = KP.fromSeed(seed);
    std.debug.print("Local key: {s}...\n", .{&local_kp.public.shortHex()});

    // UDP socket
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

    // 1ms recv timeout for fast KCP loop
    const short_timeout = posix.timeval{ .sec = 0, .usec = 1_000 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&short_timeout));

    // === Phase 4: KCP Echo with Data Verification ===
    var grand_total_sent: usize = 0;
    var grand_total_verified: usize = 0;
    var grand_total_corrupted: usize = 0;
    var grand_total_throughput: u64 = 0;

    for (0..rounds) |round| {
        std.debug.print("Round {d}/{d}: {d} blocks via KCP...\n", .{ round + 1, rounds, total_blocks });

        var blocks_sent: u32 = 0;
        var blocks_verified: u32 = 0;
        var blocks_corrupted: u32 = 0;
        var next_recv_block: u32 = 0;
        const start = std.time.milliTimestamp();
        var last_update: i64 = start;
        var last_print: i64 = start;

        while (next_recv_block < total_blocks) {
            const now = std.time.milliTimestamp();

            // KCP update
            if (now - last_update >= 1) {
                kcp_inst.update(@intCast(@as(u64, @intCast(now)) & 0xFFFFFFFF));
                last_update = now;
            }

            // Send blocks with pattern
            if (blocks_sent < total_blocks and kcp_inst.waitSnd() < 128) {
                var send_buf: [chunk_size]u8 = undefined;
                fillBlock(&send_buf, blocks_sent);
                const ret = kcp_inst.send(&send_buf);
                if (ret >= 0) blocks_sent += 1;
            }

            // Drain UDP → Noise decrypt → KCP input
            while (true) {
                var udp_buf: [max_pkt]u8 = undefined;
                const udp_len = posix.recvfrom(sock, &udp_buf, 0, null, null) catch break;
                // Simulate packet loss on recv
                if (shouldDrop()) { g_pkts_dropped += 1; continue; }
                if (udp_len > tag_size) {
                    var pt: [max_pkt]u8 = undefined;
                    recv_cs.decrypt(udp_buf[0..udp_len], "", pt[0 .. udp_len - tag_size]) catch continue;
                    _ = kcp_inst.input(pt[0 .. udp_len - tag_size]);
                }
            }

            // Drain KCP recv + verify
            while (true) {
                var recv_buf: [chunk_size]u8 = undefined;
                const kcp_len = kcp_inst.recv(&recv_buf);
                if (kcp_len <= 0) break;
                if (kcp_len == chunk_size) {
                    if (verifyBlock(recv_buf[0..chunk_size], next_recv_block)) {
                        blocks_verified += 1;
                    } else {
                        blocks_corrupted += 1;
                        std.debug.print("  CORRUPT block {d}!\n", .{next_recv_block});
                    }
                    next_recv_block += 1;
                }
            }

            // Progress every 2s
            if (now - last_print >= 2000) {
                const elapsed_s = @as(u64, @intCast(now - start)) / 1000;
                std.debug.print("  [{d}s] sent={d} verified={d} corrupt={d} waitSnd={d}\n", .{
                    elapsed_s, blocks_sent, blocks_verified, blocks_corrupted, kcp_inst.waitSnd(),
                });
                last_print = now;
            }

            // Timeout
            if (now - start > 60000) {
                std.debug.print("  TIMEOUT after 60s\n", .{});
                break;
            }
        }

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
        const data_kb = @as(u64, blocks_verified) * chunk_size / 1024;
        const throughput = if (elapsed > 0) (data_kb * 2 * 1000) / elapsed else 0;

        std.debug.print("  Sent: {d}, Verified: {d}, Corrupt: {d}, Time: {d}ms, Throughput: {d} KB/s\n", .{
            blocks_sent, blocks_verified, blocks_corrupted, elapsed, throughput,
        });

        grand_total_sent += blocks_sent;
        grand_total_verified += blocks_verified;
        grand_total_corrupted += blocks_corrupted;
        grand_total_throughput += throughput;
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total sent:     {d} blocks\n", .{grand_total_sent});
    std.debug.print("Total verified: {d} blocks\n", .{grand_total_verified});
    std.debug.print("Total corrupt:  {d} blocks\n", .{grand_total_corrupted});
    std.debug.print("Avg throughput: {d} KB/s\n", .{grand_total_throughput / rounds});
    if (g_loss_pct > 0) {
        std.debug.print("Packets sent:   {d}\n", .{g_pkts_sent});
        std.debug.print("Packets dropped:{d} ({d}%% configured)\n", .{ g_pkts_dropped, g_loss_pct });
    }
    std.debug.print("Data integrity: {s}\n", .{if (grand_total_corrupted == 0) "PASS" else "FAIL"});
    std.debug.print("=== Done ===\n\n", .{});
}
