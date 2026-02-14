//! WebSim Flash Server
//!
//! TCP server that receives firmware uploads.
//!
//! Protocol v2 (FLASH2):
//!   Client -> "FLASH2\n"
//!   Client -> <config_json_size>\n
//!   Client -> <config_json_bytes>
//!   Client -> <wasm_size>\n
//!   Client -> <wasm_bytes>
//!   Server -> "OK\n" or "ERROR: <msg>\n"
//!
//! Protocol v1 (FLASH, backward compatible):
//!   Client -> "FLASH\n"
//!   Client -> <wasm_size>\n
//!   Client -> <wasm_bytes>
//!   Server -> "OK\n"

const std = @import("std");
const net = std.net;

pub const FirmwareBundle = struct {
    config_json: []const u8, // Board config JSON (empty for v1)
    wasm_data: []const u8, // WASM binary
};

pub const FlashServer = struct {
    listener: net.Server,
    port: u16,
    thread: ?std.Thread = null,
    running: bool = true,

    on_firmware: ?*const fn (bundle: FirmwareBundle) void = null,

    pub fn init(port: u16, on_firmware: *const fn (FirmwareBundle) void) !FlashServer {
        const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const server = try addr.listen(.{ .reuse_address = true });
        const bound_port = server.listen_address.getPort();

        std.debug.print("[Flash] Listening on tcp://127.0.0.1:{}\n", .{bound_port});

        return FlashServer{
            .listener = server,
            .port = bound_port,
            .on_firmware = on_firmware,
        };
    }

    pub fn startThread(self: *FlashServer) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *FlashServer) void {
        self.running = false;
        self.listener.deinit();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn acceptLoop(self: *FlashServer) void {
        while (self.running) {
            const conn = self.listener.accept() catch {
                if (!self.running) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            self.handleClient(conn.stream) catch |err| {
                std.debug.print("[Flash] Client error: {}\n", .{err});
            };
            conn.stream.close();
        }
    }

    fn handleClient(self: *FlashServer, stream: net.Stream) !void {
        // Read all data (nc sends everything at once then closes)
        const max_size = 16 * 1024 * 1024 + 4096;
        const all_data = std.heap.c_allocator.alloc(u8, max_size) catch return;
        defer std.heap.c_allocator.free(all_data);
        var total: usize = 0;

        while (total < max_size) {
            const n = stream.read(all_data[total..]) catch break;
            if (n == 0) break;
            total += n;
        }

        if (total == 0) return;

        const data = all_data[0..total];
        std.debug.print("[Flash] Received {} bytes total\n", .{total});

        // Parse first line (command)
        const first_nl = std.mem.indexOf(u8, data, "\n") orelse {
            _ = try stream.write("ERROR: no newline in command\n");
            return;
        };
        const cmd = std.mem.trimRight(u8, data[0..first_nl], "\r \t");
        const rest = data[first_nl + 1 ..];

        if (std.mem.eql(u8, cmd, "FLASH2")) {
            try self.handleFlash2FromBuf(stream, rest);
        } else if (std.mem.eql(u8, cmd, "FLASH")) {
            try self.handleFlash1FromBuf(stream, rest);
        } else {
            std.debug.print("[Flash] Unknown command: '{s}'\n", .{cmd});
            _ = try stream.write("ERROR: unknown command. Use FLASH or FLASH2.\n");
        }
    }

    /// FLASH2 from pre-read buffer
    fn handleFlash2FromBuf(self: *FlashServer, stream: net.Stream, data: []const u8) !void {
        var rest = data;

        // Parse config size line
        const cfg_nl = std.mem.indexOf(u8, rest, "\n") orelse return error.MissingNewline;
        const cfg_size = std.fmt.parseInt(u32, std.mem.trimRight(u8, rest[0..cfg_nl], "\r \t"), 10) catch return error.InvalidSize;
        rest = rest[cfg_nl + 1 ..];

        if (cfg_size > rest.len) return error.InsufficientData;
        const config_json = rest[0..cfg_size];
        rest = rest[cfg_size..];

        // Parse WASM size line
        const wasm_nl = std.mem.indexOf(u8, rest, "\n") orelse return error.MissingNewline;
        const wasm_size = std.fmt.parseInt(u32, std.mem.trimRight(u8, rest[0..wasm_nl], "\r \t"), 10) catch return error.InvalidSize;
        rest = rest[wasm_nl + 1 ..];

        if (wasm_size > rest.len) {
            std.debug.print("[Flash] WASM size mismatch: expected {} got {}\n", .{ wasm_size, rest.len });
            return error.InsufficientData;
        }
        const wasm_data = rest[0..wasm_size];

        // Validate WASM magic
        if (wasm_data.len < 4 or wasm_data[0] != 0x00 or wasm_data[1] != 0x61 or
            wasm_data[2] != 0x73 or wasm_data[3] != 0x6d)
        {
            _ = try stream.write("ERROR: invalid WASM magic\n");
            return;
        }

        std.debug.print("[Flash] FLASH2 OK: config={} wasm={}\n", .{ cfg_size, wasm_size });

        if (self.on_firmware) |cb| {
            cb(.{ .config_json = config_json, .wasm_data = wasm_data });
        }

        _ = try stream.write("OK\n");
    }

    /// FLASH v1 from pre-read buffer
    fn handleFlash1FromBuf(self: *FlashServer, stream: net.Stream, data: []const u8) !void {
        var rest = data;
        const size_nl = std.mem.indexOf(u8, rest, "\n") orelse return error.MissingNewline;
        const wasm_size = std.fmt.parseInt(u32, std.mem.trimRight(u8, rest[0..size_nl], "\r \t"), 10) catch return error.InvalidSize;
        rest = rest[size_nl + 1 ..];

        if (wasm_size > rest.len) return error.InsufficientData;
        const wasm_data = rest[0..wasm_size];

        std.debug.print("[Flash] FLASH v1 OK: {} bytes\n", .{wasm_size});

        if (self.on_firmware) |cb| {
            cb(.{ .config_json = "{}", .wasm_data = wasm_data });
        }

        _ = try stream.write("OK\n");
    }

    /// FLASH2: config JSON + WASM (streaming, unused now)
    fn handleFlash2(self: *FlashServer, stream: net.Stream) !void {
        // Read config JSON size
        const config_size = try readSizeLine(stream);
        if (config_size == 0 or config_size > 1024 * 1024) {
            _ = try stream.write("ERROR: invalid config size\n");
            return;
        }

        std.debug.print("[Flash] FLASH2: config={} bytes\n", .{config_size});

        // Read config JSON
        const config_json = try readExact(stream, config_size);
        defer std.heap.c_allocator.free(config_json);

        // Read WASM size
        const wasm_size = try readSizeLine(stream);
        if (wasm_size == 0 or wasm_size > 16 * 1024 * 1024) {
            _ = try stream.write("ERROR: invalid wasm size\n");
            return;
        }

        std.debug.print("[Flash] FLASH2: wasm={} bytes\n", .{wasm_size});

        // Read WASM data
        const wasm_data = try readExact(stream, wasm_size);
        defer std.heap.c_allocator.free(wasm_data);

        // Validate WASM magic
        if (wasm_data.len < 4 or wasm_data[0] != 0x00 or wasm_data[1] != 0x61 or
            wasm_data[2] != 0x73 or wasm_data[3] != 0x6d)
        {
            _ = try stream.write("ERROR: invalid WASM magic\n");
            return;
        }

        std.debug.print("[Flash] Firmware received: config={} wasm={} bytes\n", .{ config_size, wasm_size });

        if (self.on_firmware) |cb| {
            cb(.{ .config_json = config_json, .wasm_data = wasm_data });
        }

        _ = try stream.write("OK\n");
    }

    /// FLASH (v1): WASM only, no config
    fn handleFlash1(self: *FlashServer, stream: net.Stream) !void {
        const wasm_size = try readSizeLine(stream);
        if (wasm_size == 0 or wasm_size > 16 * 1024 * 1024) {
            _ = try stream.write("ERROR: invalid size\n");
            return;
        }

        std.debug.print("[Flash] FLASH v1: {} bytes\n", .{wasm_size});

        const wasm_data = try readExact(stream, wasm_size);
        defer std.heap.c_allocator.free(wasm_data);

        if (self.on_firmware) |cb| {
            cb(.{ .config_json = "{}", .wasm_data = wasm_data });
        }

        _ = try stream.write("OK\n");
    }

    fn readSizeLine(stream: net.Stream) !u32 {
        var buf: [32]u8 = undefined;
        const n = try stream.read(&buf);
        if (n == 0) return error.ConnectionClosed;
        const line = std.mem.trimRight(u8, buf[0..n], "\r\n \t");
        return std.fmt.parseInt(u32, line, 10) catch return error.InvalidSize;
    }

    fn readExact(stream: net.Stream, size: u32) ![]u8 {
        const data = try std.heap.c_allocator.alloc(u8, size);
        errdefer std.heap.c_allocator.free(data);

        var total: usize = 0;
        while (total < size) {
            const n = try stream.read(data[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
        return data;
    }
};
