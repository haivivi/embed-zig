//! MQTT Broker — Network-facing MQTT 5.0 & 3.1.1 broker
//!
//! Handles multiple client connections, routes messages via topic trie.
//! Supports MQTT 3.1.1 and 5.0 with auto protocol detection.
//!
//! ## Usage
//!
//! ```zig
//! const MyBroker = mqtt0.Broker(TcpSocket, Log, Time, 16);
//!
//! var broker = MyBroker.init(.{});
//!
//! // Accept loop (caller manages listener)
//! while (listener.accept()) |conn| {
//!     broker.handleClient(&conn, recv_buf, send_buf);
//! }
//! ```
//!
//! Note: This broker is single-threaded per-client. For multi-threaded usage,
//! wrap handleClient with WaitGroup.go() from the async framework.

const pkt = @import("packet.zig");
const v4_codec = @import("v4.zig");
const v5_codec = @import("v5.zig");
const trie_mod = @import("trie.zig");

const PacketType = pkt.PacketType;
const ProtocolVersion = pkt.ProtocolVersion;
const ReasonCode = pkt.ReasonCode;
const ConnectReturnCode = pkt.ConnectReturnCode;
const Message = pkt.Message;
const Handler = pkt.Handler;

// ============================================================================
// Authenticator
// ============================================================================

pub const Authenticator = struct {
    ctx: ?*anyopaque = null,
    /// Validate client credentials. Return true to allow.
    authenticateFn: *const fn (ctx: ?*anyopaque, client_id: []const u8, username: []const u8, password: []const u8) bool = allowAllAuth,
    /// Check publish/subscribe permissions. write=true for publish.
    aclFn: *const fn (ctx: ?*anyopaque, client_id: []const u8, topic: []const u8, write: bool) bool = allowAllAcl,

    pub fn authenticate(self: *const Authenticator, client_id: []const u8, username: []const u8, password: []const u8) bool {
        return self.authenticateFn(self.ctx, client_id, username, password);
    }

    pub fn acl(self: *const Authenticator, client_id: []const u8, topic: []const u8, write: bool) bool {
        return self.aclFn(self.ctx, client_id, topic, write);
    }
};

fn allowAllAuth(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}

fn allowAllAcl(_: ?*anyopaque, _: []const u8, _: []const u8, _: bool) bool {
    return true;
}

pub const allow_all = Authenticator{};

// ============================================================================
// Broker
// ============================================================================

/// MQTT Broker with configurable max clients.
///
/// Socket: fn send(*Self, []const u8) !usize, fn recv(*Self, []u8) !usize
/// Log:    fn info/warn/err(comptime fmt, args) void
/// Time:   fn getTimeMs() u64
/// max_clients: maximum concurrent connections
pub fn Broker(
    comptime Socket: type,
    comptime Log: type,
    comptime Time: type,
    comptime max_clients: usize,
) type {
    const SubscriptionTrie = trie_mod.Trie(u16, 256, max_clients); // value = client_index

    return struct {
        const Self = @This();

        pub const Options = struct {
            auth: Authenticator = allow_all,
            handler: ?Handler = null, // Global message handler
            max_topic_alias: u16 = 65535,
        };

        const ClientSlot = struct {
            active: bool = false,
            client_id_buf: [128]u8 = undefined,
            client_id_len: u8 = 0,
            protocol_version: ProtocolVersion = .v5,
            socket: ?*Socket = null,

            // v5 topic aliases (client→server direction, per-client)
            topic_aliases: [64]TopicAliasEntry = [_]TopicAliasEntry{.{}} ** 64,

            fn clientId(self: *const ClientSlot) []const u8 {
                return self.client_id_buf[0..self.client_id_len];
            }

            fn setClientId(self: *ClientSlot, id: []const u8) void {
                const len = @min(id.len, 128);
                for (id[0..len], 0..) |b, i| {
                    self.client_id_buf[i] = b;
                }
                self.client_id_len = @intCast(len);
            }
        };

        const TopicAliasEntry = struct {
            topic_buf: [256]u8 = undefined,
            topic_len: u16 = 0,
            used: bool = false,
        };

        opts: Options,
        clients: [max_clients]ClientSlot = [_]ClientSlot{.{}} ** max_clients,
        subscriptions: SubscriptionTrie = SubscriptionTrie.init(),
        running: bool = true,

        pub fn init(opts: Options) Self {
            return .{ .opts = opts };
        }

        /// Handle a single client connection (blocking, runs until disconnect).
        /// Call this from an accept loop. For concurrent clients, use WaitGroup.go().
        pub fn handleClient(self: *Self, socket: *Socket, recv_buf: []u8, send_buf: []u8) void {
            // Read first bytes to detect protocol version
            const peek_len = socket.recv(recv_buf) catch {
                Log.warn("Failed to read from new connection", .{});
                return;
            };

            if (peek_len == 0) return;

            const version = pkt.detectProtocolVersion(recv_buf[0..peek_len]) orelse {
                Log.warn("Failed to detect protocol version", .{});
                return;
            };

            switch (version) {
                .v4 => self.handleClientV4(socket, recv_buf, send_buf, peek_len),
                .v5 => self.handleClientV5(socket, recv_buf, send_buf, peek_len),
            }
        }

        /// Inject a message from the broker (routes to all matching subscribers).
        pub fn publish(self: *Self, topic: []const u8, payload: []const u8) void {
            const msg = Message{ .topic = topic, .payload = payload, .retain = false };

            if (self.opts.handler) |h| {
                h.handle(&msg);
            }

            self.routeMessage(topic, payload, false);
        }

        /// Get number of active clients.
        pub fn clientCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.clients) |*c| {
                if (c.active) count += 1;
            }
            return count;
        }

        /// Stop broker (will cause handleClient loops to exit).
        pub fn stop(self: *Self) void {
            self.running = false;
        }

        // ================================================================
        // V4 Connection Handler
        // ================================================================

        fn handleClientV4(self: *Self, socket: *Socket, recv_buf: []u8, send_buf: []u8, initial_len: usize) void {
            // Decode CONNECT (already in recv_buf)
            const result = v4_codec.decodePacket(recv_buf[0..initial_len]) catch {
                Log.warn("Malformed v4 CONNECT", .{});
                return;
            };

            const conn = switch (result.packet) {
                .connect => |c| c,
                else => {
                    Log.warn("Expected CONNECT, got other packet", .{});
                    return;
                },
            };

            // Authenticate
            if (!self.opts.auth.authenticate(
                conn.client_id,
                conn.username orelse "",
                conn.password orelse "",
            )) {
                Log.warn("Auth failed for {s}", .{conn.client_id});
                const len = v4_codec.encodeConnAck(send_buf, false, .not_authorized) catch return;
                self.socketSend(socket, send_buf[0..len]);
                return;
            }

            // Send CONNACK
            const connack_len = v4_codec.encodeConnAck(send_buf, false, .accepted) catch return;
            self.socketSend(socket, send_buf[0..connack_len]);

            // Register client
            const slot_idx = self.allocClientSlot(conn.client_id, socket, .v4) orelse {
                Log.warn("No client slots available", .{});
                return;
            };

            Log.info("Client connected: {s} (v4)", .{conn.client_id});

            // Client loop
            self.clientLoop(socket, recv_buf, send_buf, slot_idx, .v4);

            // Cleanup
            self.cleanupClient(slot_idx);
            Log.info("Client disconnected: {s}", .{self.clients[slot_idx].clientId()});
        }

        // ================================================================
        // V5 Connection Handler
        // ================================================================

        fn handleClientV5(self: *Self, socket: *Socket, recv_buf: []u8, send_buf: []u8, initial_len: usize) void {
            const result = v5_codec.decodePacket(recv_buf[0..initial_len]) catch {
                Log.warn("Malformed v5 CONNECT", .{});
                return;
            };

            const conn = switch (result.packet) {
                .connect => |c| c,
                else => {
                    Log.warn("Expected CONNECT, got other packet", .{});
                    return;
                },
            };

            if (!self.opts.auth.authenticate(
                conn.client_id,
                conn.username orelse "",
                conn.password orelse "",
            )) {
                Log.warn("Auth failed for {s}", .{conn.client_id});
                var props = v5_codec.Properties{};
                const len = v5_codec.encodeConnAck(send_buf, false, .not_authorized, &props) catch return;
                self.socketSend(socket, send_buf[0..len]);
                return;
            }

            // Send CONNACK with properties
            var connack_props = v5_codec.Properties{};
            connack_props.topic_alias_maximum = self.opts.max_topic_alias;
            const connack_len = v5_codec.encodeConnAck(send_buf, false, .success, &connack_props) catch return;
            self.socketSend(socket, send_buf[0..connack_len]);

            const slot_idx = self.allocClientSlot(conn.client_id, socket, .v5) orelse {
                Log.warn("No client slots available", .{});
                return;
            };

            Log.info("Client connected: {s} (v5)", .{conn.client_id});

            self.clientLoop(socket, recv_buf, send_buf, slot_idx, .v5);

            self.cleanupClient(slot_idx);
            Log.info("Client disconnected: {s}", .{self.clients[slot_idx].clientId()});
        }

        // ================================================================
        // Client Loop (shared v4/v5)
        // ================================================================

        fn clientLoop(self: *Self, socket: *Socket, recv_buf: []u8, send_buf: []u8, slot_idx: usize, version: ProtocolVersion) void {
            while (self.running) {
                const recv_len = socket.recv(recv_buf) catch |e| {
                    if (e == error.Timeout) continue;
                    return; // Connection error
                };

                if (recv_len == 0) return; // Connection closed

                switch (version) {
                    .v4 => {
                        if (!self.handleV4ClientPacket(socket, recv_buf[0..recv_len], send_buf, slot_idx)) return;
                    },
                    .v5 => {
                        if (!self.handleV5ClientPacket(socket, recv_buf[0..recv_len], send_buf, slot_idx)) return;
                    },
                }
            }
        }

        fn handleV4ClientPacket(self: *Self, socket: *Socket, data: []const u8, send_buf: []u8, slot_idx: usize) bool {
            const result = v4_codec.decodePacket(data) catch return true; // Skip malformed

            const client_id = self.clients[slot_idx].clientId();

            switch (result.packet) {
                .publish => |pub_pkt| {
                    if (!self.opts.auth.acl(client_id, pub_pkt.topic, true)) return true;

                    if (self.opts.handler) |h| {
                        const msg = Message{ .topic = pub_pkt.topic, .payload = pub_pkt.payload, .retain = pub_pkt.retain };
                        h.handle(&msg);
                    }

                    self.routeMessage(pub_pkt.topic, pub_pkt.payload, pub_pkt.retain);
                },
                .subscribe => |sub| {
                    var codes: [v4_codec.max_topics]u8 = undefined;
                    var i: usize = 0;
                    while (i < sub.topic_count) : (i += 1) {
                        if (self.opts.auth.acl(client_id, sub.topics[i], false)) {
                            self.subscriptions.insert(sub.topics[i], @intCast(slot_idx)) catch {
                                codes[i] = 0x80; // Failure
                                continue;
                            };
                            codes[i] = 0x00; // Success QoS 0
                        } else {
                            codes[i] = 0x80;
                        }
                    }
                    const len = v4_codec.encodeSubAck(send_buf, sub.packet_id, codes[0..sub.topic_count]) catch return true;
                    self.socketSend(socket, send_buf[0..len]);
                },
                .unsubscribe => |unsub| {
                    const idx: u16 = @intCast(slot_idx);
                    var i: usize = 0;
                    while (i < unsub.topic_count) : (i += 1) {
                        _ = self.subscriptions.remove(unsub.topics[i], struct {
                            fn pred(v: u16) bool {
                                _ = v;
                                return true; // Simple: remove all for this pattern
                            }
                        }.pred);
                        _ = idx;
                    }
                    const len = v4_codec.encodeUnsubAck(send_buf, unsub.packet_id) catch return true;
                    self.socketSend(socket, send_buf[0..len]);
                },
                .pingreq => {
                    const len = v4_codec.encodePingResp(send_buf) catch return true;
                    self.socketSend(socket, send_buf[0..len]);
                },
                .disconnect => return false,
                else => {},
            }

            return true;
        }

        fn handleV5ClientPacket(self: *Self, socket: *Socket, data: []const u8, send_buf: []u8, slot_idx: usize) bool {
            const result = v5_codec.decodePacket(data) catch return true;

            const client_id = self.clients[slot_idx].clientId();

            switch (result.packet) {
                .publish => |pub_pkt| {
                    var topic = pub_pkt.topic;

                    // Handle topic alias
                    if (pub_pkt.props.topic_alias) |alias| {
                        if (alias == 0 or alias > self.opts.max_topic_alias) return true; // Invalid alias

                        if (topic.len > 0) {
                            // Store alias mapping
                            self.storeClientTopicAlias(slot_idx, alias, topic);
                        } else {
                            // Resolve from alias
                            topic = self.resolveClientTopicAlias(slot_idx, alias) orelse return true;
                        }
                    }

                    if (topic.len == 0) return true;
                    if (!self.opts.auth.acl(client_id, topic, true)) return true;

                    if (self.opts.handler) |h| {
                        const msg = Message{ .topic = topic, .payload = pub_pkt.payload, .retain = pub_pkt.retain };
                        h.handle(&msg);
                    }

                    self.routeMessage(topic, pub_pkt.payload, pub_pkt.retain);
                },
                .subscribe => |sub| {
                    var codes: [v5_codec.max_topics]ReasonCode = undefined;
                    var i: usize = 0;
                    while (i < sub.filter_count) : (i += 1) {
                        if (self.opts.auth.acl(client_id, sub.filters[i].topic, false)) {
                            self.subscriptions.insert(sub.filters[i].topic, @intCast(slot_idx)) catch {
                                codes[i] = .unspecified_error;
                                continue;
                            };
                            codes[i] = .success;
                        } else {
                            codes[i] = .not_authorized;
                        }
                    }
                    const len = v5_codec.encodeSubAck(send_buf, sub.packet_id, codes[0..sub.filter_count]) catch return true;
                    self.socketSend(socket, send_buf[0..len]);
                },
                .unsubscribe => |unsub| {
                    var i: usize = 0;
                    while (i < unsub.topic_count) : (i += 1) {
                        _ = self.subscriptions.remove(unsub.topics[i], struct {
                            fn pred(_: u16) bool {
                                return true;
                            }
                        }.pred);
                    }
                    var codes: [v5_codec.max_topics]ReasonCode = undefined;
                    var j: usize = 0;
                    while (j < unsub.topic_count) : (j += 1) {
                        codes[j] = .success;
                    }
                    const len = v5_codec.encodeUnsubAck(send_buf, unsub.packet_id, codes[0..unsub.topic_count]) catch return true;
                    self.socketSend(socket, send_buf[0..len]);
                },
                .pingreq => {
                    const len = v5_codec.encodePingResp(send_buf) catch return true;
                    self.socketSend(socket, send_buf[0..len]);
                },
                .disconnect => return false,
                else => {},
            }

            return true;
        }

        // ================================================================
        // Message Routing
        // ================================================================

        fn routeMessage(self: *Self, topic: []const u8, payload: []const u8, retain: bool) void {
            var match_buf: [max_clients]u16 = undefined;
            const matches = self.subscriptions.get(topic, &match_buf);

            for (matches) |client_idx| {
                if (client_idx >= max_clients) continue;
                const slot = &self.clients[client_idx];
                if (!slot.active or slot.socket == null) continue;

                // Encode and send PUBLISH to subscriber
                var pub_buf: [4096]u8 = undefined;
                const opts = pkt.PublishOptions{ .topic = topic, .payload = payload, .retain = retain };

                const len = switch (slot.protocol_version) {
                    .v4 => v4_codec.encodePublish(&pub_buf, &opts) catch continue,
                    .v5 => blk: {
                        const props = v5_codec.Properties{};
                        break :blk v5_codec.encodePublish(&pub_buf, &opts, &props) catch continue;
                    },
                };

                self.socketSend(slot.socket.?, pub_buf[0..len]);
            }
        }

        // ================================================================
        // Client Management
        // ================================================================

        fn allocClientSlot(self: *Self, client_id: []const u8, socket: *Socket, version: ProtocolVersion) ?usize {
            // Check for duplicate client ID — disconnect old
            for (&self.clients, 0..) |*slot, i| {
                if (slot.active and eql(slot.clientId(), client_id)) {
                    self.cleanupClient(i);
                    break;
                }
            }

            // Find free slot
            for (&self.clients, 0..) |*slot, i| {
                if (!slot.active) {
                    slot.active = true;
                    slot.setClientId(client_id);
                    slot.protocol_version = version;
                    slot.socket = socket;
                    return i;
                }
            }
            return null;
        }

        fn cleanupClient(self: *Self, slot_idx: usize) void {
            // Remove all subscriptions for this client
            // (simplified: we'd need to track per-client subscriptions for efficient removal)
            self.clients[slot_idx].active = false;
            self.clients[slot_idx].socket = null;
            // Reset topic aliases
            for (&self.clients[slot_idx].topic_aliases) |*a| a.used = false;
        }

        // ================================================================
        // Topic Alias (v5, per-client)
        // ================================================================

        fn storeClientTopicAlias(self: *Self, slot_idx: usize, alias: u16, topic: []const u8) void {
            if (alias == 0 or alias > 64) return;
            const idx = alias - 1;
            const entry = &self.clients[slot_idx].topic_aliases[idx];
            const len = @min(topic.len, 256);
            for (topic[0..len], 0..) |b, i| {
                entry.topic_buf[i] = b;
            }
            entry.topic_len = @intCast(len);
            entry.used = true;
        }

        fn resolveClientTopicAlias(self: *Self, slot_idx: usize, alias: u16) ?[]const u8 {
            if (alias == 0 or alias > 64) return null;
            const idx = alias - 1;
            const entry = &self.clients[slot_idx].topic_aliases[idx];
            if (!entry.used) return null;
            return entry.topic_buf[0..entry.topic_len];
        }

        // ================================================================
        // Utility
        // ================================================================

        fn socketSend(self: *Self, socket: *Socket, data: []const u8) void {
            _ = self;
            var sent: usize = 0;
            while (sent < data.len) {
                const n = socket.send(data[sent..]) catch return;
                if (n == 0) return;
                sent += n;
            }
        }

        /// Get current time in milliseconds (from platform Time type).
        pub fn now() u64 {
            return Time.getTimeMs();
        }
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

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
        if (self.recv_pos >= self.recv_len) return 0; // Connection closed
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

    fn reset(self: *MockSocket) void {
        self.send_len = 0;
        self.recv_len = 0;
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

const TestBroker = Broker(MockSocket, MockLog, MockTime, 4);

test "Broker: init" {
    const broker = TestBroker.init(.{});
    if (broker.clientCount() != 0) return error.TestExpectedEqual;
}

test "Broker: v4 client connect then close" {
    var broker = TestBroker.init(.{});
    var socket = MockSocket{};

    // Prepare CONNECT packet only — socket will return 0 (closed) on next read
    var connect_buf: [256]u8 = undefined;
    const config = pkt.ConnectConfig{
        .client_id = "test-client",
        .protocol_version = .v4,
    };
    const connect_len = v4_codec.encodeConnect(&connect_buf, &config) catch return error.TestExpectedEqual;
    socket.setRecvData(connect_buf[0..connect_len]);

    var recv_buf: [4096]u8 = undefined;
    var send_buf: [4096]u8 = undefined;
    broker.handleClient(&socket, &recv_buf, &send_buf);

    // Should have sent CONNACK
    if (socket.send_len == 0) return error.TestExpectedEqual;

    // Verify CONNACK
    const result = v4_codec.decodePacket(socket.send_buf[0..socket.send_len]) catch return error.TestExpectedEqual;
    switch (result.packet) {
        .connack => |ack| {
            if (ack.return_code != .accepted) return error.TestExpectedEqual;
        },
        else => return error.TestExpectedEqual,
    }
}

test "Broker: authenticator deny" {
    const deny_auth = Authenticator{
        .authenticateFn = struct {
            fn auth(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
                return false;
            }
        }.auth,
    };

    var broker = TestBroker.init(.{ .auth = deny_auth });
    var socket = MockSocket{};

    var connect_buf: [256]u8 = undefined;
    const config = pkt.ConnectConfig{
        .client_id = "denied",
        .protocol_version = .v4,
    };
    const connect_len = v4_codec.encodeConnect(&connect_buf, &config) catch return error.TestExpectedEqual;
    socket.setRecvData(connect_buf[0..connect_len]);

    var recv_buf: [4096]u8 = undefined;
    var send_buf: [4096]u8 = undefined;
    broker.handleClient(&socket, &recv_buf, &send_buf);

    // Should have sent CONNACK with not_authorized
    if (socket.send_len == 0) return error.TestExpectedEqual;
    const result = v4_codec.decodePacket(socket.send_buf[0..socket.send_len]) catch return error.TestExpectedEqual;
    switch (result.packet) {
        .connack => |ack| {
            if (ack.return_code != .not_authorized) return error.TestExpectedEqual;
        },
        else => return error.TestExpectedEqual,
    }
}
