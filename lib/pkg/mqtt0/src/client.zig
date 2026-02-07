//! MQTT Client — connects to a broker, publishes, subscribes, dispatches via Mux.
//!
//! Generic over Transport type (anything with send/recv).
//! Received messages are automatically dispatched through the Mux.
//!
//! Usage:
//!     var mux = try Mux.init(allocator);
//!     try mux.handleFn("device/+/state", handleState);
//!
//!     var client = try Client(Socket).init(&socket, &mux, .{ .client_id = "dev-001" });
//!     try client.subscribe(&.{"device/+/state"});
//!     try client.readLoop(); // blocks, dispatches to mux

const std = @import("std");
const pkt = @import("packet.zig");
const v4 = @import("v4.zig");
const v5 = @import("v5.zig");
const mux_mod = @import("mux.zig");

const Message = pkt.Message;
const Handler = mux_mod.Handler;
const Mux = mux_mod.Mux;
const ProtocolVersion = pkt.ProtocolVersion;

pub fn Client(comptime Transport: type) type {
    return struct {
        const Self = @This();

        pub const Config = struct {
            client_id: []const u8 = "",
            username: []const u8 = "",
            password: []const u8 = "",
            keep_alive: u16 = 60,
            clean_start: bool = true,
            protocol_version: ProtocolVersion = .v4,
        };

        transport: *Transport,
        mux: *Mux,
        config: Config,
        connected: bool = false,
        next_packet_id: u16 = 1,
        buf: [8192]u8 = undefined,

        // ---- Lifecycle ----

        /// Connect to broker (sends CONNECT, waits for CONNACK).
        pub fn init(transport: *Transport, mux: *Mux, config: Config) !Self {
            var self = Self{
                .transport = transport,
                .mux = mux,
                .config = config,
            };
            try self.doConnect();
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.connected) {
                self.doDisconnect();
            }
        }

        // ---- Pub/Sub ----

        /// Subscribe to topic filters (sends SUBSCRIBE, waits for SUBACK).
        pub fn subscribe(self: *Self, topics: []const []const u8) !void {
            if (!self.connected) return error.NotConnected;
            const pid = self.nextPid();

            switch (self.config.protocol_version) {
                .v4 => {
                    const sub = v4.Subscribe{ .packet_id = pid, .topics = topics };
                    const len = try v4.encodeSubscribe(&self.buf, &sub);
                    try pkt.writeAll(self.transport, self.buf[0..len]);

                    // Wait for SUBACK
                    const pkt_len = try pkt.readPacket(self.transport, &self.buf);
                    const result = try v4.decodePacket(self.buf[0..pkt_len]);
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
                    const len = try v5.encodeSubscribe(&self.buf, pid, topics, &.{});
                    try pkt.writeAll(self.transport, self.buf[0..len]);

                    const pkt_len = try pkt.readPacket(self.transport, &self.buf);
                    const result = try v5.decodePacket(self.buf[0..pkt_len]);
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

        /// Unsubscribe from topics.
        pub fn unsubscribe(self: *Self, topics: []const []const u8) !void {
            if (!self.connected) return error.NotConnected;
            const pid = self.nextPid();

            switch (self.config.protocol_version) {
                .v4 => {
                    const unsub = v4.Unsubscribe{ .packet_id = pid, .topics = topics };
                    const len = try v4.encodeUnsubscribe(&self.buf, &unsub);
                    try pkt.writeAll(self.transport, self.buf[0..len]);
                },
                .v5 => {
                    const len = try v5.encodeUnsubscribe(&self.buf, pid, topics, &.{});
                    try pkt.writeAll(self.transport, self.buf[0..len]);
                },
            }
        }

        /// Publish a message (QoS 0).
        pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void {
            return self.publishMessage(&.{
                .topic = topic,
                .payload = payload,
            });
        }

        /// Publish with full message options.
        pub fn publishMessage(self: *Self, msg: *const Message) !void {
            if (!self.connected) return error.NotConnected;

            switch (self.config.protocol_version) {
                .v4 => {
                    const p = v4.Publish{
                        .topic = msg.topic,
                        .payload = msg.payload,
                        .retain = msg.retain,
                    };
                    const len = try v4.encodePublish(&self.buf, &p);
                    try pkt.writeAll(self.transport, self.buf[0..len]);
                },
                .v5 => {
                    const p = v5.Publish{
                        .topic = msg.topic,
                        .payload = msg.payload,
                        .retain = msg.retain,
                    };
                    const len = try v5.encodePublish(&self.buf, &p);
                    try pkt.writeAll(self.transport, self.buf[0..len]);
                },
            }
        }

        // ---- Read Loop ----

        /// Run the receive loop. Blocks, reads packets, dispatches to mux.
        /// Returns on disconnect or error.
        pub fn readLoop(self: *Self) !void {
            while (self.connected) {
                const pkt_len = pkt.readPacket(self.transport, &self.buf) catch |err| {
                    self.connected = false;
                    return err;
                };

                try self.handlePacket(self.buf[0..pkt_len]);
            }
        }

        // ---- Keepalive ----

        /// Send PINGREQ.
        pub fn ping(self: *Self) !void {
            if (!self.connected) return error.NotConnected;
            const len = switch (self.config.protocol_version) {
                .v4 => try v4.encodePingReq(&self.buf),
                .v5 => try v5.encodePingReq(&self.buf),
            };
            try pkt.writeAll(self.transport, self.buf[0..len]);
        }

        /// Check if connected.
        pub fn isConnected(self: *const Self) bool {
            return self.connected;
        }

        // ====================================================================
        // Private
        // ====================================================================

        fn doConnect(self: *Self) !void {
            switch (self.config.protocol_version) {
                .v4 => {
                    const connect = v4.Connect{
                        .client_id = self.config.client_id,
                        .username = self.config.username,
                        .password = self.config.password,
                        .clean_session = self.config.clean_start,
                        .keep_alive = self.config.keep_alive,
                    };
                    const len = try v4.encodeConnect(&self.buf, &connect);
                    try pkt.writeAll(self.transport, self.buf[0..len]);

                    const pkt_len = try pkt.readPacket(self.transport, &self.buf);
                    const result = try v4.decodePacket(self.buf[0..pkt_len]);
                    switch (result.packet) {
                        .connack => |ca| {
                            if (ca.return_code != .accepted) return error.ConnectionRefused;
                            self.connected = true;
                        },
                        else => return error.UnexpectedPacket,
                    }
                },
                .v5 => {
                    const connect = v5.Connect{
                        .client_id = self.config.client_id,
                        .username = self.config.username,
                        .password = self.config.password,
                        .clean_start = self.config.clean_start,
                        .keep_alive = self.config.keep_alive,
                    };
                    const len = try v5.encodeConnect(&self.buf, &connect);
                    try pkt.writeAll(self.transport, self.buf[0..len]);

                    const pkt_len = try pkt.readPacket(self.transport, &self.buf);
                    const result = try v5.decodePacket(self.buf[0..pkt_len]);
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
            const len = switch (self.config.protocol_version) {
                .v4 => v4.encodeDisconnect(&self.buf) catch return,
                .v5 => v5.encodeDisconnect(&self.buf, &.{}) catch return,
            };
            pkt.writeAll(self.transport, self.buf[0..len]) catch {};
            self.connected = false;
        }

        fn handlePacket(self: *Self, data: []const u8) !void {
            const hdr = try pkt.decodeFixedHeader(data);

            switch (hdr.packet_type) {
                .publish => {
                    switch (self.config.protocol_version) {
                        .v4 => {
                            const result = try v4.decodePacket(data);
                            const p = result.packet.publish;
                            const msg = Message{
                                .topic = p.topic,
                                .payload = p.payload,
                                .retain = p.retain,
                            };
                            try self.mux.handleMessage(&msg);
                        },
                        .v5 => {
                            const result = try v5.decodePacket(data);
                            const p = result.packet.publish;
                            const msg = Message{
                                .topic = p.topic,
                                .payload = p.payload,
                                .retain = p.retain,
                            };
                            try self.mux.handleMessage(&msg);
                        },
                    }
                },
                .pingresp => {}, // Ignore
                .disconnect => {
                    self.connected = false;
                },
                else => {}, // Ignore other packets in read loop
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
