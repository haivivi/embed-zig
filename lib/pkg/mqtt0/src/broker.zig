//! MQTT Broker — accepts connections, handles auth, routes messages.
//!
//! Generic over Transport type. User controls the accept loop.
//! Each connection is handled by serveConn (run in a thread/task).
//!
//! Usage:
//!     var mux = try Mux.init(allocator);
//!     try mux.handleFn("device/#", handleAll);
//!
//!     var broker = try Broker(Socket).init(allocator, mux.handler(), .{});
//!     // User controls accept loop:
//!     while (try listener.accept()) |conn| {
//!         spawn(Broker(Socket).serveConn, .{&broker, conn});
//!     }

const std = @import("std");
const Allocator = std.mem.Allocator;
const pkt = @import("packet.zig");
const v4 = @import("v4.zig");
const v5 = @import("v5.zig");
const mux_mod = @import("mux.zig");
const trie_mod = @import("trie.zig");

const Message = pkt.Message;
const Handler = mux_mod.Handler;
const ProtocolVersion = pkt.ProtocolVersion;

// ============================================================================
// Authenticator
// ============================================================================

pub const Authenticator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        authenticate: *const fn (ptr: *anyopaque, client_id: []const u8, username: []const u8, password: []const u8) bool,
        acl: *const fn (ptr: *anyopaque, client_id: []const u8, topic: []const u8, write: bool) bool,
    };

    pub fn authenticate(self: Authenticator, client_id: []const u8, username: []const u8, password: []const u8) bool {
        return self.vtable.authenticate(self.ptr, client_id, username, password);
    }

    pub fn acl(self: Authenticator, client_id: []const u8, topic: []const u8, write: bool) bool {
        return self.vtable.acl(self.ptr, client_id, topic, write);
    }
};

/// AllowAll authenticator
pub const AllowAll = struct {
    pub fn authenticator() Authenticator {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .authenticate = struct {
                    fn f(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
                        return true;
                    }
                }.f,
                .acl = struct {
                    fn f(_: *anyopaque, _: []const u8, _: []const u8, _: bool) bool {
                        return true;
                    }
                }.f,
            },
        };
    }
};

// ============================================================================
// Client Handle (internal, per-connection state)
// ============================================================================

const ClientHandle = struct {
    client_id: []const u8,
    // In a full implementation, this would have a message channel
    // For now, we track connections for subscription routing
};

// ============================================================================
// Broker
// ============================================================================

pub fn Broker(comptime Transport: type) type {
    return struct {
        const Self = @This();

        pub const Config = struct {
            max_packet_size: usize = pkt.max_packet_size,
        };

        allocator: Allocator,
        handler: Handler,
        auth: Authenticator,
        config: Config,
        // Subscription trie: topic pattern → list of transports to forward to
        subscriptions: trie_mod.Trie(*Transport),
        sub_mutex: std.Thread.Mutex,

        pub fn init(allocator: Allocator, handler: Handler, config: Config) !Self {
            return .{
                .allocator = allocator,
                .handler = handler,
                .auth = AllowAll.authenticator(),
                .config = config,
                .subscriptions = try trie_mod.Trie(*Transport).init(allocator),
                .sub_mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.subscriptions.deinit();
        }

        pub fn setAuthenticator(self: *Self, auth: Authenticator) void {
            self.auth = auth;
        }

        /// Handle a single client connection. Blocks until disconnect.
        /// Call this in a separate thread/task per connection.
        pub fn serveConn(self: *Self, transport: *Transport) void {
            self.serveConnInner(transport) catch {};
        }

        fn serveConnInner(self: *Self, transport: *Transport) !void {
            var buf: [8192]u8 = undefined;

            // Read first packet (must be CONNECT)
            const first_len = try pkt.readPacket(transport, &buf);
            if (first_len < 2) return;

            // Detect protocol version by peeking at protocol level byte
            const version = detectVersion(buf[0..first_len]) catch return;

            switch (version) {
                .v4 => try self.handleV4(transport, &buf, buf[0..first_len]),
                .v5 => try self.handleV5(transport, &buf, buf[0..first_len]),
            }
        }

        fn handleV4(self: *Self, transport: *Transport, buf: *[8192]u8, connect_data: []const u8) !void {
            const result = try v4.decodePacket(connect_data);
            const connect = switch (result.packet) {
                .connect => |c| c,
                else => return,
            };

            // Authenticate
            if (!self.auth.authenticate(connect.client_id, connect.username, connect.password)) {
                const len = try v4.encodeConnAck(buf, &.{
                    .session_present = false,
                    .return_code = .not_authorized,
                });
                pkt.writeAll(transport, buf[0..len]) catch {};
                return;
            }

            // Send CONNACK (accepted)
            const ca_len = try v4.encodeConnAck(buf, &.{
                .session_present = false,
                .return_code = .accepted,
            });
            try pkt.writeAll(transport, buf[0..ca_len]);

            // Main loop
            while (true) {
                const pkt_len = pkt.readPacket(transport, buf) catch return;
                const hdr = pkt.decodeFixedHeader(buf[0..pkt_len]) catch return;

                switch (hdr.packet_type) {
                    .publish => {
                        const pr = v4.decodePacket(buf[0..pkt_len]) catch continue;
                        const p = pr.packet.publish;
                        // Check ACL
                        if (!self.auth.acl(connect.client_id, p.topic, true)) continue;
                        // Dispatch to handler
                        const msg = Message{
                            .topic = p.topic,
                            .payload = p.payload,
                            .retain = p.retain,
                        };
                        self.handler.handleMessage(&msg) catch {};
                        // Route to subscribers
                        self.routeMessage(&msg, transport);
                    },
                    .subscribe => {
                        // Decode and process subscribe
                        const payload = buf[hdr.header_len..pkt_len];
                        const pid = pkt.decodeU16(payload[0..2]) catch continue;
                        var it = v4.SubscribeTopicIterator.init(payload, true);
                        var codes_buf: [32]u8 = undefined;
                        var code_count: usize = 0;
                        while (it.next() catch null) |topic_info| {
                            if (!self.auth.acl(connect.client_id, topic_info.topic, false)) {
                                codes_buf[code_count] = 0x80; // Failure
                            } else {
                                // Add to subscription trie
                                self.sub_mutex.lock();
                                self.subscriptions.insert(topic_info.topic, transport) catch {};
                                self.sub_mutex.unlock();
                                codes_buf[code_count] = 0x00; // QoS 0
                            }
                            code_count += 1;
                        }
                        // Send SUBACK
                        const sa = v4.SubAck{
                            .packet_id = pid,
                            .return_codes = codes_buf[0..code_count],
                        };
                        const sa_len = v4.encodeSubAck(buf, &sa) catch continue;
                        pkt.writeAll(transport, buf[0..sa_len]) catch return;
                    },
                    .unsubscribe => {
                        const payload = buf[hdr.header_len..pkt_len];
                        const pid = pkt.decodeU16(payload[0..2]) catch continue;
                        // Send UNSUBACK
                        const ua_len = v4.encodeUnsubAck(buf, pid) catch continue;
                        pkt.writeAll(transport, buf[0..ua_len]) catch return;
                    },
                    .pingreq => {
                        const resp_len = v4.encodePingResp(buf) catch continue;
                        pkt.writeAll(transport, buf[0..resp_len]) catch return;
                    },
                    .disconnect => return,
                    else => {},
                }
            }
        }

        fn handleV5(self: *Self, transport: *Transport, buf: *[8192]u8, connect_data: []const u8) !void {
            const result = try v5.decodePacket(connect_data);
            const connect = switch (result.packet) {
                .connect => |c| c,
                else => return,
            };

            if (!self.auth.authenticate(connect.client_id, connect.username, connect.password)) {
                const len = try v5.encodeConnAck(buf, &.{ .reason_code = .not_authorized });
                pkt.writeAll(transport, buf[0..len]) catch {};
                return;
            }

            const ca_len = try v5.encodeConnAck(buf, &.{
                .reason_code = .success,
                .properties = .{},
            });
            try pkt.writeAll(transport, buf[0..ca_len]);

            while (true) {
                const pkt_len = pkt.readPacket(transport, buf) catch return;
                const hdr = pkt.decodeFixedHeader(buf[0..pkt_len]) catch return;

                switch (hdr.packet_type) {
                    .publish => {
                        const pr = v5.decodePacket(buf[0..pkt_len]) catch continue;
                        const p = pr.packet.publish;
                        if (!self.auth.acl(connect.client_id, p.topic, true)) continue;
                        const msg = Message{
                            .topic = p.topic,
                            .payload = p.payload,
                            .retain = p.retain,
                        };
                        self.handler.handleMessage(&msg) catch {};
                        self.routeMessage(&msg, transport);
                    },
                    .subscribe => {
                        const payload = buf[hdr.header_len..pkt_len];
                        var off: usize = 0;
                        const pid = pkt.decodeU16(payload[off..]) catch continue;
                        off += 2;
                        // Skip properties
                        const pr = v5.decodeProperties(payload[off..]) catch continue;
                        off += pr.len;
                        // Parse topics
                        var codes: [32]pkt.ReasonCode = undefined;
                        var code_count: usize = 0;
                        while (off < payload.len) {
                            const r = pkt.decodeString(payload[off..]) catch break;
                            off += r.len;
                            if (off >= payload.len) break;
                            off += 1; // subscription options

                            if (!self.auth.acl(connect.client_id, r.str, false)) {
                                codes[code_count] = .not_authorized;
                            } else {
                                self.sub_mutex.lock();
                                self.subscriptions.insert(r.str, transport) catch {};
                                self.sub_mutex.unlock();
                                codes[code_count] = .success;
                            }
                            code_count += 1;
                        }
                        const sa = v5.SubAck{
                            .packet_id = pid,
                            .reason_codes = codes[0..code_count],
                        };
                        const sa_len = v5.encodeSubAck(buf, &sa) catch continue;
                        pkt.writeAll(transport, buf[0..sa_len]) catch return;
                    },
                    .pingreq => {
                        const resp_len = v5.encodePingResp(buf) catch continue;
                        pkt.writeAll(transport, buf[0..resp_len]) catch return;
                    },
                    .disconnect => return,
                    else => {},
                }
            }
        }

        fn routeMessage(self: *Self, msg: *const Message, sender: *Transport) void {
            self.sub_mutex.lock();
            const subscribers = self.subscriptions.match(msg.topic);
            self.sub_mutex.unlock();

            if (subscribers) |transports| {
                for (transports) |t| {
                    if (t == sender) continue; // Don't echo back to sender
                    // Encode and forward publish
                    var fwd_buf: [8192]u8 = undefined;
                    const pub_pkt = v4.Publish{
                        .topic = msg.topic,
                        .payload = msg.payload,
                        .retain = msg.retain,
                    };
                    const len = v4.encodePublish(&fwd_buf, &pub_pkt) catch continue;
                    pkt.writeAll(t, fwd_buf[0..len]) catch {};
                }
            }
        }

        /// Detect MQTT protocol version from CONNECT packet.
        fn detectVersion(data: []const u8) !ProtocolVersion {
            const hdr = try pkt.decodeFixedHeader(data);
            if (hdr.packet_type != .connect) return error.ProtocolError;
            const payload = data[hdr.header_len..];
            // Skip protocol name (2 + 4 = 6 bytes for "MQTT")
            if (payload.len < 7) return error.MalformedPacket;
            const name_len = (@as(usize, payload[0]) << 8) | @as(usize, payload[1]);
            const level_offset = 2 + name_len;
            if (payload.len <= level_offset) return error.MalformedPacket;
            return switch (payload[level_offset]) {
                4 => .v4,
                5 => .v5,
                else => error.UnsupportedProtocolVersion,
            };
        }
    };
}
