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

const Noise = zgrnet.noise.Protocol(crypto_suite);
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
    const local_kp = KP.generate();
    std.debug.print("Local public key:  {s}...\n", .{&local_kp.public.shortHex()});

    // Parse peer address
    const peer_addr = try std.net.Address.parseIp4(peer_ip, port);

    // Create UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    // Set recv timeout (5s)
    const timeout = posix.timeval{ .sec = 5, .usec = 0 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

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
    const chunk_size: usize = 1024; // 1KB chunks (UDP-friendly)
    const num_chunks = total_bytes / chunk_size;

    // Prepare test data
    var plaintext: [chunk_size]u8 = undefined;
    for (&plaintext, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    var total_throughput: u64 = 0;

    for (0..rounds) |round| {
        std.debug.print("Round {d}/{d}: sending {d} KB ({d} chunks x {d}B)...\n", .{ round + 1, rounds, total_kb, num_chunks, chunk_size });

        const start = std.time.nanoTimestamp();
        var bytes_sent: usize = 0;

        for (0..num_chunks) |_| {
            // Encrypt
            var ciphertext: [chunk_size + tag_size]u8 = undefined;
            send_cs.encrypt(&plaintext, "", &ciphertext);

            // Send
            _ = posix.sendto(sock, &ciphertext, 0, dest_addr, dest_len) catch {
                std.debug.print("  Send failed\n", .{});
                continue;
            };
            bytes_sent += chunk_size;

            // Receive echo
            var echo_buf: [chunk_size + tag_size]u8 = undefined;
            const echo_len = posix.recvfrom(sock, &echo_buf, 0, null, null) catch {
                std.debug.print("  Echo timeout\n", .{});
                continue;
            };

            // Decrypt echo
            var decrypted: [chunk_size]u8 = undefined;
            recv_cs.decrypt(echo_buf[0..echo_len], "", &decrypted) catch {
                std.debug.print("  Decrypt failed\n", .{});
                continue;
            };
        }

        const elapsed_ns = std.time.nanoTimestamp() - start;
        const elapsed_ms = @as(u64, @intCast(elapsed_ns)) / 1_000_000;
        const throughput_kbps = if (elapsed_ms > 0) (bytes_sent * 2 * 1000) / elapsed_ms / 1024 else 0;

        std.debug.print("  Time: {d}ms, Throughput: {d} KB/s (bidirectional)\n", .{ elapsed_ms, throughput_kbps });
        total_throughput += throughput_kbps;
    }

    std.debug.print("\nAverage throughput: {d} KB/s\n", .{total_throughput / rounds});
    std.debug.print("=== Test Complete ===\n\n", .{});
}
