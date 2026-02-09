//! Noise Throughput Test — Mac initiator
//!
//! Connects to ESP32 (or another peer) over UDP, performs Noise IK handshake,
//! then sends encrypted data and measures throughput.
//!
//! Usage:
//!   zig build run -- <peer_ip> [port] [total_kb] [rounds]
//!
//! Default: port=9999, total_kb=256, rounds=3

const std = @import("std");
const posix = std.posix;
const crypto_suite = @import("crypto");
const zgrnet = @import("zgrnet");

/// Desktop Crypto with all algorithms for both cipher suites.
const DesktopCrypto = struct {
    pub const Blake2s256 = crypto_suite.Blake2s256;
    pub const Sha256 = crypto_suite.Sha256;
    pub const ChaCha20Poly1305 = crypto_suite.ChaCha20Poly1305;
    pub const Aes256Gcm = crypto_suite.Aes256Gcm;
    pub const X25519 = crypto_suite.X25519;
    pub const Rng = crypto_suite.Rng;
};

/// Toggle this to match ESP32 side.
const use_aesgcm = false;

const Noise = if (use_aesgcm)
    zgrnet.noise.ProtocolWithSuite(DesktopCrypto, .AESGCM_SHA256)
else
    zgrnet.noise.Protocol(DesktopCrypto);
const Key = Noise.Key;
const KP = Noise.KeyPair;
const msg = zgrnet.noise.message;
const tag_size = zgrnet.tag_size;
const key_size = zgrnet.key_size;

const default_port: u16 = 9999;
const default_total_kb: usize = 256;
const default_rounds: usize = 3;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 2) {
        std.debug.print("Usage: noise_throughput <peer_ip> [port] [total_kb] [rounds]\n", .{});
        std.debug.print("  peer_ip:  ESP32 or peer IP address\n", .{});
        std.debug.print("  port:     UDP port (default: {d})\n", .{default_port});
        std.debug.print("  total_kb: data per round in KB (default: {d})\n", .{default_total_kb});
        std.debug.print("  rounds:   number of test rounds (default: {d})\n", .{default_rounds});
        return;
    }

    const peer_ip = args[1];
    const port = if (args.len > 2) std.fmt.parseInt(u16, args[2], 10) catch default_port else default_port;
    const total_kb = if (args.len > 3) std.fmt.parseInt(usize, args[3], 10) catch default_total_kb else default_total_kb;
    const rounds = if (args.len > 4) std.fmt.parseInt(usize, args[4], 10) catch default_rounds else default_rounds;

    const total_bytes = total_kb * 1024;

    std.debug.print("\n", .{});
    std.debug.print("=== Noise Protocol Throughput Test (Initiator) ===\n", .{});
    std.debug.print("Peer:       {s}:{d}\n", .{ peer_ip, port });
    std.debug.print("Data/round: {d} KB\n", .{total_kb});
    std.debug.print("Rounds:     {d}\n", .{rounds});
    std.debug.print("\n", .{});

    // Generate keypair
    var seed: [32]u8 = undefined;
    DesktopCrypto.Rng.fill(&seed);
    const local_kp = KP.fromSeed(seed);
    std.debug.print("Local public key:  {s}...\n", .{&local_kp.public.shortHex()});

    // Parse peer address
    const peer_addr = try std.net.Address.parseIp4(peer_ip, port);

    // Create UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    // Set recv timeout (5s)
    const timeout = posix.timeval{ .sec = 5, .usec = 0 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

    // Increase socket buffer sizes for throughput
    const buf_size: u32 = 256 * 1024; // 256KB
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&buf_size));
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&buf_size));

    const dest_addr: *const posix.sockaddr = @ptrCast(&peer_addr.any);
    const dest_len = peer_addr.getOsSockLen();

    // ========================================================================
    // Phase 1: Key exchange — send our public key, receive peer's
    // ========================================================================
    std.debug.print("Exchanging public keys...\n", .{});

    // Send our public key to peer
    _ = try posix.sendto(sock, &local_kp.public.data, 0, dest_addr, dest_len);

    // Receive peer's public key
    var peer_pk_buf: [32]u8 = undefined;
    const pk_len = posix.recvfrom(sock, &peer_pk_buf, 0, null, null) catch {
        std.debug.print("ERROR: No response from peer. Is the responder running?\n", .{});
        return;
    };
    if (pk_len != 32) {
        std.debug.print("ERROR: Invalid peer public key length: {d}\n", .{pk_len});
        return;
    }
    const peer_pk = Key.fromBytes(peer_pk_buf);
    std.debug.print("Peer public key:   {s}...\n", .{&peer_pk.shortHex()});

    // ========================================================================
    // Phase 2: Noise IK Handshake
    // ========================================================================
    std.debug.print("Starting Noise IK handshake...\n", .{});

    var hs = Noise.HandshakeState.init(.{
        .pattern = .IK,
        .initiator = true,
        .local_static = local_kp,
        .remote_static = peer_pk,
    }) catch {
        std.debug.print("ERROR: Failed to initialize handshake\n", .{});
        return;
    };

    // Message 1: initiator -> responder
    var msg1_buf: [256]u8 = undefined;
    const msg1_len = hs.writeMessage("", &msg1_buf) catch {
        std.debug.print("ERROR: Failed to write handshake message 1\n", .{});
        return;
    };
    _ = try posix.sendto(sock, msg1_buf[0..msg1_len], 0, dest_addr, dest_len);

    // Message 2: responder -> initiator
    var msg2_buf: [256]u8 = undefined;
    const msg2_len = posix.recvfrom(sock, &msg2_buf, 0, null, null) catch {
        std.debug.print("ERROR: No handshake response from peer\n", .{});
        return;
    };
    var payload_buf: [64]u8 = undefined;
    _ = hs.readMessage(msg2_buf[0..msg2_len], &payload_buf) catch {
        std.debug.print("ERROR: Failed to read handshake message 2\n", .{});
        return;
    };

    if (!hs.isFinished()) {
        std.debug.print("ERROR: Handshake not finished\n", .{});
        return;
    }

    // Split into transport keys
    var send_cs, var recv_cs = hs.split() catch {
        std.debug.print("ERROR: Failed to split handshake\n", .{});
        return;
    };
    std.debug.print("Handshake complete!\n\n", .{});

    // ========================================================================
    // Phase 3: Throughput test
    // ========================================================================
    const chunk_size: usize = 1024; // 1KB chunks
    const num_chunks = total_bytes / chunk_size;

    // Prepare test data
    var plaintext: [chunk_size]u8 = undefined;
    for (&plaintext, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    // Set short recv timeout for pipelined receive (100ms)
    const short_timeout = posix.timeval{ .sec = 0, .usec = 100_000 };

    var total_throughput: u64 = 0;

    for (0..rounds) |round| {
        std.debug.print("Round {d}/{d}: {d} KB pipelined ({d} x {d}B)...\n", .{ round + 1, rounds, total_kb, num_chunks, chunk_size });

        const start = std.time.nanoTimestamp();

        // Phase 1: Send all packets (pipelined, no waiting)
        for (0..num_chunks) |_| {
            var ciphertext: [chunk_size + tag_size]u8 = undefined;
            send_cs.encrypt(&plaintext, "", &ciphertext);
            _ = posix.sendto(sock, &ciphertext, 0, dest_addr, dest_len) catch continue;
        }

        // Phase 2: Receive all echoes
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&short_timeout));
        var echoes_received: usize = 0;
        var recv_buf: [chunk_size + tag_size]u8 = undefined;
        while (echoes_received < num_chunks) {
            const echo_len = posix.recvfrom(sock, &recv_buf, 0, null, null) catch break;
            var decrypted: [chunk_size]u8 = undefined;
            recv_cs.decrypt(recv_buf[0..echo_len], "", &decrypted) catch continue;
            echoes_received += 1;
        }
        // Restore long timeout
        const long_timeout = posix.timeval{ .sec = 5, .usec = 0 };
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&long_timeout));

        const bytes_total = num_chunks * chunk_size + echoes_received * chunk_size;
        const elapsed_ns = std.time.nanoTimestamp() - start;
        const elapsed_ms = @as(u64, @intCast(elapsed_ns)) / 1_000_000;
        const throughput_kbps = if (elapsed_ms > 0) (bytes_total * 1000) / elapsed_ms / 1024 else 0;

        std.debug.print("  Sent: {d}, Echoes: {d}/{d}, Time: {d}ms, Throughput: {d} KB/s\n", .{ num_chunks, echoes_received, num_chunks, elapsed_ms, throughput_kbps });
        total_throughput += throughput_kbps;
    }

    std.debug.print("\nAverage throughput: {d} KB/s\n", .{total_throughput / rounds});
    std.debug.print("=== Test Complete ===\n\n", .{});
}
