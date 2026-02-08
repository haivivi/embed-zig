//! MQTT Client — connects to a broker, publishes, subscribes, dispatches via Mux.
//!
//! Features:
//! - MQTT 3.1.1 (v4) and 5.0 (v5) support
//! - Mux-based message dispatch (handlers registered by topic pattern)
//! - Session Expiry (v5)
//! - Write mutex for concurrent publish safety
//! - Dynamic packet buffers (supports messages up to max_packet_size)
//! - Reconnect with auto-resubscribe
//!
//! Usage:
//!     var mux = try Mux.init(allocator);
//!     try mux.handleFn("device/+/state", handleState);
//!
//!     var client = try Client(Socket).init(&socket, &mux, .{
//!         .client_id = "dev-001",
//!         .protocol_version = .v5,
//!         .session_expiry = 3600,
//!         .allocator = allocator,
//!     });
//!     try client.subscribe(&.{"device/+/state"});
//!     try client.readLoop(); // blocks, dispatches to mux

const std = @import("std");
const pkt = @import("packet.zig");
const v4 = @import("v4.zig");
const v5 = @import("v5.zig");
const mux_mod = @import("mux.zig");

const Message = pkt.Message;
const Mux = mux_mod.Mux;
const ProtocolVersion = pkt.ProtocolVersion;

pub fn Client(comptime Transport: type) type {
    return struct {
        const Self = @This();

        /// Stored subscription entry (owned copy of topic string).
        const SubEntry = struct {
            buf: [256]u8 = undefined,
            len: usize = 0,

            fn topic(self: *const SubEntry) []const u8 {
                return self.buf[0..self.len];
            }

            fn from(t: []const u8) SubEntry {
                var e = SubEntry{};
                const l = @min(t.len, 256);
                @memcpy(e.buf[0..l], t[0..l]);
                e.len = l;
                return e;
            }
        };

        pub const Config = struct {
            client_id: []const u8 = "",
            username: []const u8 = "",
            password: []const u8 = "",
            keep_alive: u16 = 60,
            clean_start: bool = true,
            protocol_version: ProtocolVersion = .v4,
            session_expiry: ?u32 = null,
            allocator: std.mem.Allocator = std.heap.page_allocator,
        };

        transport: *Transport,
        mux: *Mux,
        config: Config,
        connected: bool = false,
        next_packet_id: u16 = 1,
        read_buf: pkt.PacketBuffer,
        write_buf: pkt.PacketBuffer,
        write_mutex: std.Thread.Mutex = .{},
        /// Tracked subscriptions for auto-resubscribe on reconnect.
        subscriptions: std.ArrayListUnmanaged(SubEntry) = .empty,

        // ---- Lifecycle ----

        pub fn init(transport: *Transport, mux: *Mux, config: Config) !Self {
            var self = Self{
                .transport = transport,
                .mux = mux,
                .config = config,
                .read_buf = pkt.PacketBuffer.init(config.allocator),
                .write_buf = pkt.PacketBuffer.init(config.allocator),
            };
            try self.doConnect();
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.connected) self.doDisconnect();
            self.read_buf.deinit();
            self.write_buf.deinit();
            self.subscriptions.deinit(self.config.allocator);
        }

        // ---- Reconnect ----

        /// Reconnect on a new transport. Re-sends CONNECT and re-subscribes
        /// all previously subscribed topics.
        /// Caller is responsible for establishing the new transport (TCP/TLS).
        pub fn reconnect(self: *Self, new_transport: *Transport) !void {
            self.transport = new_transport;
            self.connected = false;
            try self.doConnect();

            // Re-subscribe all tracked topics
            if (self.subscriptions.items.len > 0) {
                var topics_buf: [64][]const u8 = undefined;
                const count = @min(self.subscriptions.items.len, 64);
                for (self.subscriptions.items[0..count], 0..) |*entry, i| {
                    topics_buf[i] = entry.topic();
                }
                self.doSubscribe(topics_buf[0..count]) catch {};
            }
        }

        // ---- Pub/Sub ----

        pub fn subscribe(self: *Self, topics: []const []const u8) !void {
            if (!self.connected) return error.NotConnected;
            try self.doSubscribe(topics);

            // Track subscriptions for reconnect
            for (topics) |t| {
                // Check if already tracked
                var found = false;
                for (self.subscriptions.items) |*e| {
                    if (std.mem.eql(u8, e.topic(), t)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try self.subscriptions.append(self.config.allocator, SubEntry.from(t));
                }
            }
        }

        pub fn unsubscribe(self: *Self, topics: []const []const u8) !void {
            if (!self.connected) return error.NotConnected;
            const pid = self.nextPid();

            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            const wb = try self.write_buf.acquire(4096);

            switch (self.config.protocol_version) {
                .v4 => {
                    const unsub = v4.Unsubscribe{ .packet_id = pid, .topics = topics };
                    const len = try v4.encodeUnsubscribe(wb, &unsub);
                    try pkt.writeAll(self.transport, wb[0..len]);
                },
                .v5 => {
                    const len = try v5.encodeUnsubscribe(wb, pid, topics, &.{});
                    try pkt.writeAll(self.transport, wb[0..len]);
                },
            }

            // Remove from tracked subscriptions
            for (topics) |t| {
                var i: usize = 0;
                while (i < self.subscriptions.items.len) {
                    if (std.mem.eql(u8, self.subscriptions.items[i].topic(), t)) {
                        _ = self.subscriptions.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void {
            return self.publishMessage(&.{ .topic = topic, .payload = payload });
        }

        pub fn publishMessage(self: *Self, msg: *const Message) !void {
            if (!self.connected) return error.NotConnected;

            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            // Acquire buffer large enough for topic + payload + overhead
            const needed = msg.topic.len + msg.payload.len + 128;
            const wb = try self.write_buf.acquire(needed);

            switch (self.config.protocol_version) {
                .v4 => {
                    const len = try v4.encodePublish(wb, &.{
                        .topic = msg.topic,
                        .payload = msg.payload,
                        .retain = msg.retain,
                    });
                    try pkt.writeAll(self.transport, wb[0..len]);
                },
                .v5 => {
                    const len = try v5.encodePublish(wb, &.{
                        .topic = msg.topic,
                        .payload = msg.payload,
                        .retain = msg.retain,
                    });
                    try pkt.writeAll(self.transport, wb[0..len]);
                },
            }
        }

        // ---- Read Loop ----

        pub fn readLoop(self: *Self) !void {
            while (self.connected) {
                try self.poll();
            }
        }

        pub fn poll(self: *Self) !void {
            const pkt_len = pkt.readPacketBuf(self.transport, &self.read_buf) catch |err| {
                self.connected = false;
                return err;
            };
            const data = self.read_buf.slice()[0..pkt_len];
            try self.dispatchPacket(data);
        }

        // ---- Keepalive ----

        pub fn ping(self: *Self) !void {
            if (!self.connected) return error.NotConnected;
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            const wb = try self.write_buf.acquire(4);
            const len = switch (self.config.protocol_version) {
                .v4 => try v4.encodePingReq(wb),
                .v5 => try v5.encodePingReq(wb),
            };
            try pkt.writeAll(self.transport, wb[0..len]);
        }

        pub fn isConnected(self: *const Self) bool {
            return self.connected;
        }

        // ====================================================================
        // Private
        // ====================================================================

        fn doSubscribe(self: *Self, topics: []const []const u8) !void {
            const pid = self.nextPid();
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            const wb = try self.write_buf.acquire(4096);

            switch (self.config.protocol_version) {
                .v4 => {
                    const sub = v4.Subscribe{ .packet_id = pid, .topics = topics };
                    const len = try v4.encodeSubscribe(wb, &sub);
                    try pkt.writeAll(self.transport, wb[0..len]);
                },
                .v5 => {
                    const len = try v5.encodeSubscribe(wb, pid, topics, &.{});
                    try pkt.writeAll(self.transport, wb[0..len]);
                },
            }

            // Read SUBACK
            const pkt_len = try pkt.readPacketBuf(self.transport, &self.read_buf);
            const buf = self.read_buf.slice()[0..pkt_len];
            switch (self.config.protocol_version) {
                .v4 => {
                    const result = try v4.decodePacket(buf);
                    switch (result.packet) {
                        .suback => |sa| {
                            if (sa.packet_id != pid) return error.ProtocolError;
                            for (sa.return_codes) |code| {
                                if (code == 0x80) return error.SubscribeFailed;
                            }
                        },
                        else => return error.UnexpectedPacket,
                    }
                },
                .v5 => {
                    const result = try v5.decodePacket(buf);
                    switch (result.packet) {
                        .suback => |sa| {
                            if (sa.packet_id != pid) return error.ProtocolError;
                            for (sa.reason_codes) |rc| {
                                if (rc.isError()) return error.SubscribeFailed;
                            }
                        },
                        else => return error.UnexpectedPacket,
                    }
                },
            }
        }

        fn doConnect(self: *Self) !void {
            const wb = try self.write_buf.acquire(4096);
            switch (self.config.protocol_version) {
                .v4 => {
                    const len = try v4.encodeConnect(wb, &.{
                        .client_id = self.config.client_id,
                        .username = self.config.username,
                        .password = self.config.password,
                        .clean_session = self.config.clean_start,
                        .keep_alive = self.config.keep_alive,
                    });
                    try pkt.writeAll(self.transport, wb[0..len]);

                    const pkt_len = try pkt.readPacketBuf(self.transport, &self.read_buf);
                    const result = try v4.decodePacket(self.read_buf.slice()[0..pkt_len]);
                    switch (result.packet) {
                        .connack => |ca| {
                            if (ca.return_code != .accepted) return error.ConnectionRefused;
                            self.connected = true;
                        },
                        else => return error.UnexpectedPacket,
                    }
                },
                .v5 => {
                    var props = v5.Properties{};
                    if (self.config.session_expiry) |se| props.session_expiry = se;

                    const len = try v5.encodeConnect(wb, &.{
                        .client_id = self.config.client_id,
                        .username = self.config.username,
                        .password = self.config.password,
                        .clean_start = self.config.clean_start,
                        .keep_alive = self.config.keep_alive,
                        .properties = props,
                    });
                    try pkt.writeAll(self.transport, wb[0..len]);

                    const pkt_len = try pkt.readPacketBuf(self.transport, &self.read_buf);
                    const result = try v5.decodePacket(self.read_buf.slice()[0..pkt_len]);
                    switch (result.packet) {
                        .connack => |ca| {
                            if (ca.reason_code != .success) return error.ConnectionRefused;
                            self.connected = true;
                        },
                        else => return error.UnexpectedPacket,
                    }
                },
            }
        }

        fn doDisconnect(self: *Self) void {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            const wb = self.write_buf.acquire(4) catch return;
            const len = switch (self.config.protocol_version) {
                .v4 => v4.encodeDisconnect(wb) catch return,
                .v5 => v5.encodeDisconnect(wb, &.{}) catch return,
            };
            pkt.writeAll(self.transport, wb[0..len]) catch {};
            self.connected = false;
        }

        fn dispatchPacket(self: *Self, data: []const u8) !void {
            const hdr = try pkt.decodeFixedHeader(data);
            switch (hdr.packet_type) {
                .publish => {
                    switch (self.config.protocol_version) {
                        .v4 => {
                            const result = try v4.decodePacket(data);
                            const p = result.packet.publish;
                            const msg = Message{ .topic = p.topic, .payload = p.payload, .retain = p.retain };
                            try self.mux.handleMessage(self.config.client_id, &msg);
                        },
                        .v5 => {
                            const result = try v5.decodePacket(data);
                            const p = result.packet.publish;
                            const msg = Message{ .topic = p.topic, .payload = p.payload, .retain = p.retain };
                            try self.mux.handleMessage(self.config.client_id, &msg);
                        },
                    }
                },
                .pingresp => {},
                .disconnect => {
                    self.connected = false;
                },
                else => {},
            }
        }

        fn nextPid(self: *Self) u16 {
            const id = self.next_packet_id;
            self.next_packet_id +%= 1;
            if (self.next_packet_id == 0) self.next_packet_id = 1;
            return id;
        }
    };
}
