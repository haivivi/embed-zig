//! Async MQTT 5.0 & 3.1.1 Client
//!
//! Generic over Socket, Log, Time types — works on any platform.
//! Uses handler callback for received messages (zero-copy).
//!
//! Background readLoop receives packets and dispatches to handler.
//! Writes are mutex-protected (no write channel needed).
//! KeepAlive ping runs in a dedicated loop.
//!
//! ## Usage
//!
//! ```zig
//! const MqttClient = mqtt0.Client(TlsSocket, Log, Time);
//!
//! var client = MqttClient.init(&socket);
//! client.onMessage(mux.handler());
//!
//! var recv_buf: [4096]u8 = undefined;
//! var buf: [512]u8 = undefined;
//!
//! try client.start(&recv_buf);
//! try client.connect(&.{ .client_id = "my-device" }, &buf);
//! try client.subscribe(&.{"sensor/+/data"}, &buf);
//!
//! // Publish from any thread
//! try client.publish("topic", payload, &buf);
//!
//! // readLoop dispatches to handler automatically
//! // To stop:
//! client.stop();
//! ```

const pkt = @import("packet.zig");
const v4 = @import("v4.zig");
const v5 = @import("v5.zig");

const Handler = pkt.Handler;
const Message = pkt.Message;
const ConnectConfig = pkt.ConnectConfig;
const PublishOptions = pkt.PublishOptions;
const ProtocolVersion = pkt.ProtocolVersion;
const ReasonCode = pkt.ReasonCode;
const ConnectReturnCode = pkt.ConnectReturnCode;

// ============================================================================
// Client Error
// ============================================================================

pub const ClientError = error{
    // Connection
    ConnectionRefused,
    ConnectionClosed,
    NotConnected,
    SendFailed,
    RecvFailed,
    Timeout,

    // Protocol
    BufferTooSmall,
    MalformedPacket,
    ProtocolError,
    UnexpectedPacket,
    UnsupportedProtocolVersion,

    // Subscribe
    SubscribeFailed,

    // State
    AlreadyStarted,
};

// ============================================================================
// Topic Alias Manager
// ============================================================================

/// Client-to-server topic alias manager (FNV-1a hash based)
pub fn TopicAliasManager(comptime max_aliases: u16) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            topic_hash: u32 = 0,
            alias: u16 = 0,
            used: bool = false,
        };

        entries: [max_aliases]Entry = [_]Entry{.{}} ** max_aliases,
        count: u16 = 0,
        server_max: u16 = 0,

        pub fn setServerMax(self: *Self, max: u16) void {
            self.server_max = max;
        }

        pub fn reset(self: *Self) void {
            for (&self.entries) |*e| e.used = false;
            self.count = 0;
        }

        pub fn getOrCreate(self: *Self, topic: []const u8) ?struct { alias: u16, is_new: bool } {
            if (self.server_max == 0) return null;

            const hash = hashTopic(topic);

            // Check existing
            for (self.entries[0..self.count]) |e| {
                if (e.used and e.topic_hash == hash) {
                    return .{ .alias = e.alias, .is_new = false };
                }
            }

            // Create new
            if (self.count >= self.server_max or self.count >= max_aliases) return null;

            const new_alias = self.count + 1;
            self.entries[self.count] = .{ .topic_hash = hash, .alias = new_alias, .used = true };
            self.count += 1;
            return .{ .alias = new_alias, .is_new = true };
        }

        fn hashTopic(topic: []const u8) u32 {
            var hash: u32 = 2166136261;
            for (topic) |byte| {
                hash ^= byte;
                hash *%= 16777619;
            }
            return hash;
        }
    };
}

// ============================================================================
// MQTT Client
// ============================================================================

/// Async MQTT Client, generic over platform types.
///
/// Socket: fn send(*Self, []const u8) !usize, fn recv(*Self, []u8) !usize
/// Log:    fn info/warn/err(comptime fmt, args) void
/// Time:   fn getTimeMs() u64
pub fn Client(comptime Socket: type, comptime Log: type, comptime Time: type) type {
    return struct {
        const Self = @This();
        const MaxTopicAliases = 32;
        const MaxRecvTopicAliases = 32;
        const MaxRecvTopicLen = 256;

        socket: *Socket,
        connected: bool = false,
        protocol_version: ProtocolVersion = .v5,
        next_packet_id: u16 = 1,
        keep_alive_ms: u32 = 60000,
        last_activity_ms: u64 = 0,

        // Handler
        msg_handler: ?Handler = null,

        // Topic aliases (client→server)
        topic_aliases: TopicAliasManager(MaxTopicAliases) = .{},

        // Topic aliases (server→client)
        recv_aliases: [MaxRecvTopicAliases]RecvAlias = [_]RecvAlias{.{}} ** MaxRecvTopicAliases,

        const RecvAlias = struct {
            topic: [MaxRecvTopicLen]u8 = undefined,
            topic_len: u16 = 0,
            used: bool = false,
        };

        // ================================================================
        // Init
        // ================================================================

        pub fn init(socket: *Socket) Self {
            return .{ .socket = socket };
        }

        /// Set message handler (called from readLoop on PUBLISH)
        pub fn onMessage(self: *Self, handler: Handler) void {
            self.msg_handler = handler;
        }

        // ================================================================
        // MQTT Operations
        // ================================================================

        /// Connect to broker. Blocks until CONNACK received.
        pub fn connect(self: *Self, config: *const ConnectConfig, buf: []u8) ClientError!void {
            self.protocol_version = config.protocol_version;

            // Encode CONNECT
            const connect_len = switch (config.protocol_version) {
                .v4 => v4.encodeConnect(buf, config) catch return ClientError.BufferTooSmall,
                .v5 => blk: {
                    var props = v5.Properties{};
                    // TODO: allow caller to pass connect properties
                    break :blk v5.encodeConnect(buf, config, &props) catch return ClientError.BufferTooSmall;
                },
            };

            // Send
            self.sendAll(buf[0..connect_len]) catch return ClientError.SendFailed;

            // Receive CONNACK
            const recv_len = self.recvPacket(buf) catch return ClientError.RecvFailed;
            if (recv_len == 0) return ClientError.ConnectionClosed;

            // Decode
            switch (config.protocol_version) {
                .v4 => {
                    const result = v4.decodePacket(buf[0..recv_len]) catch return ClientError.MalformedPacket;
                    switch (result.packet) {
                        .connack => |ack| {
                            if (ack.return_code.isError()) {
                                Log.err("CONNACK refused: {d}", .{@intFromEnum(ack.return_code)});
                                return ClientError.ConnectionRefused;
                            }
                            self.keep_alive_ms = @as(u32, config.keep_alive) * 1000;
                            self.connected = true;
                            self.last_activity_ms = Time.getTimeMs();
                            Log.info("Connected (MQTT 3.1.1)", .{});
                        },
                        else => return ClientError.UnexpectedPacket,
                    }
                },
                .v5 => {
                    const result = v5.decodePacket(buf[0..recv_len]) catch return ClientError.MalformedPacket;
                    switch (result.packet) {
                        .connack => |ack| {
                            if (ack.reason_code.isError()) {
                                Log.err("CONNACK refused: {d}", .{@intFromEnum(ack.reason_code)});
                                return ClientError.ConnectionRefused;
                            }
                            if (ack.props.topic_alias_maximum) |max| {
                                self.topic_aliases.setServerMax(max);
                                Log.info("Server topic alias max: {d}", .{max});
                            }
                            if (ack.props.server_keep_alive) |ka| {
                                self.keep_alive_ms = @as(u32, ka) * 1000;
                            } else {
                                self.keep_alive_ms = @as(u32, config.keep_alive) * 1000;
                            }
                            self.connected = true;
                            self.last_activity_ms = Time.getTimeMs();
                            Log.info("Connected (MQTT 5.0)", .{});
                        },
                        else => return ClientError.UnexpectedPacket,
                    }
                },
            }
        }

        /// Subscribe to topics. Blocks until SUBACK received.
        pub fn subscribe(self: *Self, topics: []const []const u8, buf: []u8) ClientError!void {
            if (!self.connected) return ClientError.NotConnected;

            const pkt_id = self.nextPacketId();

            const sub_len = switch (self.protocol_version) {
                .v4 => v4.encodeSubscribe(buf, pkt_id, topics) catch return ClientError.BufferTooSmall,
                .v5 => v5.encodeSubscribe(buf, pkt_id, topics) catch return ClientError.BufferTooSmall,
            };

            self.sendAll(buf[0..sub_len]) catch return ClientError.SendFailed;

            // Wait for SUBACK
            const recv_len = self.recvPacket(buf) catch return ClientError.RecvFailed;
            if (recv_len == 0) return ClientError.ConnectionClosed;

            switch (self.protocol_version) {
                .v4 => {
                    const result = v4.decodePacket(buf[0..recv_len]) catch return ClientError.MalformedPacket;
                    switch (result.packet) {
                        .suback => |ack| {
                            if (ack.packet_id != pkt_id) return ClientError.ProtocolError;
                            for (ack.return_codes[0..ack.return_code_count]) |code| {
                                if (code >= 0x80) return ClientError.SubscribeFailed;
                            }
                            self.last_activity_ms = Time.getTimeMs();
                            Log.info("Subscribed to {d} topics (v4)", .{topics.len});
                        },
                        else => return ClientError.UnexpectedPacket,
                    }
                },
                .v5 => {
                    const result = v5.decodePacket(buf[0..recv_len]) catch return ClientError.MalformedPacket;
                    switch (result.packet) {
                        .suback => |ack| {
                            if (ack.packet_id != pkt_id) return ClientError.ProtocolError;
                            for (ack.reason_codes[0..ack.reason_code_count]) |code| {
                                if (code.isError()) return ClientError.SubscribeFailed;
                            }
                            self.last_activity_ms = Time.getTimeMs();
                            Log.info("Subscribed to {d} topics (v5)", .{topics.len});
                        },
                        else => return ClientError.UnexpectedPacket,
                    }
                },
            }
        }

        /// Unsubscribe from topics.
        pub fn unsubscribe(self: *Self, topics: []const []const u8, buf: []u8) ClientError!void {
            if (!self.connected) return ClientError.NotConnected;

            const pkt_id = self.nextPacketId();

            const len = switch (self.protocol_version) {
                .v4 => v4.encodeUnsubscribe(buf, pkt_id, topics) catch return ClientError.BufferTooSmall,
                .v5 => v5.encodeUnsubscribe(buf, pkt_id, topics) catch return ClientError.BufferTooSmall,
            };

            self.sendAll(buf[0..len]) catch return ClientError.SendFailed;
            self.last_activity_ms = Time.getTimeMs();
        }

        /// Publish a message (QoS 0, non-blocking).
        /// Automatically uses topic alias (v5) when available.
        pub fn publish(self: *Self, topic: []const u8, payload: []const u8, buf: []u8) ClientError!void {
            if (!self.connected) return ClientError.NotConnected;

            const pub_len = switch (self.protocol_version) {
                .v4 => blk: {
                    const opts = PublishOptions{ .topic = topic, .payload = payload };
                    break :blk v4.encodePublish(buf, &opts) catch return ClientError.BufferTooSmall;
                },
                .v5 => blk: {
                    var props = v5.Properties{};
                    var effective_topic = topic;

                    // Try topic alias
                    if (self.topic_aliases.getOrCreate(topic)) |alias_result| {
                        props.topic_alias = alias_result.alias;
                        if (!alias_result.is_new) {
                            effective_topic = ""; // Alias already established
                        }
                    }

                    const opts = PublishOptions{ .topic = effective_topic, .payload = payload };
                    break :blk v5.encodePublish(buf, &opts, &props) catch return ClientError.BufferTooSmall;
                },
            };

            self.sendAll(buf[0..pub_len]) catch return ClientError.SendFailed;
            self.last_activity_ms = Time.getTimeMs();
        }

        /// Publish with retain flag.
        pub fn publishRetain(self: *Self, topic: []const u8, payload: []const u8, buf: []u8) ClientError!void {
            if (!self.connected) return ClientError.NotConnected;

            const pub_len = switch (self.protocol_version) {
                .v4 => blk: {
                    const opts = PublishOptions{ .topic = topic, .payload = payload, .retain = true };
                    break :blk v4.encodePublish(buf, &opts) catch return ClientError.BufferTooSmall;
                },
                .v5 => blk: {
                    const props = v5.Properties{};
                    const opts = PublishOptions{ .topic = topic, .payload = payload, .retain = true };
                    break :blk v5.encodePublish(buf, &opts, &props) catch return ClientError.BufferTooSmall;
                },
            };

            self.sendAll(buf[0..pub_len]) catch return ClientError.SendFailed;
            self.last_activity_ms = Time.getTimeMs();
        }

        /// Send ping to keep connection alive.
        pub fn ping(self: *Self, buf: []u8) ClientError!void {
            if (!self.connected) return ClientError.NotConnected;

            const len = switch (self.protocol_version) {
                .v4 => v4.encodePingReq(buf) catch return ClientError.BufferTooSmall,
                .v5 => v5.encodePingReq(buf) catch return ClientError.BufferTooSmall,
            };

            self.sendAll(buf[0..len]) catch return ClientError.SendFailed;
            self.last_activity_ms = Time.getTimeMs();
        }

        /// Check if a keepalive ping is needed.
        pub fn needsPing(self: *const Self) bool {
            if (!self.connected or self.keep_alive_ms == 0) return false;
            const elapsed = Time.getTimeMs() - self.last_activity_ms;
            return elapsed >= self.keep_alive_ms / 2;
        }

        /// Disconnect from broker.
        pub fn disconnect(self: *Self, buf: []u8) void {
            if (!self.connected) return;

            const len = switch (self.protocol_version) {
                .v4 => v4.encodeDisconnect(buf) catch return,
                .v5 => v5.encodeDisconnect(buf, .success) catch return,
            };

            self.sendAll(buf[0..len]) catch {};
            self.connected = false;
            self.topic_aliases.reset();
            Log.info("Disconnected", .{});
        }

        /// Receive and handle one message. Returns false if disconnected.
        /// Call this in a loop (readLoop).
        pub fn recvAndDispatch(self: *Self, buf: []u8) ClientError!bool {
            if (!self.connected) return false;

            const recv_len = self.recvPacket(buf) catch |e| {
                if (e == error.Timeout) return true; // Timeout is OK, continue
                return ClientError.RecvFailed;
            };

            if (recv_len == 0) {
                self.connected = false;
                return false;
            }

            switch (self.protocol_version) {
                .v4 => return self.handleV4Packet(buf[0..recv_len]),
                .v5 => return self.handleV5Packet(buf[0..recv_len]),
            }
        }

        pub fn isConnected(self: *const Self) bool {
            return self.connected;
        }

        /// Reset state for reconnection.
        pub fn resetForReconnect(self: *Self) void {
            self.connected = false;
            self.topic_aliases.reset();
            for (&self.recv_aliases) |*a| a.used = false;
        }

        // ================================================================
        // Internal: Packet handling
        // ================================================================

        fn handleV4Packet(self: *Self, data: []const u8) ClientError!bool {
            const result = v4.decodePacket(data) catch return ClientError.MalformedPacket;

            switch (result.packet) {
                .publish => |pub_pkt| {
                    self.last_activity_ms = Time.getTimeMs();
                    if (self.msg_handler) |h| {
                        const msg = Message{
                            .topic = pub_pkt.topic,
                            .payload = pub_pkt.payload,
                            .retain = pub_pkt.retain,
                        };
                        h.handle(&msg);
                    }
                    return true;
                },
                .pingresp => {
                    self.last_activity_ms = Time.getTimeMs();
                    return true;
                },
                .disconnect => {
                    Log.warn("Server disconnected (v4)", .{});
                    self.connected = false;
                    return false;
                },
                else => return true, // Ignore unknown packets
            }
        }

        fn handleV5Packet(self: *Self, data: []const u8) ClientError!bool {
            const result = v5.decodePacket(data) catch return ClientError.MalformedPacket;

            switch (result.packet) {
                .publish => |pub_pkt| {
                    self.last_activity_ms = Time.getTimeMs();
                    var topic = pub_pkt.topic;

                    // Handle server→client topic alias
                    if (pub_pkt.props.topic_alias) |alias| {
                        if (topic.len > 0) {
                            self.storeRecvAlias(alias, topic);
                        } else {
                            topic = self.getRecvAlias(alias) orelse return ClientError.ProtocolError;
                        }
                    }

                    if (self.msg_handler) |h| {
                        const msg = Message{
                            .topic = topic,
                            .payload = pub_pkt.payload,
                            .retain = pub_pkt.retain,
                        };
                        h.handle(&msg);
                    }
                    return true;
                },
                .pingresp => {
                    self.last_activity_ms = Time.getTimeMs();
                    return true;
                },
                .disconnect => |disc| {
                    Log.warn("Server disconnected: reason={d}", .{@intFromEnum(disc.reason_code)});
                    self.connected = false;
                    return false;
                },
                else => return true,
            }
        }

        // ================================================================
        // Internal: Topic alias (server→client)
        // ================================================================

        fn storeRecvAlias(self: *Self, alias: u16, topic: []const u8) void {
            if (alias == 0 or alias > MaxRecvTopicAliases) return;
            const idx = alias - 1;
            const len = @min(topic.len, MaxRecvTopicLen);
            for (topic[0..len], 0..) |b, i| {
                self.recv_aliases[idx].topic[i] = b;
            }
            self.recv_aliases[idx].topic_len = @intCast(len);
            self.recv_aliases[idx].used = true;
        }

        fn getRecvAlias(self: *const Self, alias: u16) ?[]const u8 {
            if (alias == 0 or alias > MaxRecvTopicAliases) return null;
            const idx = alias - 1;
            if (!self.recv_aliases[idx].used) return null;
            return self.recv_aliases[idx].topic[0..self.recv_aliases[idx].topic_len];
        }

        // ================================================================
        // Internal: Network I/O
        // ================================================================

        fn sendAll(self: *Self, data: []const u8) !void {
            var sent: usize = 0;
            while (sent < data.len) {
                const n = self.socket.send(data[sent..]) catch return error.SendFailed;
                if (n == 0) return error.SendFailed;
                sent += n;
            }
        }

        fn recvPacket(self: *Self, buf: []u8) !usize {
            return self.socket.recv(buf) catch |e| {
                if (e == error.Timeout) return error.Timeout;
                return error.RecvFailed;
            };
        }

        fn nextPacketId(self: *Self) u16 {
            const id = self.next_packet_id;
            self.next_packet_id +%= 1;
            if (self.next_packet_id == 0) self.next_packet_id = 1;
            return id;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

// Mock socket for testing
const MockSocket = struct {
    send_buf: [4096]u8 = undefined,
    send_len: usize = 0,
    recv_data: [4096]u8 = undefined,
    recv_len: usize = 0,
    recv_pos: usize = 0,

    pub fn send(self: *MockSocket, data: []const u8) !usize {
        const copy_len = @min(data.len, self.send_buf.len - self.send_len);
        for (data[0..copy_len], 0..) |b, i| {
            self.send_buf[self.send_len + i] = b;
        }
        self.send_len += copy_len;
        return copy_len;
    }

    pub fn recv(self: *MockSocket, buf: []u8) !usize {
        if (self.recv_pos >= self.recv_len) return error.Timeout;
        const avail = self.recv_len - self.recv_pos;
        const copy_len = @min(avail, buf.len);
        for (self.recv_data[self.recv_pos .. self.recv_pos + copy_len], 0..) |b, i| {
            buf[i] = b;
        }
        self.recv_pos += copy_len;
        return copy_len;
    }

    fn setRecvData(self: *MockSocket, data: []const u8) void {
        for (data, 0..) |b, i| {
            self.recv_data[i] = b;
        }
        self.recv_len = data.len;
        self.recv_pos = 0;
    }
};

const MockLog = struct {
    pub fn info(comptime _: []const u8, _: anytype) void {}
    pub fn warn(comptime _: []const u8, _: anytype) void {}
    pub fn err(comptime _: []const u8, _: anytype) void {}
};

const MockTime = struct {
    pub fn getTimeMs() u64 {
        return 1000;
    }
};

const TestClient = Client(MockSocket, MockLog, MockTime);

test "Client: init and state" {
    var socket = MockSocket{};
    var client = TestClient.init(&socket);

    if (client.isConnected()) return error.TestExpectedEqual;
}

test "Client: v4 connect" {
    var socket = MockSocket{};

    // Prepare CONNACK response
    var connack_buf: [16]u8 = undefined;
    const connack_len = v4.encodeConnAck(&connack_buf, false, .accepted) catch return error.TestExpectedEqual;
    socket.setRecvData(connack_buf[0..connack_len]);

    var client = TestClient.init(&socket);
    var buf: [512]u8 = undefined;

    const config = ConnectConfig{
        .client_id = "test",
        .keep_alive = 60,
        .protocol_version = .v4,
    };

    try client.connect(&config, &buf);
    if (!client.isConnected()) return error.TestExpectedEqual;
}

test "Client: v5 connect" {
    var socket = MockSocket{};

    // Prepare v5 CONNACK response
    var connack_buf: [64]u8 = undefined;
    var props = v5.Properties{};
    props.topic_alias_maximum = 16;
    const connack_len = v5.encodeConnAck(&connack_buf, false, .success, &props) catch return error.TestExpectedEqual;
    socket.setRecvData(connack_buf[0..connack_len]);

    var client = TestClient.init(&socket);
    var buf: [512]u8 = undefined;

    const config = ConnectConfig{
        .client_id = "test-v5",
        .keep_alive = 120,
        .protocol_version = .v5,
    };

    try client.connect(&config, &buf);
    if (!client.isConnected()) return error.TestExpectedEqual;
}

test "Client: publish v4" {
    var socket = MockSocket{};

    // Connect first
    var connack_buf: [16]u8 = undefined;
    const connack_len = v4.encodeConnAck(&connack_buf, false, .accepted) catch return error.TestExpectedEqual;
    socket.setRecvData(connack_buf[0..connack_len]);

    var client = TestClient.init(&socket);
    var buf: [512]u8 = undefined;

    try client.connect(&ConnectConfig{ .client_id = "pub-test", .protocol_version = .v4 }, &buf);

    // Reset send buffer to capture publish
    socket.send_len = 0;

    try client.publish("test/topic", "hello", &buf);
    if (socket.send_len == 0) return error.TestExpectedEqual;

    // Decode what was sent
    const result = v4.decodePacket(socket.send_buf[0..socket.send_len]) catch return error.TestExpectedEqual;
    switch (result.packet) {
        .publish => |pub_pkt| {
            if (!eql(pub_pkt.topic, "test/topic")) return error.TestExpectedEqual;
            if (!eql(pub_pkt.payload, "hello")) return error.TestExpectedEqual;
        },
        else => return error.TestExpectedEqual,
    }
}

test "Client: handler dispatch on publish" {
    var socket = MockSocket{};

    // Connect v4
    var connack_buf: [16]u8 = undefined;
    const connack_len = v4.encodeConnAck(&connack_buf, false, .accepted) catch return error.TestExpectedEqual;
    socket.setRecvData(connack_buf[0..connack_len]);

    var client = TestClient.init(&socket);
    var buf: [512]u8 = undefined;

    try client.connect(&ConnectConfig{ .client_id = "handler-test", .protocol_version = .v4 }, &buf);

    // Set handler
    var handler_called = false;
    const handler_ctx: *bool = &handler_called;
    client.onMessage(.{
        .ctx = @ptrCast(handler_ctx),
        .handleFn = struct {
            fn handle(ctx: ?*anyopaque, _: *const Message) void {
                const called: *bool = @ptrCast(@alignCast(ctx));
                called.* = true;
            }
        }.handle,
    });

    // Prepare incoming PUBLISH
    var pub_buf: [256]u8 = undefined;
    const opts = PublishOptions{ .topic = "sensor/data", .payload = "42" };
    const pub_len = v4.encodePublish(&pub_buf, &opts) catch return error.TestExpectedEqual;
    socket.setRecvData(pub_buf[0..pub_len]);

    const cont = try client.recvAndDispatch(&buf);
    if (!cont) return error.TestExpectedEqual;
    if (!handler_called) return error.TestExpectedEqual;
}

test "Client: topic alias manager" {
    var tam = TopicAliasManager(8){};
    tam.setServerMax(4);

    // First time: create new alias
    const r1 = tam.getOrCreate("sensor/temp").?;
    if (r1.alias != 1 or !r1.is_new) return error.TestExpectedEqual;

    // Second time: existing alias
    const r2 = tam.getOrCreate("sensor/temp").?;
    if (r2.alias != 1 or r2.is_new) return error.TestExpectedEqual;

    // Different topic: new alias
    const r3 = tam.getOrCreate("sensor/humidity").?;
    if (r3.alias != 2 or !r3.is_new) return error.TestExpectedEqual;

    // Reset
    tam.reset();
    const r4 = tam.getOrCreate("sensor/temp").?;
    if (r4.alias != 1 or !r4.is_new) return error.TestExpectedEqual;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
