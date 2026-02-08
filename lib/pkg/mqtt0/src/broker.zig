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
            username_buf: [128]u8 = undefined,
            username_len: usize = 0,
            transport: ?*Transport = null,
            write_mutex: std.Thread.Mutex = .{},
            active: bool = false,
            generation: u32 = 0,
            alloc: Allocator = std.heap.page_allocator,

            fn clientId(self: *const ClientHandle) []const u8 {
                return self.client_id_buf[0..self.client_id_len];
            }

            fn username(self: *const ClientHandle) []const u8 {
                return self.username_buf[0..self.username_len];
            }

            fn setClientId(self: *ClientHandle, id: []const u8) void {
                const len = @min(id.len, 256);
                @memcpy(self.client_id_buf[0..len], id[0..len]);
                self.client_id_len = len;
            }

            fn setUsername(self: *ClientHandle, name: []const u8) void {
                const len = @min(name.len, 128);
                @memcpy(self.username_buf[0..len], name[0..len]);
                self.username_len = len;
            }

            /// Thread-safe write to this client's transport
            fn sendPublish(self: *ClientHandle, msg: *const Message) void {
                self.write_mutex.lock();
                defer self.write_mutex.unlock();
                if (!self.active) return;
                const t = self.transport orelse return;

                const needed = msg.topic.len + msg.payload.len + 128;
                var write_pkt_buf = pkt.PacketBuffer.init(self.alloc);
                defer write_pkt_buf.deinit();
                const buf = write_pkt_buf.acquire(needed) catch return;

                const pub_pkt = v4.Publish{
                    .topic = msg.topic,
                    .payload = msg.payload,
                    .retain = msg.retain,
                };
                const len = v4.encodePublish(buf, &pub_pkt) catch return;
                pkt.writeAll(t, buf[0..len]) catch {
                    self.active = false;
                };
            }
        };

        /// Shared subscription group — round-robin distribution among subscribers.
        const SharedGroup = struct {
            group_name_buf: [128]u8 = undefined,
            group_name_len: usize = 0,
            topic_buf: [256]u8 = undefined,
            topic_len: usize = 0,
            subscribers: std.ArrayListUnmanaged(*ClientHandle) = .empty,
            next_index: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
            mutex: std.Thread.Mutex = .{},

            fn groupName(self: *const SharedGroup) []const u8 {
                return self.group_name_buf[0..self.group_name_len];
            }

            fn actualTopic(self: *const SharedGroup) []const u8 {
                return self.topic_buf[0..self.topic_len];
            }

            fn setGroupName(self: *SharedGroup, name: []const u8) void {
                const len = @min(name.len, 128);
                @memcpy(self.group_name_buf[0..len], name[0..len]);
                self.group_name_len = len;
            }

            fn setActualTopic(self: *SharedGroup, t: []const u8) void {
                const len = @min(t.len, 256);
                @memcpy(self.topic_buf[0..len], t[0..len]);
                self.topic_len = len;
            }

            fn add(self: *SharedGroup, allocator: Allocator, handle: *ClientHandle) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                for (self.subscribers.items) |s| {
                    if (s == handle) return true; // already subscribed
                }
                self.subscribers.append(allocator, handle) catch return false;
                return true;
            }

            fn removeByHandle(self: *SharedGroup, handle: *ClientHandle) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                var i: usize = 0;
                while (i < self.subscribers.items.len) {
                    if (self.subscribers.items[i] == handle) {
                        _ = self.subscribers.orderedRemove(i);
                        return;
                    }
                    i += 1;
                }
            }

            fn isEmpty(self: *SharedGroup) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.subscribers.items.len == 0;
            }

            fn nextSubscriber(self: *SharedGroup) ?*ClientHandle {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.subscribers.items.len == 0) return null;
                const idx = (self.next_index.fetchAdd(1, .monotonic)) % self.subscribers.items.len;
                return self.subscribers.items[idx];
            }

            fn deinit(self: *SharedGroup, allocator: Allocator) void {
                self.subscribers.deinit(allocator);
            }
        };

        pub const Config = struct {
            max_packet_size: usize = 2 * 1024 * 1024, // 2MB
            max_topic_alias: u16 = 65535,
            max_topic_length: usize = 256,
            max_subscriptions_per_client: usize = 100,
            sys_events_enabled: bool = false,
        };

        allocator: Allocator,
        handler: Handler,
        auth: Authenticator,
        config: Config,

        // Subscription management
        subscriptions: trie_mod.Trie(*ClientHandle),
        shared_trie: trie_mod.Trie(*SharedGroup), // $share/ subscriptions
        sub_mutex: std.Thread.Mutex,

        // Client tracking
        clients: std.StringHashMap(*ClientHandle),
        client_subscriptions: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
        clients_mutex: std.Thread.Mutex,

        // Shared group storage (owns SharedGroup allocations)
        shared_groups: std.ArrayListUnmanaged(*SharedGroup),

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
                .shared_trie = try trie_mod.Trie(*SharedGroup).init(allocator),
                .sub_mutex = .{},
                .clients = std.StringHashMap(*ClientHandle).init(allocator),
                .client_subscriptions = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
                .clients_mutex = .{},
                .shared_groups = .empty,
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

            // Free shared groups
            for (self.shared_groups.items) |sg| {
                sg.deinit(self.allocator);
                self.allocator.destroy(sg);
            }
            self.shared_groups.deinit(self.allocator);
            self.shared_trie.deinit();
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
            var read_buf = pkt.PacketBuffer.init(self.allocator);
            defer read_buf.deinit();
            var write_buf = pkt.PacketBuffer.init(self.allocator);
            defer write_buf.deinit();

            const first_len = try pkt.readPacketBuf(transport, &read_buf);
            if (first_len < 2) return;
            const data = read_buf.slice()[0..first_len];
            const version = detectVersion(data) catch return;

            switch (version) {
                .v4 => self.handleConnectionV4(transport, &read_buf, &write_buf, data),
                .v5 => self.handleConnectionV5(transport, &read_buf, &write_buf, data),
            }
        }

        fn handleConnectionV4(self: *Self, transport: *Transport, read_buf: *pkt.PacketBuffer, write_buf: *pkt.PacketBuffer, connect_data: []const u8) void {
            const result = v4.decodePacket(connect_data) catch return;
            const connect = switch (result.packet) {
                .connect => |c| c,
                else => return,
            };

            if (!self.auth.authenticate(connect.client_id, connect.username, connect.password)) {
                const wb = write_buf.acquire(64) catch return;
                const len = v4.encodeConnAck(wb, &.{ .session_present = false, .return_code = .not_authorized }) catch return;
                pkt.writeAll(transport, wb[0..len]) catch {};
                return;
            }

            const wb = write_buf.acquire(64) catch return;
            const ca_len = v4.encodeConnAck(wb, &.{ .session_present = false, .return_code = .accepted }) catch return;
            pkt.writeAll(transport, wb[0..ca_len]) catch return;

            const handle = self.registerClient(connect.client_id, transport) orelse return;
            handle.setUsername(connect.username);
            const gen = handle.generation;
            defer self.cleanupClient(handle, gen);

            if (self.on_connect) |cb| cb(connect.client_id);
            defer if (self.on_disconnect) |cb| cb(handle.clientId());

            self.publishSysConnected(handle.clientId(), handle.username(), @intFromEnum(pkt.ProtocolVersion.v4), connect.keep_alive);

            setKeepaliveTimeout(transport, connect.keep_alive);
            self.clientLoopV4(transport, read_buf, write_buf, handle);
        }

        fn handleConnectionV5(self: *Self, transport: *Transport, read_buf: *pkt.PacketBuffer, write_buf: *pkt.PacketBuffer, connect_data: []const u8) void {
            const result = v5.decodePacket(connect_data) catch return;
            const connect = switch (result.packet) {
                .connect => |c| c,
                else => return,
            };

            if (!self.auth.authenticate(connect.client_id, connect.username, connect.password)) {
                const wb = write_buf.acquire(128) catch return;
                const len = v5.encodeConnAck(wb, &.{ .reason_code = .not_authorized }) catch return;
                pkt.writeAll(transport, wb[0..len]) catch {};
                return;
            }

            const wb = write_buf.acquire(128) catch return;
            const ca_len = v5.encodeConnAck(wb, &.{
                .reason_code = .success,
                .properties = .{ .topic_alias_maximum = self.config.max_topic_alias },
            }) catch return;
            pkt.writeAll(transport, wb[0..ca_len]) catch return;

            const handle = self.registerClient(connect.client_id, transport) orelse return;
            handle.setUsername(connect.username);
            const gen = handle.generation;
            defer self.cleanupClient(handle, gen);

            if (self.on_connect) |cb| cb(connect.client_id);
            defer if (self.on_disconnect) |cb| cb(handle.clientId());

            self.publishSysConnected(handle.clientId(), handle.username(), @intFromEnum(pkt.ProtocolVersion.v5), connect.keep_alive);

            setKeepaliveTimeout(transport, connect.keep_alive);
            self.clientLoopV5(transport, read_buf, write_buf, handle);
        }

        // ====================================================================
        // Client loops
        // ====================================================================

        fn clientLoopV4(self: *Self, transport: *Transport, read_buf: *pkt.PacketBuffer, write_buf: *pkt.PacketBuffer, handle: *ClientHandle) void {
            while (handle.active) {
                const pkt_len = pkt.readPacketBuf(transport, read_buf) catch return;
                const buf = read_buf.slice();
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
                        const wb = write_buf.acquire(256) catch continue;
                        const sa_len = v4.encodeSubAck(wb, &.{
                            .packet_id = pid,
                            .return_codes = codes_buf[0..code_count],
                        }) catch continue;
                        pkt.writeAll(transport, wb[0..sa_len]) catch return;
                    },
                    .unsubscribe => {
                        const payload = buf[hdr.header_len..pkt_len];
                        const pid = pkt.decodeU16(payload[0..2]) catch continue;
                        var it = v4.UnsubscribeTopicIterator.init(payload, true);
                        while (it.next() catch null) |topic| {
                            self.handleUnsubscribe(handle, topic);
                        }
                        const wb = write_buf.acquire(64) catch continue;
                        const ua_len = v4.encodeUnsubAck(wb, pid) catch continue;
                        pkt.writeAll(transport, wb[0..ua_len]) catch return;
                    },
                    .pingreq => {
                        const wb = write_buf.acquire(4) catch continue;
                        const resp_len = v4.encodePingResp(wb) catch continue;
                        pkt.writeAll(transport, wb[0..resp_len]) catch return;
                    },
                    .disconnect => return,
                    else => {},
                }
            }
        }

        fn clientLoopV5(self: *Self, transport: *Transport, read_buf: *pkt.PacketBuffer, write_buf: *pkt.PacketBuffer, handle: *ClientHandle) void {
            // Per-client topic alias map (client→broker direction)
            var topic_aliases = std.AutoHashMap(u16, []const u8).init(self.allocator);
            defer {
                var vit = topic_aliases.valueIterator();
                while (vit.next()) |v| self.allocator.free(v.*);
                topic_aliases.deinit();
            }

            while (handle.active) {
                const pkt_len = pkt.readPacketBuf(transport, read_buf) catch return;
                const buf = read_buf.slice();
                const hdr = pkt.decodeFixedHeader(buf[0..pkt_len]) catch return;

                switch (hdr.packet_type) {
                    .publish => {
                        const pr = v5.decodePacket(buf[0..pkt_len]) catch continue;
                        const p = pr.packet.publish;
                        const topic = self.resolveTopicAlias(&topic_aliases, p.topic, p.properties.topic_alias) orelse continue;
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
                            off += 1;
                            codes[code_count] = if (self.handleSubscribe(handle, r.str))
                                pkt.ReasonCode.success
                            else
                                pkt.ReasonCode.not_authorized;
                            code_count += 1;
                        }
                        const wb = write_buf.acquire(256) catch continue;
                        const sa_len = v5.encodeSubAck(wb, &.{
                            .packet_id = pid,
                            .reason_codes = codes[0..code_count],
                        }) catch continue;
                        pkt.writeAll(transport, wb[0..sa_len]) catch return;
                    },
                    .unsubscribe => {
                        const payload = buf[hdr.header_len..pkt_len];
                        var uoff: usize = 0;
                        const upid = pkt.decodeU16(payload[uoff..]) catch continue;
                        uoff += 2;
                        const upr = v5.decodeProperties(payload[uoff..]) catch continue;
                        uoff += upr.len;

                        var ucodes: [64]pkt.ReasonCode = undefined;
                        var ucode_count: usize = 0;
                        while (uoff < payload.len) {
                            const r = pkt.decodeString(payload[uoff..]) catch break;
                            uoff += r.len;
                            self.handleUnsubscribe(handle, r.str);
                            ucodes[ucode_count] = .success;
                            ucode_count += 1;
                        }
                        const wb = write_buf.acquire(128) catch continue;
                        var uo: usize = 0;
                        wb[uo] = (@as(u8, @intFromEnum(pkt.PacketType.unsuback)) << 4);
                        uo += 1;
                        uo += pkt.encodeVariableInt(wb[uo..], @truncate(2 + 1 + ucode_count)) catch continue;
                        uo += pkt.encodeU16(wb[uo..], upid) catch continue;
                        wb[uo] = 0;
                        uo += 1;
                        for (ucodes[0..ucode_count]) |rc| {
                            wb[uo] = @intFromEnum(rc);
                            uo += 1;
                        }
                        pkt.writeAll(transport, wb[0..uo]) catch return;
                    },
                    .pingreq => {
                        const wb = write_buf.acquire(4) catch continue;
                        const resp_len = v5.encodePingResp(wb) catch continue;
                        pkt.writeAll(transport, wb[0..resp_len]) catch return;
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
            // Parse shared subscription
            const shared = parseSharedTopic(topic);
            const acl_topic = if (shared) |s| s.actual_topic else topic;

            // Validate topic length
            if (acl_topic.len > self.config.max_topic_length) return false;

            // ACL check
            if (!self.auth.acl(handle.clientId(), acl_topic, false)) return false;

            // Check subscription limit and track (dedup: replace existing)
            self.clients_mutex.lock();
            const key = handle.clientId();
            var is_resub = false;
            if (self.client_subscriptions.getPtr(key)) |subs| {
                // Check if already subscribed to this topic (MQTT spec: replace)
                for (subs.items) |existing| {
                    if (std.mem.eql(u8, existing, topic)) {
                        is_resub = true;
                        break;
                    }
                }
                if (!is_resub) {
                    if (subs.items.len >= self.config.max_subscriptions_per_client) {
                        self.clients_mutex.unlock();
                        return false;
                    }
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
            }
            self.clients_mutex.unlock();

            const trie_ok = if (shared) |s| blk: {
                self.sub_mutex.lock();
                defer self.sub_mutex.unlock();
                // addToSharedGroup already deduplicates via sg.add()
                break :blk self.addToSharedGroup(s.group, s.actual_topic, handle);
            } else blk: {
                self.sub_mutex.lock();
                defer self.sub_mutex.unlock();
                // Remove old entry first to prevent duplicates (MQTT spec: replace)
                if (is_resub) _ = self.subscriptions.removeValue(topic, handle);
                self.subscriptions.insert(topic, handle) catch break :blk false;
                break :blk true;
            };

            if (!trie_ok) {
                // Rollback: remove topic_dup from client_subscriptions (only if we added one)
                if (!is_resub) {
                    self.clients_mutex.lock();
                    if (self.client_subscriptions.getPtr(handle.clientId())) |subs| {
                        if (subs.items.len > 0) {
                            const idx = subs.items.len - 1;
                            if (std.mem.eql(u8, subs.items[idx], topic)) {
                                const removed = subs.orderedRemove(idx);
                                self.allocator.free(removed);
                            }
                        }
                    }
                    self.clients_mutex.unlock();
                }
                return false;
            }

            return true;
        }

        fn addToSharedGroup(self: *Self, group_name: []const u8, actual_topic: []const u8, handle: *ClientHandle) bool {
            // Check if shared group already exists (exact match on group_name + actual_topic)
            for (self.shared_groups.items) |sg| {
                if (std.mem.eql(u8, sg.groupName(), group_name) and
                    std.mem.eql(u8, sg.actualTopic(), actual_topic))
                {
                    return sg.add(self.allocator, handle);
                }
            }

            // Create new shared group
            const sg = self.allocator.create(SharedGroup) catch return false;
            sg.* = .{};
            sg.setGroupName(group_name);
            sg.setActualTopic(actual_topic);
            if (!sg.add(self.allocator, handle)) {
                sg.deinit(self.allocator);
                self.allocator.destroy(sg);
                return false;
            }
            self.shared_groups.append(self.allocator, sg) catch {
                sg.deinit(self.allocator);
                self.allocator.destroy(sg);
                return false;
            };
            self.shared_trie.insert(actual_topic, sg) catch {
                // Rollback: remove from shared_groups, destroy
                if (self.shared_groups.items.len > 0) {
                    _ = self.shared_groups.pop();
                }
                sg.deinit(self.allocator);
                self.allocator.destroy(sg);
                return false;
            };
            return true;
        }

        fn handleUnsubscribe(self: *Self, handle: *ClientHandle, topic: []const u8) void {
            const cid = handle.clientId();
            const shared = parseSharedTopic(topic);

            if (shared) |s| {
                self.sub_mutex.lock();
                if (self.shared_trie.match(s.actual_topic)) |groups| {
                    for (groups) |sg| {
                        if (std.mem.eql(u8, sg.groupName(), s.group)) {
                            sg.removeByHandle(handle);
                            break;
                        }
                    }
                }
                self.sub_mutex.unlock();
            } else {
                // Remove only this client's subscription (pointer comparison)
                self.sub_mutex.lock();
                _ = self.subscriptions.removeValue(topic, handle);
                self.sub_mutex.unlock();
            }

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

            // Normal subscribers
            const subscribers = self.subscriptions.match(msg.topic);
            var handles_buf: [128]*ClientHandle = undefined;
            var handle_count: usize = 0;
            if (subscribers) |items| {
                for (items) |h| {
                    if (sender != null and h == sender.?) continue;
                    if (handle_count < handles_buf.len) {
                        handles_buf[handle_count] = h;
                        handle_count += 1;
                    }
                }
            }

            // Shared subscription groups (round-robin)
            if (self.shared_trie.match(msg.topic)) |groups| {
                for (groups) |sg| {
                    if (sg.nextSubscriber()) |h| {
                        if (sender != null and h == sender.?) continue;
                        if (handle_count < handles_buf.len) {
                            handles_buf[handle_count] = h;
                            handle_count += 1;
                        }
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

        fn registerClient(self: *Self, client_id: []const u8, transport: *Transport) ?*ClientHandle {
            self.clients_mutex.lock();
            defer self.clients_mutex.unlock();

            // Check for existing client with same ID (kick old)
            if (self.clients.get(client_id)) |old_handle| {
                old_handle.write_mutex.lock();
                old_handle.active = false;
                old_handle.generation +%= 1;
                old_handle.transport = transport;
                old_handle.active = true;
                old_handle.write_mutex.unlock();
                return old_handle;
            }

            // New client
            const handle = self.allocator.create(ClientHandle) catch return null;
            handle.* = .{ .alloc = self.allocator };
            handle.setClientId(client_id);
            handle.transport = transport;
            handle.active = true;

            const key_dup = self.allocator.dupe(u8, client_id) catch {
                self.allocator.destroy(handle);
                return null;
            };
            self.clients.put(key_dup, handle) catch {
                self.allocator.free(key_dup);
                self.allocator.destroy(handle);
                return null;
            };

            const key_dup2 = self.allocator.dupe(u8, client_id) catch {
                // Rollback: remove from clients map (returns owned key), destroy handle
                if (self.clients.fetchRemove(client_id)) |kv| {
                    self.allocator.free(kv.key);
                }
                self.allocator.destroy(handle);
                return null;
            };
            self.client_subscriptions.put(key_dup2, .empty) catch {
                self.allocator.free(key_dup2);
                if (self.clients.fetchRemove(client_id)) |kv| {
                    self.allocator.free(kv.key);
                }
                self.allocator.destroy(handle);
                return null;
            };

            return handle;
        }

        fn cleanupClient(self: *Self, handle: *ClientHandle, expected_gen: u32) void {
            // If generation changed, a new connection took over this handle.
            // Skip cleanup to avoid disrupting the new connection.
            if (handle.generation != expected_gen) return;

            self.publishSysDisconnected(handle.clientId(), handle.username());
            handle.write_mutex.lock();
            handle.active = false;
            handle.transport = null;
            handle.write_mutex.unlock();

            const cid = handle.clientId();

            // Remove subscriptions from both normal and shared tries
            self.clients_mutex.lock();
            if (self.client_subscriptions.getPtr(cid)) |subs| {
                self.sub_mutex.lock();
                for (subs.items) |topic| {
                    const shared = parseSharedTopic(topic);
                    if (shared) |s| {
                        if (self.shared_trie.match(s.actual_topic)) |groups| {
                            for (groups) |sg| {
                                if (std.mem.eql(u8, sg.groupName(), s.group)) {
                                    sg.removeByHandle(handle);
                                    break;
                                }
                            }
                        }
                    } else {
                        // Pointer comparison: only remove this client's entry
                        _ = self.subscriptions.removeValue(topic, handle);
                    }
                    self.allocator.free(topic);
                }
                subs.deinit(self.allocator);
                subs.* = .empty;
                self.sub_mutex.unlock();
            }
            self.clients_mutex.unlock();
        }

        // ====================================================================
        // $SYS Events (EMQX-compatible format)
        // ====================================================================

        fn publishSysConnected(self: *Self, client_id: []const u8, username: []const u8, proto_ver: u8, keep_alive: u16) void {
            if (!self.config.sys_events_enabled) return;

            var topic_buf: [320]u8 = undefined;
            const safe_id = sanitizeForTopic(&topic_buf, client_id);
            var full_topic: [384]u8 = undefined;
            const topic = std.fmt.bufPrint(&full_topic, "$SYS/brokers/{s}/connected", .{safe_id}) catch return;

            var json_buf: [1024]u8 = undefined;
            const timestamp = @divTrunc(std.time.milliTimestamp(), 1000);
            const json = std.fmt.bufPrint(&json_buf,
                \\{{"clientid":"{s}","username":"{s}","ipaddress":"","proto_ver":{d},"keepalive":{d},"connected_at":{d}}}
            , .{ client_id, username, proto_ver, keep_alive, timestamp }) catch return;

            const msg = Message{ .topic = topic, .payload = json };
            // Dispatch to broker handler AND route to MQTT subscribers
            self.handler.handleMessage("", &msg) catch {};
            self.routeMessage(&msg, null);
        }

        fn publishSysDisconnected(self: *Self, client_id: []const u8, username: []const u8) void {
            if (!self.config.sys_events_enabled) return;

            var topic_buf: [320]u8 = undefined;
            const safe_id = sanitizeForTopic(&topic_buf, client_id);
            var full_topic: [384]u8 = undefined;
            const topic = std.fmt.bufPrint(&full_topic, "$SYS/brokers/{s}/disconnected", .{safe_id}) catch return;

            var json_buf: [512]u8 = undefined;
            const timestamp = @divTrunc(std.time.milliTimestamp(), 1000);
            const json = std.fmt.bufPrint(&json_buf,
                \\{{"clientid":"{s}","username":"{s}","reason":"normal","disconnected_at":{d}}}
            , .{ client_id, username, timestamp }) catch return;

            const msg = Message{ .topic = topic, .payload = json };
            self.handler.handleMessage("", &msg) catch {};
            self.routeMessage(&msg, null);
        }

        /// Sanitize clientID for use in topic paths: replace /, +, # with _
        fn sanitizeForTopic(buf: []u8, client_id: []const u8) []const u8 {
            const len = @min(client_id.len, buf.len);
            for (client_id[0..len], 0..) |c, i| {
                buf[i] = if (c == '/' or c == '+' or c == '#') '_' else c;
            }
            return buf[0..len];
        }

        // ====================================================================
        // Shared topic parsing
        // ====================================================================

        const SharedTopicInfo = struct {
            group: []const u8,
            actual_topic: []const u8,
        };

        /// Parse $share/{group}/{topic} format.
        fn parseSharedTopic(topic: []const u8) ?SharedTopicInfo {
            const prefix = "$share/";
            if (topic.len <= prefix.len) return null;
            if (!std.mem.startsWith(u8, topic, prefix)) return null;
            const rest = topic[prefix.len..];
            const sep = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
            if (sep == 0) return null;
            const group = rest[0..sep];
            const actual = rest[sep + 1 ..];
            if (actual.len == 0) return null;
            return .{ .group = group, .actual_topic = actual };
        }

        // ====================================================================
        // Keepalive
        // ====================================================================

        /// Set socket recv timeout for keepalive enforcement.
        /// MQTT spec: broker should wait 1.5x keepalive before disconnecting.
        fn setKeepaliveTimeout(transport: *Transport, keep_alive: u16) void {
            if (keep_alive == 0) return;
            const timeout_ms: u32 = @as(u32, keep_alive) * 1500; // 1.5x in ms
            if (@hasDecl(Transport, "setRecvTimeout")) {
                transport.setRecvTimeout(timeout_ms);
            }
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
