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

const esp = @import("esp");
const idf = esp.idf;
const crypto_suite = @import("crypto");
const zgrnet = @import("zgrnet");

const Noise = zgrnet.noise.Protocol(crypto_suite);
const Key = Noise.Key;
const KP = Noise.KeyPair;
const tag_size = zgrnet.tag_size;
const key_size = zgrnet.key_size;

const listen_port: u16 = 9999;
const max_packet: usize = 2048;

pub fn main() void {
    Board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };

    // Connect to WiFi
    log.info("Connecting to WiFi...", .{});
    Board.wifi.connect(platform.env.wifi_ssid, platform.env.wifi_password) catch |err| {
        log.err("WiFi connect failed: {}", .{err});
        return;
    };
    log.info("WiFi connected. Starting Noise responder on port {d}...", .{listen_port});

    // Generate keypair
    const local_kp = KP.generate();
    log.info("Local public key: {s}...", .{&local_kp.public.shortHex()});

    // Create UDP socket
    const sock = idf.socket.Socket.udp() catch |err| {
        log.err("UDP socket failed: {}", .{err});
        return;
    };
    defer sock.close();

    sock.bind(listen_port) catch |err| {
        log.err("Bind failed: {}", .{err});
        return;
    };

    log.info("Listening on UDP :{d}. Waiting for peer...", .{listen_port});

    while (Board.isRunning()) {
        handlePeer(sock, local_kp) catch |err| {
            log.err("Peer session error: {}. Waiting for next peer...", .{err});
        };
    }
}

fn handlePeer(sock: idf.socket.Socket, local_kp: KP) !void {
    var peer_addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

    // ====================================================================
    // Phase 1: Key exchange
    // ====================================================================
    log.info("Waiting for peer public key...", .{});

    var pk_buf: [max_packet]u8 = undefined;
    const pk_len = std.posix.recvfrom(sock.fd, &pk_buf, 0, &peer_addr, &addr_len) catch
        return error.RecvFailed;
    if (pk_len != 32) return error.InvalidKeyLength;

    const peer_pk = Key.fromBytes(pk_buf[0..32].*);
    log.info("Peer public key: {s}...", .{&peer_pk.shortHex()});

    // Send our public key back
    _ = std.posix.sendto(sock.fd, &local_kp.public.data, 0, &peer_addr, addr_len) catch
        return error.SendFailed;

    // ====================================================================
    // Phase 2: Noise IK Handshake (responder)
    // ====================================================================
    log.info("Starting Noise IK handshake (responder)...", .{});

    var hs = try Noise.HandshakeState.init(.{
        .pattern = .IK,
        .initiator = false,
        .local_static = local_kp,
    });

    // Message 1: receive from initiator
    var msg1_buf: [max_packet]u8 = undefined;
    const msg1_len = std.posix.recvfrom(sock.fd, &msg1_buf, 0, &peer_addr, &addr_len) catch
        return error.RecvFailed;

    var payload1: [64]u8 = undefined;
    _ = try hs.readMessage(msg1_buf[0..msg1_len], &payload1);

    // Message 2: send response
    var msg2_buf: [256]u8 = undefined;
    const msg2_len = try hs.writeMessage("", &msg2_buf);

    _ = std.posix.sendto(sock.fd, msg2_buf[0..msg2_len], 0, &peer_addr, addr_len) catch
        return error.SendFailed;

    if (!hs.isFinished()) return error.HandshakeNotFinished;

    var recv_cs, var send_cs = try hs.split();
    log.info("Handshake complete! Entering echo loop...", .{});

    // ====================================================================
    // Phase 3: Echo loop
    // ====================================================================
    var total_bytes: usize = 0;
    var total_packets: usize = 0;
    const start = std.time.milliTimestamp();

    while (Board.isRunning()) {
        var recv_buf: [max_packet]u8 = undefined;
        const recv_len = std.posix.recvfrom(sock.fd, &recv_buf, 0, &peer_addr, &addr_len) catch |err| {
            if (err == error.WouldBlock) {
                // Print stats periodically
                if (total_packets > 0) {
                    const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
                    const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
                    log.info("Stats: {d} packets, {d} KB, {d} KB/s (bidirectional)", .{ total_packets, total_bytes / 1024, kbps });
                }
                continue;
            }
            return error.RecvFailed;
        };

        if (recv_len < tag_size) continue;

        // Decrypt
        const pt_len = recv_len - tag_size;
        var plaintext: [max_packet]u8 = undefined;
        recv_cs.decrypt(recv_buf[0..recv_len], "", plaintext[0..pt_len]) catch {
            log.warn("Decrypt failed, ignoring packet", .{});
            continue;
        };

        // Re-encrypt and echo back
        var echo_buf: [max_packet]u8 = undefined;
        send_cs.encrypt(plaintext[0..pt_len], "", echo_buf[0 .. pt_len + tag_size]);

        _ = std.posix.sendto(sock.fd, echo_buf[0 .. pt_len + tag_size], 0, &peer_addr, addr_len) catch {
            log.warn("Echo send failed", .{});
            continue;
        };

        total_bytes += pt_len;
        total_packets += 1;

        // Print stats every 100 packets
        if (total_packets % 100 == 0) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            const kbps = if (elapsed > 0) (total_bytes * 2 * 1000) / elapsed / 1024 else 0;
            log.info("{d} packets, {d} KB/s", .{ total_packets, kbps });
        }
    }
}
