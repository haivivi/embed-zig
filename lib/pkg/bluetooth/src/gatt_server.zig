//! GATT Server — Go ServeMux-style Handler Pattern
//!
//! Comptime service table defines the schema (UUIDs + properties).
//! Runtime handler binding associates functions with characteristics.
//! Handlers run async in separate tasks, never blocking readLoop.
//!
//! ## Design (Go http analogy)
//!
//! | Go HTTP              | BLE GATT                            |
//! |----------------------|-------------------------------------|
//! | `http.ServeMux`      | `GattServer(service_table)`         |
//! | `mux.HandleFunc`     | `server.handle(svc, chr, fn, ctx)`  |
//! | `http.Request`       | `Request` (op, conn, data)          |
//! | `http.ResponseWriter`| `ResponseWriter` (write, notify)    |
//! | URL path             | service_uuid / char_uuid            |
//! | GET/POST             | read / write / write_cmd            |
//!
//! ## Usage
//!
//! ```zig
//! // Step 1: Define service table at comptime
//! const my_server = GattServer(.{
//!     Service(0x180D, .{                           // Heart Rate
//!         Char(0x2A37, .{ .read = true, .notify = true }),  // Measurement
//!         Char(0x2A38, .{ .read = true }),                   // Body Sensor Location
//!     }),
//!     Service(0xFFE0, .{                           // Custom
//!         Char(0xFFE1, .{ .write = true, .notify = true }),
//!     }),
//! });
//!
//! // Step 2: Create instance
//! var server = my_server.init();
//!
//! // Step 3: Register handlers at runtime (like Go HandleFunc)
//! server.handle(0x180D, 0x2A37, struct {
//!     pub fn serve(req: *Request, w: *ResponseWriter) void {
//!         switch (req.op) {
//!             .read => w.write(&[_]u8{ 0x00, 72 }),
//!             else => w.err(.request_not_supported),
//!         }
//!     }
//! }.serve, null);
//!
//! // Step 4: Host dispatches ATT PDUs to server automatically
//! ```

const std = @import("std");
const trait = @import("trait");
const waitgroup = @import("waitgroup");
const att = @import("host/att/att.zig");

// ============================================================================
// Comptime Service/Characteristic Definition
// ============================================================================

/// Define a characteristic (comptime).
pub const CharDef = struct {
    uuid: att.UUID,
    props: att.CharProps,
};

/// Define a service (comptime).
pub const ServiceDef = struct {
    uuid: att.UUID,
    chars: []const CharDef,
};

/// Shorthand: create a 16-bit UUID characteristic definition.
pub fn Char(comptime uuid16: u16, comptime props: att.CharProps) CharDef {
    return .{ .uuid = att.UUID.from16(uuid16), .props = props };
}

/// Shorthand: create a 16-bit UUID service definition.
pub fn Service(comptime uuid16: u16, comptime chars: []const CharDef) ServiceDef {
    return .{ .uuid = att.UUID.from16(uuid16), .chars = chars };
}

// ============================================================================
// Handler Function Type
// ============================================================================

/// Handler function signature (like http.HandlerFunc).
/// Called in async context — may block, allocate, do I/O.
pub const HandlerFn = *const fn (*Request, *ResponseWriter) void;

// ============================================================================
// Request (like http.Request)
// ============================================================================

/// Operation type
pub const Operation = enum {
    read,
    write,
    write_command,
};

/// Request passed to handler (like http.Request).
pub const Request = struct {
    /// Operation type
    op: Operation,
    /// Connection handle
    conn_handle: u16,
    /// Attribute handle
    attr_handle: u16,
    /// Service UUID
    service_uuid: att.UUID,
    /// Characteristic UUID
    char_uuid: att.UUID,
    /// Write data (for write/write_command ops)
    data: []const u8,
    /// User context (passed during handle() registration)
    user_ctx: ?*anyopaque,
};

// ============================================================================
// ResponseWriter (like http.ResponseWriter)
// ============================================================================

/// ResponseWriter for handler to produce response (like http.ResponseWriter).
pub const ResponseWriter = struct {
    buf: *[att.MAX_PDU_LEN]u8,
    len: *usize,
    req_opcode: att.Opcode,
    attr_handle: u16,
    has_response: bool = false,

    /// Write response data (for read requests).
    pub fn write(self: *ResponseWriter, data: []const u8) void {
        const pdu = att.encodeReadResponse(self.buf, data);
        self.len.* = pdu.len;
        self.has_response = true;
    }

    /// Acknowledge a write request (Write Response).
    pub fn ok(self: *ResponseWriter) void {
        const pdu = att.encodeWriteResponse(self.buf);
        self.len.* = pdu.len;
        self.has_response = true;
    }

    /// Send an error response.
    pub fn err(self: *ResponseWriter, code: att.ErrorCode) void {
        const pdu = att.encodeErrorResponse(self.buf, self.req_opcode, self.attr_handle, code);
        self.len.* = pdu.len;
        self.has_response = true;
    }
};

// ============================================================================
// GATT Server
// ============================================================================

/// Create a GATT Server type from a comptime service table.
///
/// The service table is fixed at compile time (UUIDs + properties).
/// Handlers are bound at runtime via `handle()`.
///
/// `Rt` is the Runtime type providing Mutex, Condition, and spawn (see lib/trait).
/// When `enableAsync()` is called with a WaitGroup, handler invocations are
/// dispatched to independent tasks via `WaitGroup.go()`, keeping the readLoop
/// unblocked. Without `enableAsync()`, handlers run synchronously (useful for tests).
pub fn GattServer(comptime Rt: type, comptime services: []const ServiceDef) type {
    comptime {
        _ = trait.sync.Mutex(Rt.Mutex);
        _ = trait.sync.Condition(Rt.Condition, Rt.Mutex);
        trait.spawner.from(Rt);
    }

    const WG = waitgroup.WaitGroup(Rt);
    // Compute totals at comptime
    const total_chars = comptime blk: {
        var n: usize = 0;
        for (services) |svc| n += svc.chars.len;
        break :blk n;
    };

    const total_attrs = comptime blk: {
        var n: usize = 0;
        for (services) |svc| {
            n += 1; // service declaration
            for (svc.chars) |chr| {
                n += 2; // char declaration + value
                if (chr.props.notify or chr.props.indicate) n += 1; // CCCD
            }
        }
        break :blk n;
    };

    // Build attribute database at comptime
    const AttrEntry = struct {
        handle: u16,
        att_type: att.UUID,
        /// For service decl: service UUID bytes. For char decl: props+handle+uuid.
        static_value: [19]u8 = .{0} ** 19,
        static_value_len: u8 = 0,
        permissions: att.Permissions,
        /// Index into chars array (-1 = not a char value)
        char_index: i16 = -1,
        /// Parent service index
        service_index: u16 = 0,
    };

    const db = comptime blk: {
        var attrs: [total_attrs]AttrEntry = undefined;
        var handle: u16 = 1;
        var attr_idx: usize = 0;
        var char_flat_idx: usize = 0;

        for (services, 0..) |svc, svc_idx| {
            // Service declaration
            var svc_val: [19]u8 = .{0} ** 19;
            const svc_uuid_len = svc.uuid.writeTo(&svc_val);
            attrs[attr_idx] = .{
                .handle = handle,
                .att_type = att.UUID.from16(att.GATT_PRIMARY_SERVICE_UUID),
                .static_value = svc_val,
                .static_value_len = @intCast(svc_uuid_len),
                .permissions = .{ .readable = true },
                .service_index = @intCast(svc_idx),
            };
            const svc_start_handle = handle;
            _ = svc_start_handle;
            handle += 1;
            attr_idx += 1;

            for (svc.chars) |chr| {
                // Characteristic declaration
                var decl_val: [19]u8 = .{0} ** 19;
                decl_val[0] = @bitCast(chr.props);
                const value_handle = handle + 1;
                decl_val[1] = @truncate(value_handle);
                decl_val[2] = @truncate(value_handle >> 8);
                const chr_uuid_len = chr.uuid.writeTo(decl_val[3..]);

                attrs[attr_idx] = .{
                    .handle = handle,
                    .att_type = att.UUID.from16(att.GATT_CHARACTERISTIC_UUID),
                    .static_value = decl_val,
                    .static_value_len = @intCast(3 + chr_uuid_len),
                    .permissions = .{ .readable = true },
                    .service_index = @intCast(svc_idx),
                };
                handle += 1;
                attr_idx += 1;

                // Characteristic value
                attrs[attr_idx] = .{
                    .handle = handle,
                    .att_type = chr.uuid,
                    .permissions = .{
                        .readable = chr.props.read,
                        .writable = chr.props.write or chr.props.write_without_response,
                    },
                    .char_index = @intCast(char_flat_idx),
                    .service_index = @intCast(svc_idx),
                };
                handle += 1;
                attr_idx += 1;

                // CCCD (if notify or indicate)
                if (chr.props.notify or chr.props.indicate) {
                    const cccd_val: [19]u8 = .{0} ** 19;
                    attrs[attr_idx] = .{
                        .handle = handle,
                        .att_type = att.UUID.from16(att.GATT_CLIENT_CHAR_CONFIG_UUID),
                        .static_value = cccd_val,
                        .static_value_len = 2,
                        .permissions = .{ .readable = true, .writable = true },
                        .service_index = @intCast(svc_idx),
                    };
                    handle += 1;
                    attr_idx += 1;
                }

                char_flat_idx += 1;
            }
        }

        break :blk attrs;
    };

    // Compute service end handles at comptime
    const svc_ranges = comptime blk: {
        var ranges: [services.len][2]u16 = undefined;
        var attr_idx: usize = 0;
        for (services, 0..) |_, svc_idx| {
            const start = db[attr_idx].handle;
            // Find last attr belonging to this service
            var end_handle = start;
            while (attr_idx < total_attrs and db[attr_idx].service_index == svc_idx) {
                end_handle = db[attr_idx].handle;
                attr_idx += 1;
            }
            ranges[svc_idx] = .{ start, end_handle };
        }
        break :blk ranges;
    };

    return struct {
        const Self = @This();

        /// Service table (comptime, for reference)
        pub const service_table = services;
        pub const char_count = total_chars;
        pub const attr_count = total_attrs;

        // ================================================================
        // Runtime state
        // ================================================================

        /// Handler functions (bound at runtime)
        handlers: [total_chars]?HandlerBinding = .{null} ** total_chars,

        /// CCCD state: notification/indication enabled per characteristic
        /// Bit 0 = notifications enabled, Bit 1 = indications enabled
        cccd_state: [total_chars]u16 = .{0} ** total_chars,

        /// Negotiated MTU
        mtu: u16 = att.DEFAULT_MTU,

        // ================================================================
        // Async dispatch (optional — null = sync mode)
        // ================================================================

        /// WaitGroup for spawning handler tasks (lifecycle-tracked).
        wg: ?*WG = null,
        /// Allocator for handler task context (heap-allocated per request).
        async_allocator: ?std.mem.Allocator = null,
        /// Callback to send ATT response from handler task back to transport.
        response_fn: ?ResponseFn = null,
        /// Opaque context passed to response_fn (typically *Host).
        response_ctx: ?*anyopaque = null,

        /// Callback signature for sending an ATT response from an async handler task.
        /// The implementation should fragment via L2CAP and enqueue to tx_queue.
        pub const ResponseFn = *const fn (ctx: ?*anyopaque, conn_handle: u16, data: []const u8) void;

        const HandlerBinding = struct {
            func: HandlerFn,
            ctx: ?*anyopaque,
        };

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Enable async handler dispatch.
        /// After this call, user handlers are spawned via `wg.go()` in independent tasks.
        /// Responses are sent through `resp_fn` instead of being returned from `handlePdu`.
        /// Must be called after the server is at its final memory location (e.g., in Host.start()).
        pub fn enableAsync(self: *Self, wg: *WG, allocator: std.mem.Allocator, resp_fn: ResponseFn, resp_ctx: ?*anyopaque) void {
            self.wg = wg;
            self.async_allocator = allocator;
            self.response_fn = resp_fn;
            self.response_ctx = resp_ctx;
        }

        // ================================================================
        // Handler Registration (like Go ServeMux.HandleFunc)
        // ================================================================

        /// Register a handler for a characteristic by service + char UUID (16-bit).
        ///
        /// ```zig
        /// server.handle(0x180D, 0x2A37, myHandler, &my_ctx);
        /// ```
        pub fn handle(self: *Self, comptime svc_uuid16: u16, comptime char_uuid16: u16, func: HandlerFn, ctx: ?*anyopaque) void {
            const idx = comptime findCharIndex(svc_uuid16, char_uuid16);
            self.handlers[idx] = .{ .func = func, .ctx = ctx };
        }

        /// Register a handler by flat characteristic index.
        pub fn handleByIndex(self: *Self, char_index: usize, func: HandlerFn, ctx: ?*anyopaque) void {
            if (char_index < total_chars) {
                self.handlers[char_index] = .{ .func = func, .ctx = ctx };
            }
        }

        /// Check if notifications are enabled for a characteristic.
        pub fn isNotifyEnabled(self: *const Self, comptime svc_uuid16: u16, comptime char_uuid16: u16) bool {
            const idx = comptime findCharIndex(svc_uuid16, char_uuid16);
            return (self.cccd_state[idx] & 0x0001) != 0;
        }

        /// Check if indications are enabled for a characteristic.
        pub fn isIndicateEnabled(self: *const Self, comptime svc_uuid16: u16, comptime char_uuid16: u16) bool {
            const idx = comptime findCharIndex(svc_uuid16, char_uuid16);
            return (self.cccd_state[idx] & 0x0002) != 0;
        }

        /// Get the ATT handle for a characteristic value (for notifications).
        pub fn getValueHandle(comptime svc_uuid16: u16, comptime char_uuid16: u16) u16 {
            const idx = comptime findCharIndex(svc_uuid16, char_uuid16);
            // Find the attr with char_index == idx
            inline for (db) |a| {
                if (a.char_index == idx) return a.handle;
            }
            @compileError("characteristic not found in attribute database");
        }

        // ================================================================
        // ATT PDU Dispatch (called by Host readLoop)
        // ================================================================

        /// Handle an incoming ATT PDU. Returns response PDU or null.
        pub fn handlePdu(
            self: *Self,
            conn_handle: u16,
            pdu_data: []const u8,
            response_buf: *[att.MAX_PDU_LEN]u8,
        ) ?[]const u8 {
            const pdu = att.decodePdu(pdu_data) orelse {
                return att.encodeErrorResponse(
                    response_buf,
                    @enumFromInt(pdu_data[0]),
                    0x0000,
                    .invalid_pdu,
                );
            };

            return switch (pdu) {
                .exchange_mtu_request => |req| blk: {
                    self.mtu = @max(att.DEFAULT_MTU, @min(req.client_mtu, att.MAX_MTU));
                    break :blk att.encodeMtuResponse(response_buf, self.mtu);
                },
                .read_request => |req| self.dispatchRead(conn_handle, req.handle, response_buf),
                .write_request => |req| self.dispatchWrite(conn_handle, req.handle, req.value, false, response_buf),
                .write_command => |req| blk: {
                    _ = self.dispatchWrite(conn_handle, req.handle, req.value, true, response_buf);
                    break :blk null;
                },
                .read_by_group_type_request => |req| self.handleReadByGroupType(req.start_handle, req.end_handle, req.uuid, response_buf),
                .read_by_type_request => |req| self.handleReadByType(req.start_handle, req.end_handle, req.uuid, response_buf),
                .find_information_request => |req| self.handleFindInformation(req.start_handle, req.end_handle, response_buf),
                .handle_value_confirmation => null,
                else => att.encodeErrorResponse(
                    response_buf,
                    @enumFromInt(pdu_data[0]),
                    0x0000,
                    .request_not_supported,
                ),
            };
        }

        // ================================================================
        // Internal: dispatch to handlers
        // ================================================================

        fn dispatchRead(self: *Self, conn_handle: u16, attr_handle: u16, buf: *[att.MAX_PDU_LEN]u8) ?[]const u8 {
            // Find attr by handle
            inline for (db) |a| {
                if (a.handle == attr_handle) {
                    if (a.char_index >= 0) {
                        const idx: usize = @intCast(a.char_index);
                        if (self.handlers[idx]) |binding| {
                            return self.callHandler(binding, conn_handle, attr_handle, .read, &.{}, buf);
                        }
                        return att.encodeReadResponse(buf, &.{});
                    } else {
                        return att.encodeReadResponse(buf, a.static_value[0..a.static_value_len]);
                    }
                }
            }
            return att.encodeErrorResponse(buf, .read_request, attr_handle, .attribute_not_found);
        }

        fn dispatchWrite(self: *Self, conn_handle: u16, attr_handle: u16, value: []const u8, is_command: bool, buf: *[att.MAX_PDU_LEN]u8) ?[]const u8 {
            inline for (db) |a| {
                if (a.handle == attr_handle) {
                    // Check if this is a CCCD attribute
                    if (a.att_type.eql(att.UUID.from16(att.GATT_CLIENT_CHAR_CONFIG_UUID))) {
                        return self.handleCccdWrite(a.service_index, attr_handle, value, is_command, buf);
                    }

                    if (a.char_index >= 0) {
                        const idx: usize = @intCast(a.char_index);
                        if (self.handlers[idx]) |binding| {
                            const op: Operation = if (is_command) .write_command else .write;
                            return self.callHandler(binding, conn_handle, attr_handle, op, value, buf);
                        }
                    }
                    if (!is_command) return att.encodeWriteResponse(buf);
                    return null;
                }
            }
            if (!is_command) {
                return att.encodeErrorResponse(buf, .write_request, attr_handle, .attribute_not_found);
            }
            return null;
        }

        fn handleCccdWrite(self: *Self, service_index: u16, attr_handle: u16, value: []const u8, is_command: bool, buf: *[att.MAX_PDU_LEN]u8) ?[]const u8 {
            if (value.len >= 2) {
                const cccd_val = std.mem.readInt(u16, value[0..2], .little);

                // Find which characteristic this CCCD belongs to.
                // CCCD follows its characteristic value in the attr table.
                // Walk backwards to find the preceding char value attr.
                inline for (db) |a| {
                    // CCCD handle is always char_value_handle + 1
                    if (a.char_index >= 0 and a.handle == attr_handle - 1) {
                        const idx: usize = @intCast(a.char_index);
                        self.cccd_state[idx] = cccd_val;
                    }
                }
                _ = service_index;
            }
            if (!is_command) return att.encodeWriteResponse(buf);
            return null;
        }

        /// Dispatch handler: async (via WaitGroup.go) if enabled, sync otherwise.
        /// Returns response slice in sync mode, null in async mode (response
        /// sent via response_fn callback from the spawned task).
        fn callHandler(
            self: *Self,
            binding: HandlerBinding,
            conn_handle: u16,
            attr_handle: u16,
            op: Operation,
            data: []const u8,
            buf: *[att.MAX_PDU_LEN]u8,
        ) ?[]const u8 {
            // Async path: spawn handler in independent task via WaitGroup.go()
            if (self.wg != null and self.async_allocator != null and self.response_fn != null) {
                const ctx = self.async_allocator.?.create(HandlerTaskCtx) catch {
                    // Allocation failed — fall back to sync
                    return self.callHandlerSync(binding, conn_handle, attr_handle, op, data, buf);
                };

                const copy_len = @min(data.len, att.MAX_PDU_LEN);
                ctx.* = .{
                    .server = self,
                    .binding = binding,
                    .conn_handle = conn_handle,
                    .attr_handle = attr_handle,
                    .op = op,
                    .data_buf = undefined,
                    .data_len = copy_len,
                };
                if (copy_len > 0) {
                    @memcpy(ctx.data_buf[0..copy_len], data[0..copy_len]);
                }

                self.wg.?.go(handlerTaskEntry, .{ctx}) catch {
                    // Spawn failed — free context and fall back to sync
                    self.async_allocator.?.destroy(ctx);
                    return self.callHandlerSync(binding, conn_handle, attr_handle, op, data, buf);
                };

                return null; // Response will be sent via response_fn from the task
            }

            // Sync path: call handler directly (tests / no async configured)
            return self.callHandlerSync(binding, conn_handle, attr_handle, op, data, buf);
        }

        /// Synchronous handler invocation. Used directly in sync mode and as
        /// fallback when async spawn fails.
        fn callHandlerSync(
            self: *Self,
            binding: HandlerBinding,
            conn_handle: u16,
            attr_handle: u16,
            op: Operation,
            data: []const u8,
            buf: *[att.MAX_PDU_LEN]u8,
        ) []const u8 {
            _ = self;

            var response_len: usize = 0;
            var req = Request{
                .op = op,
                .conn_handle = conn_handle,
                .attr_handle = attr_handle,
                .service_uuid = att.UUID.from16(0),
                .char_uuid = att.UUID.from16(0),
                .data = data,
                .user_ctx = binding.ctx,
            };

            var writer = ResponseWriter{
                .buf = buf,
                .len = &response_len,
                .req_opcode = switch (op) {
                    .read => .read_request,
                    .write => .write_request,
                    .write_command => .write_command,
                },
                .attr_handle = attr_handle,
            };

            binding.func(&req, &writer);

            if (writer.has_response and response_len > 0) {
                return buf[0..response_len];
            }

            return switch (op) {
                .read => att.encodeReadResponse(buf, &.{}),
                .write => att.encodeWriteResponse(buf),
                .write_command => &.{},
            };
        }

        // ================================================================
        // Async handler task
        // ================================================================

        /// Heap-allocated context for an async handler task.
        /// Freed by the task after completion.
        const HandlerTaskCtx = struct {
            server: *Self,
            binding: HandlerBinding,
            conn_handle: u16,
            attr_handle: u16,
            op: Operation,
            data_buf: [att.MAX_PDU_LEN]u8,
            data_len: usize,
        };

        fn handlerTaskEntry(ctx: *HandlerTaskCtx) void {
            const server = ctx.server;
            const allocator = server.async_allocator.?;

            // Build request from captured context
            var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
            var resp_len: usize = 0;

            var req = Request{
                .op = ctx.op,
                .conn_handle = ctx.conn_handle,
                .attr_handle = ctx.attr_handle,
                .service_uuid = att.UUID.from16(0),
                .char_uuid = att.UUID.from16(0),
                .data = ctx.data_buf[0..ctx.data_len],
                .user_ctx = ctx.binding.ctx,
            };

            var writer = ResponseWriter{
                .buf = &resp_buf,
                .len = &resp_len,
                .req_opcode = switch (ctx.op) {
                    .read => .read_request,
                    .write => .write_request,
                    .write_command => .write_command,
                },
                .attr_handle = ctx.attr_handle,
            };

            // Call user handler (may block, allocate, do I/O)
            ctx.binding.func(&req, &writer);

            // Capture values before freeing ctx
            const conn_handle = ctx.conn_handle;
            const op = ctx.op;
            const send_fn = server.response_fn.?;
            const send_ctx = server.response_ctx;

            // Free the task context
            allocator.destroy(ctx);

            // write_command: no response per ATT spec (Core Spec Vol 3 Part F 3.4.5.3)
            if (op == .write_command) return;

            // Send response back via callback
            if (writer.has_response and resp_len > 0) {
                send_fn(send_ctx, conn_handle, resp_buf[0..resp_len]);
            } else {
                // Default response if handler didn't write one
                switch (op) {
                    .read => {
                        const default_resp = att.encodeReadResponse(&resp_buf, &.{});
                        send_fn(send_ctx, conn_handle, default_resp);
                    },
                    .write => {
                        const default_resp = att.encodeWriteResponse(&resp_buf);
                        send_fn(send_ctx, conn_handle, default_resp);
                    },
                    .write_command => unreachable, // handled above
                }
            }
        }

        // ================================================================
        // Internal: service discovery responses
        // ================================================================

        fn handleReadByGroupType(self: *Self, start_handle: u16, end_handle: u16, uuid: att.UUID, buf: *[att.MAX_PDU_LEN]u8) []const u8 {
            if (!uuid.eql(att.UUID.from16(att.GATT_PRIMARY_SERVICE_UUID))) {
                return att.encodeErrorResponse(buf, .read_by_group_type_request, start_handle, .unsupported_group_type);
            }

            buf[0] = @intFromEnum(att.Opcode.read_by_group_type_response);
            var pos: usize = 2;
            var entry_len: u8 = 0;
            var found = false;

            inline for (svc_ranges, 0..) |range, svc_idx| {
                if (range[0] >= start_handle and range[0] <= end_handle) {
                    const svc = services[svc_idx];
                    const uuid_len: u8 = @intCast(svc.uuid.byteLen());
                    const this_entry_len = 4 + uuid_len;

                    if (!found) {
                        entry_len = this_entry_len;
                        found = true;
                    } else if (this_entry_len != entry_len) {
                        // Mixed UUID sizes — stop here
                    } else if (pos + this_entry_len <= self.mtu) {
                        std.mem.writeInt(u16, buf[pos..][0..2], range[0], .little);
                        std.mem.writeInt(u16, buf[pos + 2 ..][0..2], range[1], .little);
                        _ = svc.uuid.writeTo(buf[pos + 4 ..]);
                        pos += this_entry_len;
                    }

                    if (found and pos == 2) {
                        // First entry
                        std.mem.writeInt(u16, buf[pos..][0..2], range[0], .little);
                        std.mem.writeInt(u16, buf[pos + 2 ..][0..2], range[1], .little);
                        _ = svc.uuid.writeTo(buf[pos + 4 ..]);
                        pos += this_entry_len;
                    }
                }
            }

            if (!found) {
                return att.encodeErrorResponse(buf, .read_by_group_type_request, start_handle, .attribute_not_found);
            }

            buf[1] = entry_len;
            return buf[0..pos];
        }

        fn handleReadByType(self: *Self, start_handle: u16, end_handle: u16, uuid: att.UUID, buf: *[att.MAX_PDU_LEN]u8) []const u8 {
            buf[0] = @intFromEnum(att.Opcode.read_by_type_response);
            var pos: usize = 2;
            var entry_len: u8 = 0;
            var found = false;

            inline for (db) |a| {
                if (a.handle >= start_handle and a.handle <= end_handle and a.att_type.eql(uuid)) {
                    const val_len: u8 = @intCast(@min(a.static_value_len, self.mtu - 4));
                    if (a.static_value_len > 0) {
                        const this_entry_len = 2 + val_len;

                        if (!found) {
                            entry_len = this_entry_len;
                            found = true;
                        } else if (this_entry_len != entry_len) {
                            // Stop
                        } else if (pos + this_entry_len > self.mtu) {
                            // Stop
                        }

                        if (found and pos + entry_len <= self.mtu) {
                            std.mem.writeInt(u16, buf[pos..][0..2], a.handle, .little);
                            @memcpy(buf[pos + 2 ..][0..val_len], a.static_value[0..val_len]);
                            pos += entry_len;
                        }
                    }
                }
            }

            if (!found) {
                return att.encodeErrorResponse(buf, .read_by_type_request, start_handle, .attribute_not_found);
            }

            buf[1] = entry_len;
            return buf[0..pos];
        }

        fn handleFindInformation(self: *Self, start_handle: u16, end_handle: u16, buf: *[att.MAX_PDU_LEN]u8) []const u8 {
            buf[0] = @intFromEnum(att.Opcode.find_information_response);
            var pos: usize = 2;
            var format: u8 = 0;
            var found = false;

            inline for (db) |a| {
                if (a.handle >= start_handle and a.handle <= end_handle) {
                    const uuid_len = a.att_type.byteLen();
                    const this_format: u8 = if (uuid_len == 2) 1 else 2;
                    const entry_len = 2 + uuid_len;

                    if (!found) {
                        format = this_format;
                        found = true;
                    } else if (this_format != format) {
                        // Mixed
                    }

                    if (found and this_format == format and pos + entry_len <= self.mtu) {
                        std.mem.writeInt(u16, buf[pos..][0..2], a.handle, .little);
                        _ = a.att_type.writeTo(buf[pos + 2 ..]);
                        pos += entry_len;
                    }
                }
            }

            if (!found) {
                return att.encodeErrorResponse(buf, .find_information_request, start_handle, .attribute_not_found);
            }

            buf[1] = format;
            return buf[0..pos];
        }

        // ================================================================
        // Comptime helpers
        // ================================================================

        fn findCharIndex(comptime svc_uuid16: u16, comptime char_uuid16: u16) usize {
            comptime {
                var idx: usize = 0;
                for (services) |svc| {
                    for (svc.chars) |chr| {
                        switch (svc.uuid) {
                            .uuid16 => |su| {
                                if (su == svc_uuid16) {
                                    switch (chr.uuid) {
                                        .uuid16 => |cu| {
                                            if (cu == char_uuid16) return idx;
                                        },
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                        idx += 1;
                    }
                }
                @compileError("characteristic not found: check service/char UUIDs");
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestRt = @import("std_impl").runtime;
const WaitGroupT = waitgroup.WaitGroup(TestRt);

test "GattServer comptime service table" {
    const MyServer = GattServer(TestRt, &.{
        Service(0x180D, &.{
            Char(0x2A37, .{ .read = true, .notify = true }),
            Char(0x2A38, .{ .read = true }),
        }),
        Service(0xFFE0, &.{
            Char(0xFFE1, .{ .write = true, .notify = true }),
        }),
    });

    try std.testing.expectEqual(@as(usize, 3), MyServer.char_count);
    // Service decls(2) + char decls(3) + values(3) + CCCDs(2 for notify chars) = 10
    try std.testing.expectEqual(@as(usize, 10), MyServer.attr_count);
}

test "GattServer handle registration and read dispatch" {
    const MyServer = GattServer(TestRt, &.{
        Service(0x180D, &.{
            Char(0x2A37, .{ .read = true }),
        }),
    });

    var server = MyServer.init();

    // Register handler
    server.handle(0x180D, 0x2A37, struct {
        pub fn serve(req: *Request, w: *ResponseWriter) void {
            _ = req;
            w.write(&[_]u8{ 0x00, 72 });
        }
    }.serve, null);

    // Get value handle (comptime)
    const value_handle = MyServer.getValueHandle(0x180D, 0x2A37);

    // Build Read Request PDU
    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.read_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.read_response)), resp[0]);
    try std.testing.expectEqual(@as(u8, 0x00), resp[1]);
    try std.testing.expectEqual(@as(u8, 72), resp[2]);
}

test "GattServer write dispatch with handler" {
    const MyServer = GattServer(TestRt, &.{
        Service(0xFFE0, &.{
            Char(0xFFE1, .{ .write = true }),
        }),
    });

    var server = MyServer.init();

    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Request, w: *ResponseWriter) void {
            if (req.op == .write) {
                w.ok();
            }
        }
    }.serve, null);

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    var req_buf: [5]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.write_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);
    req_buf[3] = 0xAA;
    req_buf[4] = 0xBB;

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.write_response)), resp[0]);
}

test "GattServer MTU exchange" {
    const MyServer = GattServer(TestRt, &.{
        Service(0x180D, &.{
            Char(0x2A37, .{ .read = true }),
        }),
    });

    var server = MyServer.init();

    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.exchange_mtu_request);
    std.mem.writeInt(u16, req_buf[1..3], 512, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.exchange_mtu_response)), resp[0]);
    try std.testing.expectEqual(@as(u16, 512), server.mtu);
}

test "GattServer service discovery" {
    const MyServer = GattServer(TestRt, &.{
        Service(0x180D, &.{
            Char(0x2A37, .{ .read = true }),
        }),
        Service(0xFFE0, &.{
            Char(0xFFE1, .{ .write = true }),
        }),
    });

    var server = MyServer.init();

    // Read By Group Type (discover primary services)
    var req_buf: [7]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.read_by_group_type_request);
    std.mem.writeInt(u16, req_buf[1..3], 0x0001, .little);
    std.mem.writeInt(u16, req_buf[3..5], 0xFFFF, .little);
    std.mem.writeInt(u16, req_buf[5..7], att.GATT_PRIMARY_SERVICE_UUID, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const resp = server.handlePdu(0x0040, &req_buf, &resp_buf) orelse unreachable;

    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.read_by_group_type_response)), resp[0]);
    try std.testing.expectEqual(@as(u8, 6), resp[1]); // entry len: 2+2+2=6
    try std.testing.expect(resp.len >= 8); // at least one entry
}

test "GattServer async handler dispatch - concurrent requests" {
    // Verify that handler tasks run concurrently and don't block each other.
    // Uses a handler that sleeps briefly to simulate I/O, and checks that
    // multiple requests are dispatched without waiting for each to finish.

    const MyServer = GattServer(TestRt, &.{
        Service(0xFFE0, &.{
            Char(0xFFE1, .{ .read = true, .write = true }),
        }),
    });

    var server = MyServer.init();

    // Shared counter: each handler increments it atomically
    const Counter = struct {
        value: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };

    var counter = Counter{};

    // Handler: sleep 10ms then increment counter
    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Request, w: *ResponseWriter) void {
            const ctr: *Counter = @ptrCast(@alignCast(req.user_ctx));

            // Simulate blocking I/O (10ms)
            std.Thread.sleep(10 * std.time.ns_per_ms);

            _ = ctr.value.fetchAdd(1, .monotonic);
            w.write(&[_]u8{0x42});
        }
    }.serve, @ptrCast(&counter));

    // Track responses received via the callback
    const ResponseTracker = struct {
        count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
    };
    var tracker = ResponseTracker{};

    const trackingResponseFn = struct {
        fn send(ctx: ?*anyopaque, conn_handle: u16, data: []const u8) void {
            _ = conn_handle;
            _ = data;
            const t: *ResponseTracker = @ptrCast(@alignCast(ctx));
            _ = t.count.fetchAdd(1, .monotonic);
            t.mutex.lock();
            defer t.mutex.unlock();
            t.cond.signal();
        }
    }.send;

    // Enable async dispatch
    var wg = WaitGroupT.init();
    defer wg.deinit();

    server.enableAsync(&wg, std.testing.allocator, trackingResponseFn, @ptrCast(&tracker));

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    // Fire N concurrent read requests
    const N = 4;
    for (0..N) |_| {
        var req_buf: [3]u8 = undefined;
        req_buf[0] = @intFromEnum(att.Opcode.read_request);
        std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);

        var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
        const result = server.handlePdu(0x0040, &req_buf, &resp_buf);

        // Async dispatch: handlePdu returns null (response via callback)
        try std.testing.expectEqual(@as(?[]const u8, null), result);
    }

    // Wait for all handler tasks to complete
    wg.wait();

    // All handlers should have run
    try std.testing.expectEqual(@as(u32, N), counter.value.load(.monotonic));

    // All responses should have been sent via callback
    try std.testing.expectEqual(@as(u32, N), tracker.count.load(.monotonic));
}

test "GattServer async handler fallback on sync mode" {
    // Without enableAsync(), callHandler should return data synchronously.
    const MyServer = GattServer(TestRt, &.{
        Service(0xFFE0, &.{
            Char(0xFFE1, .{ .read = true }),
        }),
    });

    var server = MyServer.init();

    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Request, w: *ResponseWriter) void {
            _ = req;
            w.write(&[_]u8{ 0xDE, 0xAD });
        }
    }.serve, null);

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    var req_buf: [3]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.read_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const result = server.handlePdu(0x0040, &req_buf, &resp_buf);

    // Sync mode: should return response directly
    try std.testing.expect(result != null);
    const resp = result.?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(att.Opcode.read_response)), resp[0]);
    try std.testing.expectEqual(@as(u8, 0xDE), resp[1]);
    try std.testing.expectEqual(@as(u8, 0xAD), resp[2]);
}

test "GattServer async write handler receives data" {
    // Verify that write data is correctly copied to the async task context.
    const MyServer = GattServer(TestRt, &.{
        Service(0xFFE0, &.{
            Char(0xFFE1, .{ .write = true }),
        }),
    });

    var server = MyServer.init();

    // Capture written data via user_ctx
    const Capture = struct {
        data: [4]u8 = undefined,
        len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };
    var capture = Capture{};

    server.handle(0xFFE0, 0xFFE1, struct {
        pub fn serve(req: *Request, w: *ResponseWriter) void {
            const cap: *Capture = @ptrCast(@alignCast(req.user_ctx));
            @memcpy(cap.data[0..req.data.len], req.data);
            _ = cap.len.fetchAdd(@intCast(req.data.len), .monotonic);
            w.ok();
        }
    }.serve, @ptrCast(&capture));

    const ResponseSink = struct {
        fn send(_: ?*anyopaque, _: u16, _: []const u8) void {}
    };

    var wg = WaitGroupT.init();
    defer wg.deinit();

    server.enableAsync(&wg, std.testing.allocator, ResponseSink.send, null);

    const value_handle = MyServer.getValueHandle(0xFFE0, 0xFFE1);

    // Send write request with payload [0xCA, 0xFE]
    var req_buf: [5]u8 = undefined;
    req_buf[0] = @intFromEnum(att.Opcode.write_request);
    std.mem.writeInt(u16, req_buf[1..3], value_handle, .little);
    req_buf[3] = 0xCA;
    req_buf[4] = 0xFE;

    var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
    const result = server.handlePdu(0x0040, &req_buf, &resp_buf);
    try std.testing.expectEqual(@as(?[]const u8, null), result);

    wg.wait();

    // Verify the handler received the correct data
    try std.testing.expectEqual(@as(u32, 2), capture.len.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 0xCA), capture.data[0]);
    try std.testing.expectEqual(@as(u8, 0xFE), capture.data[1]);
}
