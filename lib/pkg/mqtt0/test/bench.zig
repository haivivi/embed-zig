//! mqtt0 Benchmarks — aligned with Go mqtt0 benchmark_test.go
//!
//! Covers:
//!   1. PacketEncode (v4/v5 PUBLISH encoding, pure CPU)
//!   2. TrieMatching (exact/wildcard/no_match, pure memory)
//!   3. PublishThroughput (single-client QoS 0 over loopback TCP)
//!   4. E2ELatency (publisher→subscriber via broker)
//!   5. MessageRoutingThroughput (1 pub → N sub fan-out)
//!   6. WildcardRoutingThroughput (wildcard subscription routing)
//!   7. ConnectionThroughput (connect/disconnect rate, v4/v5)
//!   8. HighThroughputStress (4 pub/sub pairs sustained)
//!   9. MessageRate (minimal payload, raw msg/s)
//!
//! Usage:
//!   zig build run-bench
//!   zig build run-bench -- --filter=Trie

const std = @import("std");
const mqtt0 = @import("mqtt0");
const posix = std.posix;

// ============================================================================
// TCP Socket (reused from test_mqtt0.zig)
// ============================================================================

const TcpSocket = struct {
    fd: posix.socket_t,

    fn initServer(port: u16) !struct { listener: posix.socket_t, port: u16 } {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        const enable: u32 = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try posix.listen(fd, 128);
        var bound_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);
        return .{ .listener = fd, .port = std.mem.bigToNative(u16, bound_addr.port) };
    }

    fn accept(listener: posix.socket_t) !TcpSocket {
        const fd = try posix.accept(listener, null, null, 0);
        return .{ .fd = fd };
    }

    fn connect(port: u16) !TcpSocket {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
        };
        try posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        return .{ .fd = fd };
    }

    pub fn send(self: *TcpSocket, data: []const u8) !usize {
        return posix.send(self.fd, data, 0) catch return error.SendFailed;
    }

    pub fn recv(self: *TcpSocket, buf: []u8) !usize {
        const n = posix.recv(self.fd, buf, 0) catch return error.RecvFailed;
        if (n == 0) return error.ConnectionClosed;
        return n;
    }

    pub fn setRecvTimeout(self: *TcpSocket, timeout_ms: u32) void {
        const tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    fn close(self: *TcpSocket) void {
        posix.close(self.fd);
    }
};

// ============================================================================
// Benchmark Harness
// ============================================================================

const Bench = struct {
    name: []const u8,
    iterations: u64 = 0,
    elapsed_ns: u64 = 0,
    bytes_per_op: u64 = 0,

    /// Setup function type — called once before timing starts.
    /// Returns an opaque context pointer for teardown.
    const SetupFn = ?*const fn () ?*anyopaque;
    const TeardownFn = ?*const fn (?*anyopaque) void;

    fn run(name: []const u8, bytes_per_op: u64, comptime func: fn (*Bench) void) Bench {
        var b = Bench{ .name = name, .bytes_per_op = bytes_per_op };

        // Warmup (small)
        b.iterations = 10;
        func(&b);

        // Auto-calibrate: run until we have at least 200ms of data
        var target_iters: u64 = 100;
        while (true) {
            b.iterations = target_iters;
            var timer = std.time.Timer.start() catch unreachable;
            func(&b);
            b.elapsed_ns = timer.read();

            if (b.elapsed_ns >= 200_000_000) break; // 200ms minimum
            if (target_iters >= 10_000_000) break; // cap at 10M

            if (b.elapsed_ns > 0) {
                const ns_per_op = b.elapsed_ns / target_iters;
                if (ns_per_op > 0) {
                    target_iters = 500_000_000 / ns_per_op;
                    target_iters = @max(target_iters, 100);
                } else {
                    target_iters *= 10;
                }
            } else {
                target_iters *= 10;
            }
        }

        return b;
    }

    fn report(self: *const Bench) void {
        const ns_per_op = if (self.iterations > 0) self.elapsed_ns / self.iterations else 0;

        if (self.bytes_per_op > 0 and ns_per_op > 0) {
            const throughput = (self.bytes_per_op * 1_000_000_000) / ns_per_op;
            const mb_s = throughput / (1024 * 1024);
            std.debug.print("{s:<45} {d:>10} {d:>8} ns/op {d:>8} MB/s\n", .{
                self.name, self.iterations, ns_per_op, mb_s,
            });
        } else {
            std.debug.print("{s:<45} {d:>10} {d:>8} ns/op\n", .{
                self.name, self.iterations, ns_per_op,
            });
        }
    }

    fn reportWithRate(self: *const Bench) void {
        const ns_per_op = if (self.iterations > 0) self.elapsed_ns / self.iterations else 0;
        const msg_per_s = if (ns_per_op > 0) 1_000_000_000 / ns_per_op else 0;
        std.debug.print("{s:<45} {d:>10} {d:>8} ns/op {d:>8} msg/s\n", .{
            self.name, self.iterations, ns_per_op, msg_per_s,
        });
    }
};

// ============================================================================
// Broker Helper
// ============================================================================

const BrokerEnv = struct {
    listener: posix.socket_t,
    port: u16,
    broker: mqtt0.Broker(TcpSocket),
    mux: mqtt0.Mux,
    threads: std.ArrayListUnmanaged(std.Thread),
    allocator: std.mem.Allocator,

    /// Must heap-allocate: broker's handler holds pointer to mux,
    /// so the struct must not move after init.
    fn create(allocator: std.mem.Allocator) !*BrokerEnv {
        const self = try allocator.create(BrokerEnv);
        self.* = .{
            .listener = undefined,
            .port = 0,
            .broker = undefined,
            .mux = undefined,
            .threads = .empty,
            .allocator = allocator,
        };
        self.mux = try mqtt0.Mux.init(allocator);
        const noop = struct {
            fn handle(_: []const u8, _: *const mqtt0.Message) anyerror!void {}
        }.handle;
        try self.mux.handleFn("#", noop);
        self.broker = try mqtt0.Broker(TcpSocket).init(allocator, self.mux.handler(), .{});
        const srv = try TcpSocket.initServer(0);
        self.listener = srv.listener;
        self.port = srv.port;
        return self;
    }

    fn acceptOne(self: *BrokerEnv) void {
        const t = std.Thread.spawn(.{}, struct {
            fn run(b: *mqtt0.Broker(TcpSocket), listener: posix.socket_t) void {
                var conn = TcpSocket.accept(listener) catch return;
                defer conn.close();
                b.serveConn(&conn);
            }
        }.run, .{ &self.broker, self.listener }) catch return;
        self.threads.append(self.allocator, t) catch {};
    }

    /// Spawn a persistent accept loop (handles unlimited connections, each in its own thread).
    fn acceptLoop(self: *BrokerEnv) void {
        const t = std.Thread.spawn(.{}, struct {
            fn run(b: *mqtt0.Broker(TcpSocket), listener: posix.socket_t, alloc: std.mem.Allocator) void {
                while (true) {
                    const conn_ptr = alloc.create(TcpSocket) catch return;
                    conn_ptr.* = TcpSocket.accept(listener) catch {
                        alloc.destroy(conn_ptr);
                        return;
                    };
                    const ct = std.Thread.spawn(.{}, struct {
                        fn handle(broker: *mqtt0.Broker(TcpSocket), c: *TcpSocket, a: std.mem.Allocator) void {
                            defer {
                                c.close();
                                a.destroy(c);
                            }
                            broker.serveConn(c);
                        }
                    }.handle, .{ b, conn_ptr, alloc }) catch {
                        conn_ptr.close();
                        alloc.destroy(conn_ptr);
                        continue;
                    };
                    ct.detach();
                }
            }
        }.run, .{ &self.broker, self.listener, self.allocator }) catch return;
        t.detach();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    fn acceptN(self: *BrokerEnv, n: usize) void {
        for (0..n) |_| self.acceptOne();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    fn deinit(self: *BrokerEnv) void {
        posix.close(self.listener);
        for (self.threads.items) |t| t.join();
        self.threads.deinit(self.allocator);
        self.broker.deinit();
        self.mux.deinit();
    }
};

// ============================================================================
// 1. PacketEncode Benchmarks (pure CPU)
// ============================================================================

fn benchPacketEncodeV4_64(b: *Bench) void {
    var buf: [8192]u8 = undefined;
    const payload = [_]u8{0} ** 64;
    for (0..b.iterations) |_| {
        _ = mqtt0.v4.encodePublish(&buf, &.{
            .topic = "bench/topic",
            .payload = &payload,
        }) catch unreachable;
    }
}

fn benchPacketEncodeV4_1k(b: *Bench) void {
    var buf: [8192]u8 = undefined;
    const payload = [_]u8{0} ** 1024;
    for (0..b.iterations) |_| {
        _ = mqtt0.v4.encodePublish(&buf, &.{
            .topic = "bench/topic",
            .payload = &payload,
        }) catch unreachable;
    }
}

fn benchPacketEncodeV5_64(b: *Bench) void {
    var buf: [8192]u8 = undefined;
    const payload = [_]u8{0} ** 64;
    for (0..b.iterations) |_| {
        _ = mqtt0.v5.encodePublish(&buf, &.{
            .topic = "bench/topic",
            .payload = &payload,
        }) catch unreachable;
    }
}

fn benchPacketEncodeV5_1k(b: *Bench) void {
    var buf: [8192]u8 = undefined;
    const payload = [_]u8{0} ** 1024;
    for (0..b.iterations) |_| {
        _ = mqtt0.v5.encodePublish(&buf, &.{
            .topic = "bench/topic",
            .payload = &payload,
        }) catch unreachable;
    }
}

// ============================================================================
// 2. TrieMatching Benchmarks (pure memory)
// ============================================================================

fn benchTrieExactMatch(b: *Bench) void {
    var trie = mqtt0.trie.Trie([]const u8).init(std.heap.page_allocator) catch unreachable;
    defer trie.deinit();
    const patterns = [_][]const u8{
        "device/+/state",
        "device/+/stats",
        "device/+/events/#",
        "server/push/#",
        "system/+/+/metrics",
    };
    for (patterns) |p| trie.insert(p, p) catch {};

    for (0..b.iterations) |_| {
        _ = trie.get("device/gear-001/state");
    }
}

fn benchTrieWildcardMatch(b: *Bench) void {
    var trie = mqtt0.trie.Trie([]const u8).init(std.heap.page_allocator) catch unreachable;
    defer trie.deinit();
    const patterns = [_][]const u8{
        "device/+/state",
        "device/+/stats",
        "device/+/events/#",
        "server/push/#",
        "system/+/+/metrics",
    };
    for (patterns) |p| trie.insert(p, p) catch {};

    for (0..b.iterations) |_| {
        _ = trie.get("device/gear-001/events/click/button");
    }
}

fn benchTrieNoMatch(b: *Bench) void {
    var trie = mqtt0.trie.Trie([]const u8).init(std.heap.page_allocator) catch unreachable;
    defer trie.deinit();
    const patterns = [_][]const u8{
        "device/+/state",
        "device/+/stats",
        "device/+/events/#",
        "server/push/#",
        "system/+/+/metrics",
    };
    for (patterns) |p| trie.insert(p, p) catch {};

    for (0..b.iterations) |_| {
        _ = trie.get("unknown/topic/path");
    }
}

// ============================================================================
// 3. PublishThroughput (loopback TCP)
// ============================================================================

fn benchPublishThroughput(comptime payload_size: usize, comptime version: mqtt0.ProtocolVersion) fn (*Bench) void {
    return struct {
        const State = struct {
            env: *BrokerEnv,
            sock: TcpSocket,
            mux: mqtt0.Mux,
            client: mqtt0.Client(TcpSocket),
        };
        var state: ?*State = null;

        fn run(b: *Bench) void {
            const allocator = std.heap.page_allocator;
            if (state == null) {
                const s = allocator.create(State) catch return;
                s.env = BrokerEnv.create(allocator) catch return;
                s.env.acceptLoop();
                s.sock = TcpSocket.connect(s.env.port) catch return;
                s.mux = mqtt0.Mux.init(allocator) catch return;
                s.client = mqtt0.Client(TcpSocket).init(&s.sock, &s.mux, .{
                    .client_id = "bench-pub",
                    .protocol_version = version,
                    .keep_alive = 0,
                }) catch return;
                state = s;
            }
            const s = state.?;
            const payload = [_]u8{'x'} ** payload_size;
            for (0..b.iterations) |_| {
                s.client.publish("bench/topic", &payload) catch return;
            }
        }
    }.run;
}

// ============================================================================
// 5. E2E Latency (pub→recv via broker)
// ============================================================================

fn benchE2ELatency(comptime payload_size: usize) fn (*Bench) void {
    return struct {
        fn run(b: *Bench) void {
            const S = struct {
                var inited: bool = false;
                var env: *BrokerEnv = undefined;
                var sub_sock: TcpSocket = undefined;
                var sub_mux: mqtt0.Mux = undefined;
                var sub: mqtt0.Client(TcpSocket) = undefined;
                var pub_sock: TcpSocket = undefined;
                var pub_mux: mqtt0.Mux = undefined;
                var pub_client: mqtt0.Client(TcpSocket) = undefined;
            };
            if (!S.inited) {
                const allocator = std.heap.page_allocator;
                S.env = BrokerEnv.create(allocator) catch return;
                S.env.acceptLoop();

                S.sub_sock = TcpSocket.connect(S.env.port) catch return;
                S.sub_mux = mqtt0.Mux.init(allocator) catch return;
                const noop = struct {
                    fn handle(_: []const u8, _: *const mqtt0.Message) anyerror!void {}
                }.handle;
                S.sub_mux.handleFn("bench/latency", noop) catch {};
                S.sub = mqtt0.Client(TcpSocket).init(&S.sub_sock, &S.sub_mux, .{
                    .client_id = "bench-e2e-sub",
                    .keep_alive = 0,
                }) catch return;
                S.sub.subscribe(&.{"bench/latency"}) catch return;
                S.sub_sock.setRecvTimeout(2000);

                S.pub_sock = TcpSocket.connect(S.env.port) catch return;
                S.pub_mux = mqtt0.Mux.init(allocator) catch return;
                S.pub_client = mqtt0.Client(TcpSocket).init(&S.pub_sock, &S.pub_mux, .{
                    .client_id = "bench-e2e-pub",
                    .keep_alive = 0,
                }) catch return;

                S.inited = true;
            }

            const payload = [_]u8{'x'} ** payload_size;
            for (0..b.iterations) |_| {
                S.pub_client.publish("bench/latency", &payload) catch return;
                S.sub.poll() catch return;
            }
        }
    }.run;
}

// ============================================================================
// 6/7. Message Routing Throughput
// ============================================================================

fn benchRoutingThroughput(comptime sub_count: usize) fn (*Bench) void {
    return struct {
        fn run(b: *Bench) void {
            const S = struct {
                var inited: bool = false;
                var env: *BrokerEnv = undefined;
                var sub_socks: [sub_count]TcpSocket = undefined;
                var sub_muxes: [sub_count]mqtt0.Mux = undefined;
                var subs: [sub_count]mqtt0.Client(TcpSocket) = undefined;
                var pub_sock: TcpSocket = undefined;
                var pub_mux: mqtt0.Mux = undefined;
                var pub_client: mqtt0.Client(TcpSocket) = undefined;
            };
            if (!S.inited) {
                const allocator = std.heap.page_allocator;
                S.env = BrokerEnv.create(allocator) catch return;
                S.env.acceptLoop();

                for (0..sub_count) |i| {
                    S.sub_socks[i] = TcpSocket.connect(S.env.port) catch return;
                    S.sub_muxes[i] = mqtt0.Mux.init(allocator) catch return;
                    var id_buf: [32]u8 = undefined;
                    const id = std.fmt.bufPrint(&id_buf, "rsub-{d}", .{i}) catch "sub";
                    S.subs[i] = mqtt0.Client(TcpSocket).init(&S.sub_socks[i], &S.sub_muxes[i], .{
                        .client_id = id,
                        .keep_alive = 0,
                    }) catch return;
                    S.subs[i].subscribe(&.{"bench/route"}) catch return;
                    S.sub_socks[i].setRecvTimeout(2000);
                }
                S.pub_sock = TcpSocket.connect(S.env.port) catch return;
                S.pub_mux = mqtt0.Mux.init(allocator) catch return;
                S.pub_client = mqtt0.Client(TcpSocket).init(&S.pub_sock, &S.pub_mux, .{
                    .client_id = "route-pub",
                    .keep_alive = 0,
                }) catch return;
                S.inited = true;
            }

            const payload = [_]u8{'x'} ** 64;
            for (0..b.iterations) |_| {
                S.pub_client.publish("bench/route", &payload) catch return;
                for (0..sub_count) |i| {
                    S.subs[i].poll() catch {};
                }
            }
        }
    }.run;
}

// ============================================================================
// 8. ConnectionThroughput
// ============================================================================

fn benchConnectionThroughput(comptime version: mqtt0.ProtocolVersion) fn (*Bench) void {
    return struct {
        fn run(b: *Bench) void {
            const S = struct {
                var inited: bool = false;
                var env: *BrokerEnv = undefined;
            };
            if (!S.inited) {
                S.env = BrokerEnv.create(std.heap.page_allocator) catch return;
                S.env.acceptLoop();
                S.inited = true;
            }
            const allocator = std.heap.page_allocator;
            for (0..b.iterations) |i| {
                var sock = TcpSocket.connect(S.env.port) catch return;
                var mux = mqtt0.Mux.init(allocator) catch return;
                var id_buf: [32]u8 = undefined;
                const id = std.fmt.bufPrint(&id_buf, "c-{d}", .{i}) catch "c";
                var client = mqtt0.Client(TcpSocket).init(&sock, &mux, .{
                    .client_id = id,
                    .protocol_version = version,
                    .keep_alive = 0,
                }) catch {
                    mux.deinit();
                    sock.close();
                    return;
                };
                client.deinit();
                mux.deinit();
                sock.close();
            }
        }
    }.run;
}

// ============================================================================
// 9. HighThroughputStress (4 pub/sub pairs)
// ============================================================================

fn benchHighThroughputStress(b: *Bench) void {
    const num_pairs = 4;
    const S = struct {
        var inited: bool = false;
        var env: *BrokerEnv = undefined;
        var pub_socks: [num_pairs]TcpSocket = undefined;
        var pub_muxes: [num_pairs]mqtt0.Mux = undefined;
        var pub_clients: [num_pairs]mqtt0.Client(TcpSocket) = undefined;
        var sub_socks: [num_pairs]TcpSocket = undefined;
        var sub_muxes: [num_pairs]mqtt0.Mux = undefined;
        var sub_clients: [num_pairs]mqtt0.Client(TcpSocket) = undefined;
        var topics: [num_pairs][32]u8 = undefined;
        var topic_lens: [num_pairs]usize = undefined;
    };
    if (!S.inited) {
        const allocator = std.heap.page_allocator;
        S.env = BrokerEnv.create(allocator) catch return;
        S.env.acceptLoop();

        for (0..num_pairs) |i| {
            var topic_buf: [32]u8 = undefined;
            const topic = std.fmt.bufPrint(&topic_buf, "stress/{d}", .{i}) catch "stress/0";
            @memcpy(S.topics[i][0..topic.len], topic);
            S.topic_lens[i] = topic.len;

            S.sub_socks[i] = TcpSocket.connect(S.env.port) catch return;
            S.sub_muxes[i] = mqtt0.Mux.init(allocator) catch return;
            var sid_buf: [32]u8 = undefined;
            const sid = std.fmt.bufPrint(&sid_buf, "ss-{d}", .{i}) catch "sub";
            S.sub_clients[i] = mqtt0.Client(TcpSocket).init(&S.sub_socks[i], &S.sub_muxes[i], .{
                .client_id = sid,
                .keep_alive = 0,
            }) catch return;
            S.sub_clients[i].subscribe(&.{S.topics[i][0..S.topic_lens[i]]}) catch return;
            S.sub_socks[i].setRecvTimeout(2000);

            S.pub_socks[i] = TcpSocket.connect(S.env.port) catch return;
            S.pub_muxes[i] = mqtt0.Mux.init(allocator) catch return;
            var pid_buf: [32]u8 = undefined;
            const pid = std.fmt.bufPrint(&pid_buf, "sp-{d}", .{i}) catch "pub";
            S.pub_clients[i] = mqtt0.Client(TcpSocket).init(&S.pub_socks[i], &S.pub_muxes[i], .{
                .client_id = pid,
                .keep_alive = 0,
            }) catch return;
        }
        S.inited = true;
    }

    const payload = [_]u8{'x'} ** 256;
    for (0..b.iterations) |_| {
        for (0..num_pairs) |i| {
            S.pub_clients[i].publish(S.topics[i][0..S.topic_lens[i]], &payload) catch {};
        }
        for (0..num_pairs) |i| {
            S.sub_clients[i].poll() catch {};
        }
    }
}

// ============================================================================
// 10. MessageRate (minimal payload)
// ============================================================================

fn benchMessageRate(b: *Bench) void {
    const S = struct {
        var inited: bool = false;
        var env: *BrokerEnv = undefined;
        var sock: TcpSocket = undefined;
        var mux: mqtt0.Mux = undefined;
        var client: mqtt0.Client(TcpSocket) = undefined;
    };
    if (!S.inited) {
        S.env = BrokerEnv.create(std.heap.page_allocator) catch return;
        S.env.acceptLoop();
        S.sock = TcpSocket.connect(S.env.port) catch return;
        S.mux = mqtt0.Mux.init(std.heap.page_allocator) catch return;
        S.client = mqtt0.Client(TcpSocket).init(&S.sock, &S.mux, .{
            .client_id = "rate-client",
            .keep_alive = 0,
        }) catch return;
        S.inited = true;
    }
    for (0..b.iterations) |_| {
        S.client.publish("rate/test", "x") catch return;
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var filter: ?[]const u8 = null;
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("=== mqtt0 Benchmarks (Zig) ===\n", .{});
    std.debug.print("                                                     iters    ns/op     rate\n", .{});
    std.debug.print("\n", .{});

    const runBench = struct {
        fn run(name: []const u8, bytes: u64, comptime func: fn (*Bench) void, f: ?[]const u8) void {
            if (f) |flt| {
                if (std.mem.indexOf(u8, name, flt) == null) return;
            }
            const b = Bench.run(name, bytes, func);
            b.report();
        }

        fn runRate(name: []const u8, comptime func: fn (*Bench) void, f: ?[]const u8) void {
            if (f) |flt| {
                if (std.mem.indexOf(u8, name, flt) == null) return;
            }
            const b = Bench.run(name, 0, func);
            b.reportWithRate();
        }
    };

    // 1. PacketEncode
    runBench.run("PacketEncode/v4_publish_64b", 64, benchPacketEncodeV4_64, filter);
    runBench.run("PacketEncode/v4_publish_1kb", 1024, benchPacketEncodeV4_1k, filter);
    runBench.run("PacketEncode/v5_publish_64b", 64, benchPacketEncodeV5_64, filter);
    runBench.run("PacketEncode/v5_publish_1kb", 1024, benchPacketEncodeV5_1k, filter);
    std.debug.print("\n", .{});

    // 2. TrieMatching
    runBench.run("TrieMatching/exact_match", 0, benchTrieExactMatch, filter);
    runBench.run("TrieMatching/wildcard_match", 0, benchTrieWildcardMatch, filter);
    runBench.run("TrieMatching/no_match", 0, benchTrieNoMatch, filter);
    std.debug.print("\n", .{});

    // 3. PublishThroughput
    runBench.run("PublishThroughput/64_bytes", 64, benchPublishThroughput(64, .v4), filter);
    runBench.run("PublishThroughput/256_bytes", 256, benchPublishThroughput(256, .v4), filter);
    runBench.run("PublishThroughput/1024_bytes", 1024, benchPublishThroughput(1024, .v4), filter);
    runBench.run("PublishThroughput/4096_bytes", 4096, benchPublishThroughput(4096, .v4), filter);
    std.debug.print("\n", .{});

    // 5. E2E Latency
    runBench.run("E2ELatency/64_bytes", 64, benchE2ELatency(64), filter);
    runBench.run("E2ELatency/256_bytes", 256, benchE2ELatency(256), filter);
    std.debug.print("\n", .{});

    // 6. MessageRoutingThroughput
    runBench.run("RoutingThroughput/1_subscriber", 64, benchRoutingThroughput(1), filter);
    runBench.run("RoutingThroughput/5_subscribers", 64, benchRoutingThroughput(5), filter);
    std.debug.print("\n", .{});

    // 8. ConnectionThroughput
    runBench.run("ConnectionThroughput/v4", 0, benchConnectionThroughput(.v4), filter);
    runBench.run("ConnectionThroughput/v5", 0, benchConnectionThroughput(.v5), filter);
    std.debug.print("\n", .{});

    // 9. HighThroughputStress
    runBench.runRate("HighThroughputStress/4_pairs_256b", benchHighThroughputStress, filter);
    std.debug.print("\n", .{});

    // 10. MessageRate
    runBench.runRate("MessageRate/minimal_payload", benchMessageRate, filter);

    std.debug.print("\n=== Done ===\n\n", .{});
}
