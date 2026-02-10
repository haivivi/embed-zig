//! Noise + KCP Stream Throughput Test — Mac initiator
//!
//! Uses Mux/Stream (with timeout) over Noise/UDP.
//!
//! Usage:
//!   noise_throughput <ip> [port] [kb] [rounds] [loss%] [loss_mode]
//!     loss_mode: 0=recv-only (default), 1=bilateral

const std = @import("std");
const posix = std.posix;
const crypto_suite = @import("crypto");
const zgrnet = @import("zgrnet");
const kcp_raw = zgrnet.kcp;
const kcp_stream_mod = zgrnet.kcp_stream;

const DesktopCrypto = struct {
    pub const Blake2s256 = crypto_suite.Blake2s256;
    pub const Sha256 = crypto_suite.Sha256;
    pub const ChaCha20Poly1305 = crypto_suite.ChaCha20Poly1305;
    pub const Aes256Gcm = crypto_suite.Aes256Gcm;
    pub const X25519 = crypto_suite.X25519;
    pub const Rng = crypto_suite.Rng;
};

/// Desktop Runtime for Mux/Stream
const DesktopRt = struct {
    pub const Mutex = struct {
        inner: std.Thread.Mutex = .{},
        pub fn init() Mutex { return .{}; }
        pub fn deinit(_: *Mutex) void {}
        pub fn lock(self: *Mutex) void { self.inner.lock(); }
        pub fn unlock(self: *Mutex) void { self.inner.unlock(); }
    };
    pub const Condition = struct {
        inner: std.Thread.Condition = .{},
        pub const TimedWaitResult = enum { signaled, timed_out };
        pub fn init() Condition { return .{}; }
        pub fn deinit(_: *Condition) void {}
        pub fn wait(self: *Condition, mutex: *Mutex) void { self.inner.wait(&mutex.inner); }
        pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) TimedWaitResult {
            self.inner.timedWait(&mutex.inner, timeout_ns) catch return .timed_out;
            return .signaled;
        }
        pub fn signal(self: *Condition) void { self.inner.signal(); }
        pub fn broadcast(self: *Condition) void { self.inner.broadcast(); }
    };
    pub fn nowMs() u64 {
        return @intCast(@as(u64, @intCast(std.time.milliTimestamp())));
    }
};

const Noise = zgrnet.noise.Protocol(DesktopCrypto);
const Key = Noise.Key;
const KP = Noise.KeyPair;
const tag_size = zgrnet.tag_size;
const Kcp = kcp_raw.Kcp;
const MuxType = kcp_stream_mod.Mux(DesktopRt);
const StreamType = kcp_stream_mod.Stream(DesktopRt);

const default_port: u16 = 9999;
const default_total_kb: usize = 64;
const default_rounds: usize = 1;
const max_pkt: usize = 2048;
const chunk_size: usize = 1024;
const stream_timeout_ns: u64 = 10 * std.time.ns_per_s; // 10s read timeout

// Global state
var g_sock: posix.socket_t = undefined;
var g_dest_addr: *const posix.sockaddr = undefined;
var g_dest_len: posix.socklen_t = undefined;
var g_send_cs: *Noise.CipherState = undefined;
var g_recv_cs: *Noise.CipherState = undefined;
var g_mutex: std.Thread.Mutex = .{};
var g_loss_pct: u8 = 0;
var g_loss_bilateral: bool = false;
var g_pkts_sent: u64 = 0;
var g_pkts_dropped_send: u64 = 0;
var g_pkts_dropped_recv: u64 = 0;
var g_mux: *MuxType = undefined;

fn shouldDrop() bool {
    if (g_loss_pct == 0) return false;
    if (g_loss_pct >= 100) return true;
    var rng_buf: [1]u8 = undefined;
    std.crypto.random.bytes(&rng_buf);
    const threshold: u8 = @intCast((@as(u16, g_loss_pct) * 255) / 100);
    return rng_buf[0] < threshold;
}

/// Mux output: Noise encrypt + UDP send
fn muxOutput(data: []const u8, _: ?*anyopaque) anyerror!void {
    g_mutex.lock();
    defer g_mutex.unlock();
    var ct: [max_pkt]u8 = undefined;
    g_send_cs.encrypt(data, "", ct[0 .. data.len + tag_size]);
    if (g_loss_bilateral and shouldDrop()) {
        g_pkts_dropped_send += 1;
        return;
    }
    _ = posix.sendto(g_sock, ct[0 .. data.len + tag_size], 0, g_dest_addr, g_dest_len) catch {};
    g_pkts_sent += 1;
}

fn onNewStream(_: *anyopaque, _: ?*anyopaque) void {}

fn fillBlock(buf: []u8, block_num: u32) void {
    for (buf, 0..) |*b, i| b.* = @intCast((block_num ^ @as(u32, @intCast(i))) & 0xFF);
}

fn verifyBlock(buf: []const u8, block_num: u32) bool {
    for (buf, 0..) |b, i| {
        if (b != @as(u8, @intCast((block_num ^ @as(u32, @intCast(i))) & 0xFF))) return false;
    }
    return true;
}

/// UDP recv thread: decrypt + feed to Mux
fn recvThread() void {
    while (true) {
        var udp_buf: [max_pkt]u8 = undefined;
        const udp_len = posix.recvfrom(g_sock, &udp_buf, 0, null, null) catch continue;
        if (udp_len > tag_size) {
            var pt: [max_pkt]u8 = undefined;
            g_mutex.lock();
            g_recv_cs.decrypt(udp_buf[0..udp_len], "", pt[0 .. udp_len - tag_size]) catch {
                g_mutex.unlock();
                continue;
            };
            g_mutex.unlock();
            // Loss simulation after decrypt
            if (shouldDrop()) { g_pkts_dropped_recv += 1; continue; }
            g_mux.input(pt[0 .. udp_len - tag_size]) catch continue;
        }
    }
}

/// Mux update thread
fn updateThread() void {
    while (true) {
        g_mux.update();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: noise_throughput <ip> [port] [kb] [rounds] [loss%%] [loss_mode]\n", .{});
        return;
    }

    const peer_ip = args[1];
    const port = if (args.len > 2) std.fmt.parseInt(u16, args[2], 10) catch default_port else default_port;
    const total_kb = if (args.len > 3) std.fmt.parseInt(usize, args[3], 10) catch default_total_kb else default_total_kb;
    const rounds = if (args.len > 4) std.fmt.parseInt(usize, args[4], 10) catch default_rounds else default_rounds;
    g_loss_pct = if (args.len > 5) std.fmt.parseInt(u8, args[5], 10) catch 0 else 0;
    g_loss_bilateral = if (args.len > 6) (std.fmt.parseInt(u8, args[6], 10) catch 0) == 1 else false;

    const total_bytes = total_kb * 1024;
    const total_blocks = total_bytes / chunk_size;

    std.debug.print("\n=== Noise+KCP Stream Test: {d}%% loss, {d}KB x {d} ===\n", .{ g_loss_pct, total_kb, rounds });

    // Keypair + socket
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
    _ = posix.recvfrom(sock, &peer_pk_buf, 0, null, null) catch {
        std.debug.print("ERROR: No response\n", .{});
        return;
    };

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

    // Setup globals
    g_sock = sock;
    g_dest_addr = dest_addr;
    g_dest_len = dest_len;
    g_send_cs = &send_cs;
    g_recv_cs = &recv_cs;

    // Set non-blocking recv for recv thread
    const short_timeout = posix.timeval{ .sec = 0, .usec = 10_000 };
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&short_timeout));

    // Create Mux (client side)
    var mux = try MuxType.init(allocator, .{}, true, muxOutput, onNewStream, null);
    defer mux.deinit();
    g_mux = mux;

    // Start background threads
    _ = try std.Thread.spawn(.{}, recvThread, .{});
    _ = try std.Thread.spawn(.{}, updateThread, .{});

    // Open stream
    var stream = try mux.openStream(0, &.{});
    defer stream.close();

    std.debug.print("Stream opened, testing...\n\n", .{});

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

        // Send all blocks
        while (blocks_sent < total_blocks) {
            var buf: [chunk_size]u8 = undefined;
            fillBlock(&buf, blocks_sent);
            _ = stream.write(&buf) catch break;
            blocks_sent += 1;
        }

        // Receive echoes with timeout
        while (next_recv < total_blocks) {
            var recv_buf: [chunk_size]u8 = undefined;
            const n = stream.readBlocking(&recv_buf, stream_timeout_ns) catch |err| {
                if (err == kcp_stream_mod.StreamError.Timeout) {
                    std.debug.print("  Timeout at block {d}/{d}\n", .{ next_recv, total_blocks });
                    break;
                }
                break;
            };
            if (n == 0) break; // EOF
            if (n == chunk_size) {
                if (verifyBlock(recv_buf[0..chunk_size], next_recv)) {
                    blocks_verified += 1;
                } else {
                    blocks_corrupted += 1;
                }
            } else {
                blocks_corrupted += 1;
            }
            next_recv += 1;
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

    const avg = if (rounds > 0) grand_throughput / rounds else 0;
    const total_dropped = g_pkts_dropped_send + g_pkts_dropped_recv;
    std.debug.print("{d}/{d} verified, {d} corrupt, {d} KB/s, dropped: {d}, integrity: {s}\n", .{
        grand_verified,
        total_blocks * rounds,
        grand_corrupted,
        avg,
        total_dropped,
        if (grand_corrupted == 0) "PASS" else "FAIL",
    });
}
