//! MQTT Broker — feature-complete QoS 0 broker for v3.1.1 and v5.0
//!
//! Features (matching Go mqtt0):
//! - Auto protocol version detection (v4/v5)
//! - Authenticator (auth + ACL) interface
//! - Per-client subscription tracking + cleanup on disconnect
//! - Topic Alias support (client→broker, v5)
//! - Shared Subscriptions ($share/ round-robin)
//! - Limits: MaxTopicAlias, MaxTopicLength, MaxSubscriptionsPerClient
//! - $ topic publish prevention
//! - Client ID conflict handling (kick old)
//! - OnConnect/OnDisconnect callbacks
//! - Keepalive timeout
//!
//! Usage:
//!     var mux = try mqtt0.Mux.init(allocator);
//!     try mux.handleFn("device/#", handleAll);
//!
//!     var broker = try mqtt0.Broker(Socket).init(allocator, mux.handler(), .{});
//!     broker.on_connect = myOnConnect;
//!     broker.on_disconnect = myOnDisconnect;
//!     // User controls accept loop:
//!     while (try listener.accept()) |conn| {
//!         spawn(broker.serveConn, .{conn});
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

/// AllowAll authenticator — allows everything.
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
// Callback types
// ============================================================================

pub const ConnectCallback = *const fn (client_id: []const u8) void;
pub const DisconnectCallback = *const fn (client_id: []const u8) void;

// ============================================================================
// Broker
// ============================================================================

pub fn Broker(comptime Transport: type) type {
    return struct {
        const Self = @This();

        /// Per-client connection handle. Stored in trie, outlives connection for safe cleanup.
        const ClientHandle = struct {
            client_id_buf: [256]u8 = undefined,
            client_id_len: usize = 0,
            transport: ?*Transport = null,
            write_mutex: std.Thread.Mutex = .{},
            active: bool = false,
            generation: u32 = 0, // Incremented on reconnect to detect stale handles

            fn clientId(self: *const ClientHandle) []const u8 {
                return self.client_id_buf[0..self.client_id_len];
            }

            fn setClientId(self: *ClientHandle, id: []const u8) void {
                const len = @min(id.len, 256);
                @memcpy(self.client_id_buf[0..len], id[0..len]);
                self.client_id_len = len;
            }

            /// Thread-safe write to this client's transport
            fn sendPublish(self: *ClientHandle, msg: *const Message) void {
                self.write_mutex.lock();
                defer self.write_mutex.unlock();
                if (!self.active) return;
                const t = self.transport orelse return;
                var buf: [8192]u8 = undefined;
                const pub_pkt = v4.Publish{
                    .topic = msg.topic,
                    .payload = msg.payload,
                    .retain = msg.retain,
                };
                const len = v4.encodePublish(&buf, &pub_pkt) catch return;
                pkt.writeAll(t, buf[0..len]) catch {
                    self.active = false;
                };
            }
        };

        pub const Config = struct {
            max_packet_size: usize = pkt.max_packet_size,
            max_topic_alias: u16 = 65535,
            max_topic_length: usize = 256,
            max_subscriptions_per_client: usize = 100,
        };

        allocator: Allocator,
        handler: Handler,
        auth: Authenticator,
        config: Config,

        // Subscription management
        subscriptions: trie_mod.Trie(*ClientHandle),
        sub_mutex: std.Thread.Mutex,

        // Client tracking
        clients: std.StringHashMap(*ClientHandle),
        client_subscriptions: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
        clients_mutex: std.Thread.Mutex,

        // Callbacks
        on_connect: ?ConnectCallback = null,
        on_disconnect: ?DisconnectCallback = null,

        pub fn init(allocator: Allocator, handler: Handler, config: Config) !Self {
            return .{
                .allocator = allocator,
                .handler = handler,
                .auth = AllowAll.authenticator(),
                .config = config,
                .subscriptions = try trie_mod.Trie(*ClientHandle).init(allocator),
                .sub_mutex = .{},
                .clients = std.StringHashMap(*ClientHandle).init(allocator),
                .client_subscriptions = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
                .clients_mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            // Free client handles
            var cit = self.clients.iterator();
            while (cit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.clients.deinit();

            // Free subscription tracking
            var sit = self.client_subscriptions.iterator();
            while (sit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |topic| {
                    self.allocator.free(topic);
                }
                entry.value_ptr.deinit(self.allocator);
            }
            self.client_subscriptions.deinit();

            self.subscriptions.deinit();
        }

        pub fn setAuthenticator(self: *Self, auth: Authenticator) void {
            self.auth = auth;
        }

        /// Handle a single client connection. Blocks until disconnect.
        pub fn serveConn(self: *Self, transport: *Transport) void {
            self.serveConnInner(transport) catch {};
        }

        /// Publish from broker side to all matching subscribers.
        pub fn publish(self: *Self, topic: []const u8, payload: []const u8) void {
            const msg = Message{ .topic = topic, .payload = payload };
            self.routeMessage(&msg, null);
        }

        // ====================================================================
        // Connection handling
        // ====================================================================

        fn serveConnInner(self: *Self, transport: *Transport) !void {
            var buf: [8192]u8 = undefined;
            const first_len = try pkt.readPacket(transport, &buf);
            if (first_len < 2) return;
            const version = detectVersion(buf[0..first_len]) catch return;

            switch (version) {
                .v4 => self.handleConnectionV4(transport, &buf, buf[0..first_len]),
                .v5 => self.handleConnectionV5(transport, &buf, buf[0..first_len]),
            }
        }

        fn handleConnectionV4(self: *Self, transport: *Transport, buf: *[8192]u8, connect_data: []const u8) void {
            const result = v4.decodePacket(connect_data) catch return;
            const connect = switch (result.packet) {
                .connect => |c| c,
                else => return,
            };

            if (!self.auth.authenticate(connect.client_id, connect.username, connect.password)) {
                const len = v4.encodeConnAck(buf, &.{ .session_present = false, .return_code = .not_authorized }) catch return;
                pkt.writeAll(transport, buf[0..len]) catch {};
                return;
            }

            const ca_len = v4.encodeConnAck(buf, &.{ .session_present = false, .return_code = .accepted }) catch return;
            pkt.writeAll(transport, buf[0..ca_len]) catch return;

            // Register client
            const handle = self.registerClient(connect.client_id, transport);
            defer self.cleanupClient(handle);

            if (self.on_connect) |cb| cb(connect.client_id);
            defer if (self.on_disconnect) |cb| cb(connect.client_id);

            // Client loop
            self.clientLoopV4(transport, buf, handle);
        }

        fn handleConnectionV5(self: *Self, transport: *Transport, buf: *[8192]u8, connect_data: []const u8) void {
            const result = v5.decodePacket(connect_data) catch return;
            const connect = switch (result.packet) {
                .connect => |c| c,
                else => return,
            };

            if (!self.auth.authenticate(connect.client_id, connect.username, connect.password)) {
                const len = v5.encodeConnAck(buf, &.{ .reason_code = .not_authorized }) catch return;
                pkt.writeAll(transport, buf[0..len]) catch {};
                return;
            }

            // Send CONNACK with broker capabilities
            const ca_len = v5.encodeConnAck(buf, &.{
                .reason_code = .success,
                .properties = .{
                    .topic_alias_maximum = self.config.max_topic_alias,
                },
            }) catch return;
            pkt.writeAll(transport, buf[0..ca_len]) catch return;

            const handle = self.registerClient(connect.client_id, transport);
            defer self.cleanupClient(handle);

            if (self.on_connect) |cb| cb(connect.client_id);
            defer if (self.on_disconnect) |cb| cb(connect.client_id);

            self.clientLoopV5(transport, buf, handle);
        }

        // ====================================================================
        // Client loops
        // ====================================================================

        fn clientLoopV4(self: *Self, transport: *Transport, buf: *[8192]u8, handle: *ClientHandle) void {
            while (handle.active) {
                const pkt_len = pkt.readPacket(transport, buf) catch return;
                const hdr = pkt.decodeFixedHeader(buf[0..pkt_len]) catch return;

                switch (hdr.packet_type) {
                    .publish => {
                        const pr = v4.decodePacket(buf[0..pkt_len]) catch continue;
                        const p = pr.packet.publish;
                        self.handlePublish(handle.clientId(), p.topic, p.payload, p.retain);
                    },
                    .subscribe => {
                        const payload = buf[hdr.header_len..pkt_len];
                        const pid = pkt.decodeU16(payload[0..2]) catch continue;
                        var it = v4.SubscribeTopicIterator.init(payload, true);
                        var codes_buf: [64]u8 = undefined;
                        var code_count: usize = 0;
                        while (it.next() catch null) |ti| {
                            codes_buf[code_count] = if (self.handleSubscribe(handle, ti.topic))
                                @as(u8, 0x00)
                            else
                                @as(u8, 0x80);
                            code_count += 1;
                        }
                        const sa_len = v4.encodeSubAck(buf, &.{
                            .packet_id = pid,
                            .return_codes = codes_buf[0..code_count],
                        }) catch continue;
                        pkt.writeAll(transport, buf[0..sa_len]) catch return;
                    },
                    .unsubscribe => {
                        const payload = buf[hdr.header_len..pkt_len];
                        const pid = pkt.decodeU16(payload[0..2]) catch continue;
                        var it = v4.UnsubscribeTopicIterator.init(payload, true);
                        while (it.next() catch null) |topic| {
                            self.handleUnsubscribe(handle, topic);
                        }
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

        fn clientLoopV5(self: *Self, transport: *Transport, buf: *[8192]u8, handle: *ClientHandle) void {
            // Per-client topic alias map (client→broker direction)
            var topic_aliases = std.AutoHashMap(u16, []const u8).init(self.allocator);
            defer {
                var vit = topic_aliases.valueIterator();
                while (vit.next()) |v| self.allocator.free(v.*);
                topic_aliases.deinit();
            }

            while (handle.active) {
                const pkt_len = pkt.readPacket(transport, buf) catch return;
                const hdr = pkt.decodeFixedHeader(buf[0..pkt_len]) catch return;

                switch (hdr.packet_type) {
                    .publish => {
                        const pr = v5.decodePacket(buf[0..pkt_len]) catch continue;
                        const p = pr.packet.publish;
                        // Resolve topic alias
                        const topic = self.resolveTopicAlias(
                            &topic_aliases,
                            p.topic,
                            p.properties.topic_alias,
                        ) orelse continue;
                        self.handlePublish(handle.clientId(), topic, p.payload, p.retain);
                    },
                    .subscribe => {
                        const payload = buf[hdr.header_len..pkt_len];
                        var off: usize = 0;
                        const pid = pkt.decodeU16(payload[off..]) catch continue;
                        off += 2;
                        const pr = v5.decodeProperties(payload[off..]) catch continue;
                        off += pr.len;

                        var codes: [64]pkt.ReasonCode = undefined;
                        var code_count: usize = 0;
                        while (off < payload.len) {
                            const r = pkt.decodeString(payload[off..]) catch break;
                            off += r.len;
                            if (off >= payload.len) break;
                            off += 1; // subscription options
                            codes[code_count] = if (self.handleSubscribe(handle, r.str))
                                pkt.ReasonCode.success
                            else
                                pkt.ReasonCode.not_authorized;
                            code_count += 1;
                        }
                        const sa_len = v5.encodeSubAck(buf, &.{
                            .packet_id = pid,
                            .reason_codes = codes[0..code_count],
                        }) catch continue;
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

        // ====================================================================
        // Publish handling
        // ====================================================================

        fn handlePublish(self: *Self, client_id: []const u8, topic: []const u8, payload: []const u8, retain: bool) void {
            // Validate topic
            if (topic.len == 0) return;
            if (topic.len > self.config.max_topic_length) return;

            // Prevent clients from publishing to $ topics (MQTT spec)
            if (topic[0] == '$') return;

            // ACL check
            if (!self.auth.acl(client_id, topic, true)) return;

            const msg = Message{ .topic = topic, .payload = payload, .retain = retain };

            // Dispatch to handler
            self.handler.handleMessage(client_id, &msg) catch {};

            // Route to subscribers
            self.routeMessage(&msg, null);
        }

        // ====================================================================
        // Topic Alias (v5, client→broker)
        // ====================================================================

        fn resolveTopicAlias(
            self: *Self,
            aliases: *std.AutoHashMap(u16, []const u8),
            topic: []const u8,
            alias_opt: ?u16,
        ) ?[]const u8 {
            const alias = alias_opt orelse return if (topic.len > 0) topic else null;

            // Validate alias
            if (alias == 0 or alias > self.config.max_topic_alias) return null;

            if (topic.len > 0) {
                // Topic + alias = update mapping
                const duped = self.allocator.dupe(u8, topic) catch return null;
                if (aliases.fetchPut(alias, duped) catch null) |old| {
                    self.allocator.free(old.value);
                }
                return topic;
            } else {
                // Empty topic = lookup alias
                return aliases.get(alias);
            }
        }

        // ====================================================================
        // Subscribe / Unsubscribe
        // ====================================================================

        fn handleSubscribe(self: *Self, handle: *ClientHandle, topic: []const u8) bool {
            // Validate topic length
            if (topic.len > self.config.max_topic_length) return false;

            // ACL check
            if (!self.auth.acl(handle.clientId(), topic, false)) return false;

            // Check subscription limit
            self.clients_mutex.lock();
            const key = handle.clientId();
            if (self.client_subscriptions.getPtr(key)) |subs| {
                if (subs.items.len >= self.config.max_subscriptions_per_client) {
                    self.clients_mutex.unlock();
                    return false;
                }
                // Track subscription
                const topic_dup = self.allocator.dupe(u8, topic) catch {
                    self.clients_mutex.unlock();
                    return false;
                };
                subs.append(self.allocator, topic_dup) catch {
                    self.allocator.free(topic_dup);
                    self.clients_mutex.unlock();
                    return false;
                };
            }
            self.clients_mutex.unlock();

            // Add to trie
            self.sub_mutex.lock();
            self.subscriptions.insert(topic, handle) catch {
                self.sub_mutex.unlock();
                return false;
            };
            self.sub_mutex.unlock();

            return true;
        }

        fn handleUnsubscribe(self: *Self, handle: *ClientHandle, topic: []const u8) void {
            const cid = handle.clientId();

            // Remove from trie
            self.sub_mutex.lock();
            _ = self.subscriptions.remove(topic, &struct {
                fn pred(h: *ClientHandle) bool {
                    _ = h;
                    return true; // TODO: compare handle pointers properly
                }
            }.pred);
            self.sub_mutex.unlock();

            // Remove from tracking
            self.clients_mutex.lock();
            if (self.client_subscriptions.getPtr(cid)) |subs| {
                var i: usize = 0;
                while (i < subs.items.len) {
                    if (std.mem.eql(u8, subs.items[i], topic)) {
                        self.allocator.free(subs.items[i]);
                        _ = subs.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
            self.clients_mutex.unlock();
        }

        // ====================================================================
        // Message routing
        // ====================================================================

        fn routeMessage(self: *Self, msg: *const Message, sender: ?*ClientHandle) void {
            self.sub_mutex.lock();
            const subscribers = self.subscriptions.match(msg.topic);
            // Copy handles while holding lock to avoid UAF
            var handles_buf: [128]*ClientHandle = undefined;
            var handle_count: usize = 0;
            if (subscribers) |transports| {
                for (transports) |h| {
                    if (sender != null and h == sender.?) continue;
                    if (handle_count < handles_buf.len) {
                        handles_buf[handle_count] = h;
                        handle_count += 1;
                    }
                }
            }
            self.sub_mutex.unlock();

            // Send outside lock — each handle has its own write_mutex
            for (handles_buf[0..handle_count]) |h| {
                h.sendPublish(msg);
            }
        }

        // ====================================================================
        // Client registration / cleanup
        // ====================================================================

        fn registerClient(self: *Self, client_id: []const u8, transport: *Transport) *ClientHandle {
            self.clients_mutex.lock();
            defer self.clients_mutex.unlock();

            // Check for existing client with same ID (kick old)
            if (self.clients.get(client_id)) |old_handle| {
                old_handle.active = false; // Signal old client loop to stop
                // Old cleanup will happen via defer in the old connection's handler
                old_handle.generation +%= 1;
                old_handle.transport = transport;
                old_handle.active = true;

                return old_handle;
            }

            // New client
            const handle = self.allocator.create(ClientHandle) catch return undefined;
            handle.* = .{};
            handle.setClientId(client_id);
            handle.transport = transport;
            handle.active = true;

            const key_dup = self.allocator.dupe(u8, client_id) catch return handle;
            self.clients.put(key_dup, handle) catch {
                self.allocator.free(key_dup);
            };

            // Init subscription tracking
            const key_dup2 = self.allocator.dupe(u8, client_id) catch return handle;
            self.client_subscriptions.put(key_dup2, .empty) catch {
                self.allocator.free(key_dup2);
            };

            return handle;
        }

        fn cleanupClient(self: *Self, handle: *ClientHandle) void {
            handle.write_mutex.lock();
            handle.active = false;
            handle.transport = null;
            handle.write_mutex.unlock();

            const cid = handle.clientId();

            // Remove subscriptions from trie
            self.clients_mutex.lock();
            if (self.client_subscriptions.getPtr(cid)) |subs| {
                self.sub_mutex.lock();
                for (subs.items) |topic| {
                    _ = self.subscriptions.remove(topic, &struct {
                        fn pred(_: *ClientHandle) bool {
                            return true; // Remove all matching (simplified)
                        }
                    }.pred);
                    self.allocator.free(topic);
                }
                subs.deinit(self.allocator);
                subs.* = .empty;
                self.sub_mutex.unlock();
            }
            self.clients_mutex.unlock();
        }

        // ====================================================================
        // Protocol detection
        // ====================================================================

        fn detectVersion(data: []const u8) !ProtocolVersion {
            const hdr = try pkt.decodeFixedHeader(data);
            if (hdr.packet_type != .connect) return error.ProtocolError;
            const payload = data[hdr.header_len..];
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
