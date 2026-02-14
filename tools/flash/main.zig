//! WebSim Flash Tool
//!
//! Uploads a .wasm firmware file to a running WebSim simulator instance.
//!
//! Usage:
//!   websim-flash --port 9999 --firmware app.wasm
//!   websim-flash --port 9999 --firmware app.wasm --monitor
//!
//! Protocol:
//!   1. Connect to simulator TCP port
//!   2. Send "FLASH\n"
//!   3. Send "<size>\n"
//!   4. Send <wasm_bytes>
//!   5. Read response "OK <size>\n" or "ERROR: <msg>\n"

const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var port: u16 = 9999;
    var firmware_path: ?[]const u8 = null;
    var monitor = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("Error: invalid port number\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, args[i], "--firmware") or std.mem.eql(u8, args[i], "--fw")) {
            i += 1;
            if (i < args.len) firmware_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--monitor")) {
            monitor = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        }
    }

    if (firmware_path == null) {
        std.debug.print("Error: --firmware <path.wasm> is required\n\n", .{});
        printUsage();
        return;
    }

    // Read firmware file
    const fw_path = firmware_path.?;
    std.debug.print("Reading firmware: {s}\n", .{fw_path});

    const wasm_data = std.fs.cwd().readFileAlloc(allocator, fw_path, 16 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ fw_path, err });
        return;
    };
    defer allocator.free(wasm_data);

    // Validate WASM magic
    if (wasm_data.len < 8 or wasm_data[0] != 0x00 or wasm_data[1] != 0x61 or
        wasm_data[2] != 0x73 or wasm_data[3] != 0x6d)
    {
        std.debug.print("Error: {s} is not a valid WASM file\n", .{fw_path});
        return;
    }

    std.debug.print("Firmware: {} bytes (WASM validated)\n", .{wasm_data.len});
    std.debug.print("Connecting to simulator on port {}...\n", .{port});

    // Connect to simulator
    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = net.tcpConnectToAddress(addr) catch |err| {
        std.debug.print("Error: cannot connect to port {}: {}\n", .{ port, err });
        std.debug.print("Is the WebSim simulator running? (bazel run //tools/websim)\n", .{});
        return;
    };
    defer stream.close();

    // Send FLASH command
    try stream.writeAll("FLASH\n");

    // Send size
    var size_buf: [32]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{}\n", .{wasm_data.len});
    try stream.writeAll(size_str);

    // Send WASM data
    try stream.writeAll(wasm_data);

    std.debug.print("Firmware sent. Waiting for response...\n", .{});

    // Read response
    var resp_buf: [256]u8 = undefined;
    const resp_n = try stream.read(&resp_buf);
    if (resp_n > 0) {
        const resp = std.mem.trimRight(u8, resp_buf[0..resp_n], "\r\n");
        if (std.mem.startsWith(u8, resp, "OK")) {
            std.debug.print("Flash successful: {s}\n", .{resp});
        } else {
            std.debug.print("Flash failed: {s}\n", .{resp});
            return;
        }
    }

    if (monitor) {
        std.debug.print("\n--- Monitor mode (Ctrl+C to exit) ---\n\n", .{});
        // TODO: keep connection open, read log output
        while (true) {
            const n = stream.read(&resp_buf) catch break;
            if (n == 0) break;
            std.debug.print("{s}", .{resp_buf[0..n]});
        }
    }
}

fn printUsage() void {
    std.debug.print(
        \\websim-flash — Upload firmware to WebSim simulator
        \\
        \\Usage:
        \\  websim-flash --port <port> --firmware <path.wasm> [--monitor]
        \\
        \\Options:
        \\  --port <port>        Simulator flash port (default: 9999)
        \\  --firmware <path>    Path to .wasm firmware file
        \\  --fw <path>          Alias for --firmware
        \\  --monitor            Keep connection open for log output
        \\  --help               Show this help
        \\
        \\Example:
        \\  bazel run //tools/websim                                    # Start simulator
        \\  bazel run //tools/flash -- --port 9999 --fw app.wasm        # Flash firmware
        \\
    , .{});
}
