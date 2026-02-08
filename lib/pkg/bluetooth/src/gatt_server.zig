//! GATT Server — Handler-based Dispatch
//!
//! Go http.Server-style handler pattern for BLE GATT services.
//! Register services and characteristics with handler functions,
//! and the server dispatches ATT requests to the appropriate handler.
//!
//! ## Architecture
//!
//! ```
//! App registers handlers:
//!   server.addService(heart_rate_uuid)
//!   server.addCharacteristic(hr_measurement_uuid, .{ .notify = true }, handler)
//!
//! ATT request arrives (from Host readLoop → L2CAP → ATT):
//!   server.handlePdu(conn_handle, att_pdu) → response PDU
//!
//! Response is sent back via Host writeData()
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const Server = gatt_server.GattServer(16); // max 16 services
//! var server = Server.init();
//!
//! // Register Heart Rate Service
//! const hr_svc = server.addService(UUID.from16(0x180D)) catch unreachable;
//! _ = server.addCharacteristic(hr_svc, UUID.from16(0x2A37), .{
//!     .read = true, .notify = true,
//! }, struct {
//!     pub fn handle(ctx: *CharContext) void {
//!         switch (ctx.op) {
//!             .read => ctx.respond(&[_]u8{ 0x00, 72 }), // heart rate = 72
//!             else => ctx.respondError(.request_not_supported),
//!         }
//!     }
//! }.handle) catch unreachable;
//! ```

const std = @import("std");
const att = @import("host/att/att.zig");

// ============================================================================
// Types
// ============================================================================

/// Operation type passed to characteristic handler
pub const Operation = enum {
    /// Read request
    read,
    /// Write request (requires response)
    write,
    /// Write command (no response)
    write_command,
};

/// Context passed to characteristic handlers
pub const CharContext = struct {
    /// Connection handle
    conn_handle: u16,
    /// Attribute handle
    attr_handle: u16,
    /// Operation type
    op: Operation,
    /// Write value (for write operations)
    value: []const u8,

    // Response state
    response_buf: *[att.MAX_PDU_LEN]u8,
    response_len: *usize,
    has_error: bool = false,

    /// Send a read response with the given value
    pub fn respond(self: *CharContext, data: []const u8) void {
        const pdu = att.encodeReadResponse(self.response_buf, data);
        self.response_len.* = pdu.len;
    }

    /// Send a write response (acknowledgement)
    pub fn respondWriteOk(self: *CharContext) void {
        const pdu = att.encodeWriteResponse(self.response_buf);
        self.response_len.* = pdu.len;
    }

    /// Send an error response
    pub fn respondError(self: *CharContext, err: att.ErrorCode) void {
        const req_opcode: att.Opcode = switch (self.op) {
            .read => .read_request,
            .write => .write_request,
            .write_command => .write_command,
        };
        const pdu = att.encodeErrorResponse(
            self.response_buf,
            req_opcode,
            self.attr_handle,
            err,
        );
        self.response_len.* = pdu.len;
        self.has_error = true;
    }
};

/// Handler function type
pub const HandlerFn = *const fn (*CharContext) void;

/// A registered characteristic
pub const Characteristic = struct {
    /// Service index this belongs to
    service_idx: u16,
    /// Characteristic UUID
    uuid: att.UUID,
    /// Properties (read, write, notify, etc.)
    properties: att.CharProps,
    /// Handler function
    handler: HandlerFn,
    /// Attribute handles (assigned during registration)
    decl_handle: u16 = 0, // characteristic declaration
    value_handle: u16 = 0, // characteristic value
    cccd_handle: u16 = 0, // CCCD (if notify/indicate)
};

/// A registered service
pub const Service = struct {
    /// Service UUID
    uuid: att.UUID,
    /// Start handle of this service
    start_handle: u16 = 0,
    /// End handle (updated as characteristics are added)
    end_handle: u16 = 0,
};

// ============================================================================
// GATT Server
// ============================================================================

/// GATT Server with fixed capacity.
///
/// `max_services` controls the maximum number of services.
/// Each service can have multiple characteristics.
/// Total attributes = services * ~3 handles per characteristic.
pub fn GattServer(comptime max_services: usize) type {
    const max_chars = max_services * 4; // ~4 chars per service
    const max_attrs = max_services * 20; // ~20 attrs per service

    return struct {
        const Self = @This();

        /// Attribute database
        db: att.AttributeDb(max_attrs) = .{},
        /// Registered services
        services: [max_services]Service = undefined,
        service_count: usize = 0,
        /// Registered characteristics
        chars: [max_chars]Characteristic = undefined,
        char_count: usize = 0,
        /// Next available handle
        next_handle: u16 = 1,
        /// Negotiated MTU per connection (simplified: single connection)
        mtu: u16 = att.DEFAULT_MTU,

        pub fn init() Self {
            return .{};
        }

        // ================================================================
        // Registration
        // ================================================================

        /// Add a primary service. Returns the service index.
        pub fn addService(self: *Self, uuid: att.UUID) !u16 {
            if (self.service_count >= max_services) return error.TooManyServices;

            const handle = self.next_handle;
            self.next_handle += 1;

            // Create service declaration attribute
            var uuid_bytes: [16]u8 = undefined;
            const uuid_len = uuid.writeTo(&uuid_bytes);

            _ = try self.db.add(.{
                .handle = handle,
                .att_type = att.UUID.from16(att.GATT_PRIMARY_SERVICE_UUID),
                .value = uuid_bytes[0..uuid_len],
                .permissions = .{ .readable = true },
            });

            const idx: u16 = @intCast(self.service_count);
            self.services[self.service_count] = .{
                .uuid = uuid,
                .start_handle = handle,
                .end_handle = handle,
            };
            self.service_count += 1;

            return idx;
        }

        /// Add a characteristic to a service. Returns the value handle.
        pub fn addCharacteristic(
            self: *Self,
            service_idx: u16,
            uuid: att.UUID,
            properties: att.CharProps,
            handler: HandlerFn,
        ) !u16 {
            if (self.char_count >= max_chars) return error.TooManyCharacteristics;
            if (service_idx >= self.service_count) return error.InvalidService;

            // Characteristic declaration handle
            const decl_handle = self.next_handle;
            self.next_handle += 1;

            // Characteristic value handle
            const value_handle = self.next_handle;
            self.next_handle += 1;

            // Build characteristic declaration value:
            // [properties(1)][value_handle(2)][uuid(2 or 16)]
            var decl_value: [19]u8 = undefined; // max: 1 + 2 + 16
            decl_value[0] = @bitCast(properties);
            std.mem.writeInt(u16, decl_value[1..3], value_handle, .little);
            const uuid_len = uuid.writeTo(decl_value[3..]);

            // Add characteristic declaration
            _ = try self.db.add(.{
                .handle = decl_handle,
                .att_type = att.UUID.from16(att.GATT_CHARACTERISTIC_UUID),
                .value = decl_value[0 .. 3 + uuid_len],
                .permissions = .{ .readable = true },
            });

            // Add characteristic value
            _ = try self.db.add(.{
                .handle = value_handle,
                .att_type = uuid,
                .value = &.{}, // dynamic — handled by handler
                .permissions = .{
                    .readable = properties.read,
                    .writable = properties.write or properties.write_without_response,
                },
            });

            var cccd_handle: u16 = 0;
            if (properties.notify or properties.indicate) {
                cccd_handle = self.next_handle;
                self.next_handle += 1;

                _ = try self.db.add(.{
                    .handle = cccd_handle,
                    .att_type = att.UUID.from16(att.GATT_CLIENT_CHAR_CONFIG_UUID),
                    .value = &.{ 0x00, 0x00 }, // default: notifications disabled
                    .permissions = .{ .readable = true, .writable = true },
                });
            }

            // Register characteristic
            self.chars[self.char_count] = .{
                .service_idx = service_idx,
                .uuid = uuid,
                .properties = properties,
                .handler = handler,
                .decl_handle = decl_handle,
                .value_handle = value_handle,
                .cccd_handle = cccd_handle,
            };
            self.char_count += 1;

            // Update service end handle
            self.services[service_idx].end_handle = self.next_handle - 1;

            return value_handle;
        }

        // ================================================================
        // ATT PDU Handling
        // ================================================================

        /// Handle an incoming ATT PDU. Returns the response PDU (if any).
        ///
        /// Called by the Host coordinator when an L2CAP SDU arrives on CID_ATT.
        pub fn handlePdu(
            self: *Self,
            conn_handle: u16,
            pdu_data: []const u8,
            response_buf: *[att.MAX_PDU_LEN]u8,
        ) ?[]const u8 {
            const pdu = att.decodePdu(pdu_data) orelse {
                const resp = att.encodeErrorResponse(
                    response_buf,
                    @enumFromInt(pdu_data[0]),
                    0x0000,
                    .invalid_pdu,
                );
                return resp;
            };

            return switch (pdu) {
                .exchange_mtu_request => |req| blk: {
                    self.mtu = @max(att.DEFAULT_MTU, @min(req.client_mtu, att.MAX_MTU));
                    break :blk att.encodeMtuResponse(response_buf, self.mtu);
                },
                .read_request => |req| self.handleRead(conn_handle, req.handle, response_buf),
                .write_request => |req| self.handleWrite(conn_handle, req.handle, req.value, false, response_buf),
                .write_command => |req| blk: {
                    _ = self.handleWrite(conn_handle, req.handle, req.value, true, response_buf);
                    break :blk null; // write command = no response
                },
                .read_by_group_type_request => |req| self.handleReadByGroupType(req.start_handle, req.end_handle, req.uuid, response_buf),
                .read_by_type_request => |req| self.handleReadByType(req.start_handle, req.end_handle, req.uuid, response_buf),
                .find_information_request => |req| self.handleFindInformation(req.start_handle, req.end_handle, response_buf),
                .handle_value_confirmation => null, // ACK for indication — no response
                else => blk: {
                    break :blk att.encodeErrorResponse(
                        response_buf,
                        @enumFromInt(pdu_data[0]),
                        0x0000,
                        .request_not_supported,
                    );
                },
            };
        }

        fn handleRead(self: *Self, conn_handle: u16, handle: u16, buf: *[att.MAX_PDU_LEN]u8) []const u8 {
            // Find the characteristic for this value handle
            for (self.chars[0..self.char_count]) |*ch| {
                if (ch.value_handle == handle) {
                    var response_len: usize = 0;
                    var ctx = CharContext{
                        .conn_handle = conn_handle,
                        .attr_handle = handle,
                        .op = .read,
                        .value = &.{},
                        .response_buf = buf,
                        .response_len = &response_len,
                    };
                    ch.handler(&ctx);
                    if (response_len > 0) return buf[0..response_len];
                    // Handler didn't respond — send empty read response
                    return att.encodeReadResponse(buf, &.{});
                }
            }

            // Check static attributes (service declarations, CCCDs, etc.)
            if (self.db.findByHandle(handle)) |attr_ref| {
                return att.encodeReadResponse(buf, attr_ref.value);
            }

            return att.encodeErrorResponse(buf, .read_request, handle, .attribute_not_found);
        }

        fn handleWrite(
            self: *Self,
            conn_handle: u16,
            handle: u16,
            value: []const u8,
            is_command: bool,
            buf: *[att.MAX_PDU_LEN]u8,
        ) ?[]const u8 {
            for (self.chars[0..self.char_count]) |*ch| {
                if (ch.value_handle == handle) {
                    var response_len: usize = 0;
                    var ctx = CharContext{
                        .conn_handle = conn_handle,
                        .attr_handle = handle,
                        .op = if (is_command) .write_command else .write,
                        .value = value,
                        .response_buf = buf,
                        .response_len = &response_len,
                    };
                    ch.handler(&ctx);
                    if (response_len > 0) return buf[0..response_len];
                    if (!is_command) return att.encodeWriteResponse(buf);
                    return null;
                }
            }

            if (!is_command) {
                return att.encodeErrorResponse(buf, .write_request, handle, .attribute_not_found);
            }
            return null;
        }

        fn handleReadByGroupType(
            self: *Self,
            start_handle: u16,
            end_handle: u16,
            uuid: att.UUID,
            buf: *[att.MAX_PDU_LEN]u8,
        ) []const u8 {
            // Only Primary Service UUID (0x2800) is valid for Read By Group Type
            if (!uuid.eql(att.UUID.from16(att.GATT_PRIMARY_SERVICE_UUID))) {
                return att.encodeErrorResponse(
                    buf,
                    .read_by_group_type_request,
                    start_handle,
                    .unsupported_group_type,
                );
            }

            // Build response: [opcode(1)][length(1)][data...]
            // Each entry: [start_handle(2)][end_handle(2)][service_uuid(2 or 16)]
            buf[0] = @intFromEnum(att.Opcode.read_by_group_type_response);
            var pos: usize = 2; // skip opcode + length byte
            var entry_len: u8 = 0;
            var found = false;

            for (self.services[0..self.service_count]) |svc| {
                if (svc.start_handle < start_handle or svc.start_handle > end_handle) continue;

                const uuid_len: u8 = @intCast(svc.uuid.byteLen());
                const this_entry_len = 4 + uuid_len; // start(2) + end(2) + uuid

                if (!found) {
                    entry_len = this_entry_len;
                    found = true;
                } else if (this_entry_len != entry_len) {
                    break; // Mixed UUID lengths — stop
                }

                if (pos + this_entry_len > self.mtu) break;

                std.mem.writeInt(u16, buf[pos..][0..2], svc.start_handle, .little);
                std.mem.writeInt(u16, buf[pos + 2 ..][0..2], svc.end_handle, .little);
                _ = svc.uuid.writeTo(buf[pos + 4 ..]);
                pos += this_entry_len;
            }

            if (!found) {
                return att.encodeErrorResponse(
                    buf,
                    .read_by_group_type_request,
                    start_handle,
                    .attribute_not_found,
                );
            }

            buf[1] = entry_len;
            return buf[0..pos];
        }

        fn handleReadByType(
            self: *Self,
            start_handle: u16,
            end_handle: u16,
            uuid: att.UUID,
            buf: *[att.MAX_PDU_LEN]u8,
        ) []const u8 {
            buf[0] = @intFromEnum(att.Opcode.read_by_type_response);
            var pos: usize = 2;
            var entry_len: u8 = 0;
            var found = false;

            var iter = self.db.findByType(start_handle, end_handle, uuid);
            while (iter.next()) |attr_ref| {
                const val_len: u8 = @intCast(@min(attr_ref.value.len, self.mtu - 4));
                const this_entry_len = 2 + val_len; // handle(2) + value

                if (!found) {
                    entry_len = this_entry_len;
                    found = true;
                } else if (this_entry_len != entry_len) {
                    break;
                }

                if (pos + this_entry_len > self.mtu) break;

                std.mem.writeInt(u16, buf[pos..][0..2], attr_ref.handle, .little);
                @memcpy(buf[pos + 2 ..][0..val_len], attr_ref.value[0..val_len]);
                pos += this_entry_len;
            }

            if (!found) {
                return att.encodeErrorResponse(
                    buf,
                    .read_by_type_request,
                    start_handle,
                    .attribute_not_found,
                );
            }

            buf[1] = entry_len;
            return buf[0..pos];
        }

        fn handleFindInformation(
            self: *Self,
            start_handle: u16,
            end_handle: u16,
            buf: *[att.MAX_PDU_LEN]u8,
        ) []const u8 {
            buf[0] = @intFromEnum(att.Opcode.find_information_response);
            var pos: usize = 2; // opcode + format
            var format: u8 = 0; // 1=16-bit, 2=128-bit
            var found = false;

            for (self.db.attrs[0..self.db.count]) |attr| {
                if (attr.handle < start_handle or attr.handle > end_handle) continue;

                const uuid_len = attr.att_type.byteLen();
                const this_format: u8 = if (uuid_len == 2) 1 else 2;
                const entry_len = 2 + uuid_len; // handle(2) + uuid

                if (!found) {
                    format = this_format;
                    found = true;
                } else if (this_format != format) {
                    break; // Mixed formats
                }

                if (pos + entry_len > self.mtu) break;

                std.mem.writeInt(u16, buf[pos..][0..2], attr.handle, .little);
                _ = attr.att_type.writeTo(buf[pos + 2 ..]);
                pos += entry_len;
            }

            if (!found) {
                return att.encodeErrorResponse(
                    buf,
                    .find_information_request,
                    start_handle,
                    .attribute_not_found,
                );
            }

            buf[1] = format;
            return buf[0..pos];
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "GATT server register service and characteristic" {
    const Server = GattServer(4);
    var server = Server.init();

    // Register Heart Rate Service
    const hr_svc = try server.addService(att.UUID.from16(0x180D));
    try std.testing.expectEqual(@as(u16, 0), hr_svc);

    // Register Heart Rate Measurement characteristic
    const hr_handle = try server.addCharacteristic(hr_svc, att.UUID.from16(0x2A37), .{
        .read = true,
        .notify = true,
    }, struct {
        pub fn handle(ctx: *CharContext) void {
            switch (ctx.op) {
                .read => ctx.respond(&[_]u8{ 0x00, 72 }),
                else => ctx.respondError(.request_not_supported),
            }
        }
    }.handle);

    try std.testing.expect(hr_handle > 0);
    try std.testing.expectEqual(@as(usize, 1), server.service_count);
    try std.testing.expectEqual(@as(usize, 1), server.char_count);
}

test "GATT server handle Read Request" {
    const Server = GattServer(4);
    var server = Server.init();

    const svc = try server.addService(att.UUID.from16(0x180D));
    const value_handle = try server.addCharacteristic(svc, att.UUID.from16(0x2A37), .{
        .read = true,
    }, struct {
        pub fn handle(ctx: *CharContext) void {
            ctx.respond(&[_]u8{ 0x00, 72 });
        }
    }.handle);

    // Build a Read Request PDU
    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.read_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    // Should be a Read Response
    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.read_response)), resp[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 72 }, resp[1..]);
}

test "GATT server handle Write Request" {
    const Server = GattServer(4);
    var server = Server.init();

    const svc = try server.addService(att.UUID.from16(0x180D));

    _ = try server.addCharacteristic(svc, att.UUID.from16(0x2A39), .{
        .read = true,
        .write = true,
    }, struct {
        pub fn handle(ctx: *CharContext) void {
            switch (ctx.op) {
                .write => ctx.respondWriteOk(),
                .read => ctx.respond(&[_]u8{0}),
                else => {},
            }
        }
    }.handle);

    // Build a Write Request
    var req_buf: [4]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.write_request);
    std.mem.writeInt(u16, req_buf[1..3], server.chars[0].value_handle, .little);
    req_buf[3] = 42;

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    // Should be a Write Response
    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.write_response)), resp[0]);
}

test "GATT server handle Exchange MTU Request" {
    const Server = GattServer(4);
    var server = Server.init();

    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.exchange_mtu_request);
    std.mem.writeInt(u16, req_buf[1..3], 247, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.exchange_mtu_response)), resp[0]);
    try std.testing.expectEqual(@as(u16, 247), server.mtu);
}

test "GATT server handle Read By Group Type (discover services)" {
    const Server = GattServer(4);
    var server = Server.init();

    _ = try server.addService(att.UUID.from16(0x180D)); // Heart Rate
    _ = try server.addService(att.UUID.from16(0x180F)); // Battery

    // Read By Group Type: Primary Service (0x2800)
    var req_buf: [7]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.read_by_group_type_request);
    std.mem.writeInt(u16, req_buf[1..3], 0x0001, .little);
    std.mem.writeInt(u16, req_buf[3..5], 0xFFFF, .little);
    std.mem.writeInt(u16, req_buf[5..7], att.GATT_PRIMARY_SERVICE_UUID, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.read_by_group_type_response)), resp[0]);
    try std.testing.expectEqual(@as(u8, 6), resp[1]); // entry length: 2+2+2=6
    // At least one service entry should be present
    try std.testing.expect(resp.len >= 8); // header(2) + entry(6)
}
