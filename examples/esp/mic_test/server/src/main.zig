//! Mic Test Server
//!
//! Receives audio data from ESP device via TCP and plays it through speakers.
//! Also can generate test tones for verification.
//!
//! Usage:
//!   zig build run              # Start server on default port 9000
//!   zig build run -- -p 9001   # Custom port
//!   zig build run -- --tone    # Generate test tone (for speaker test)

const std = @import("std");
const net = std.net;
const posix = std.posix;

// ============================================================================
// PortAudio C bindings
// ============================================================================

const c = @cImport({
    @cInclude("portaudio.h");
});

const PaError = c.PaError;
const PaStream = c.PaStream;

// ============================================================================
// Configuration
// ============================================================================

const Config = struct {
    port: u16 = 9000,
    sample_rate: u32 = 16000,
    channels: u8 = 1,
    frames_per_buffer: u32 = 256,
    generate_tone: bool = false,
    tone_freq: f32 = 440.0,
};

// ============================================================================
// Audio Ring Buffer (lock-free single producer single consumer)
// ============================================================================

const RingBuffer = struct {
    const BUFFER_SIZE = 16000 * 2; // 2 seconds of audio at 16kHz

    buffer: [BUFFER_SIZE]i16 = [_]i16{0} ** BUFFER_SIZE,
    write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    read_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn write(self: *RingBuffer, data: []const i16) usize {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.acquire);

        // Calculate available space
        const space = if (w >= r) BUFFER_SIZE - (w - r) - 1 else r - w - 1;
        const to_write = @min(data.len, space);

        for (0..to_write) |i| {
            self.buffer[(w + i) % BUFFER_SIZE] = data[i];
        }

        self.write_pos.store((w + to_write) % BUFFER_SIZE, .release);
        return to_write;
    }

    fn read(self: *RingBuffer, out: []i16) usize {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.acquire);

        // Calculate available data
        const avail = if (w >= r) w - r else BUFFER_SIZE - r + w;
        const to_read = @min(out.len, avail);

        for (0..to_read) |i| {
            out[i] = self.buffer[(r + i) % BUFFER_SIZE];
        }

        self.read_pos.store((r + to_read) % BUFFER_SIZE, .release);
        return to_read;
    }

    fn available(self: *RingBuffer) usize {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.acquire);
        return if (w >= r) w - r else BUFFER_SIZE - r + w;
    }
};

// ============================================================================
// Global State
// ============================================================================

var ring_buffer: RingBuffer = .{};
var config: Config = .{};
var stats: struct {
    bytes_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    samples_played: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    underruns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
} = .{};

// Tone generator state
var tone_phase: f32 = 0.0;

// ============================================================================
// PortAudio Callback
// ============================================================================

fn audioCallback(
    _: ?*const anyopaque,
    output_buffer: ?*anyopaque,
    frame_count: c_ulong,
    _: [*c]const c.PaStreamCallbackTimeInfo,
    _: c_ulong,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const out: [*]i16 = @ptrCast(@alignCast(output_buffer));
    const frames: usize = @intCast(frame_count);

    if (config.generate_tone) {
        // Generate sine wave test tone
        const phase_inc = 2.0 * std.math.pi * config.tone_freq / @as(f32, @floatFromInt(config.sample_rate));
        for (0..frames) |i| {
            out[i] = @intFromFloat(@sin(tone_phase) * 16000.0);
            tone_phase += phase_inc;
            if (tone_phase > 2.0 * std.math.pi) tone_phase -= 2.0 * std.math.pi;
        }
    } else {
        // Play from ring buffer
        var temp: [1024]i16 = undefined;
        const to_read = @min(frames, temp.len);
        const got = ring_buffer.read(temp[0..to_read]);

        for (0..got) |i| {
            out[i] = temp[i];
        }
        // Fill rest with silence if underrun
        for (got..frames) |i| {
            out[i] = 0;
        }

        if (got < frames and ring_buffer.available() == 0) {
            _ = stats.underruns.fetchAdd(1, .monotonic);
        }

        _ = stats.samples_played.fetchAdd(got, .monotonic);
    }

    return c.paContinue;
}

// ============================================================================
// TCP Server
// ============================================================================

fn handleClient(connection: net.Server.Connection) void {
    const conn = connection.stream;
    defer conn.close();

    const addr = connection.address;
    std.debug.print("[CONNECT] Client connected: {any}\n", .{addr});

    // Audio packet format:
    // - 4 bytes: packet length (little endian)
    // - N bytes: i16 samples (little endian)

    var header_buf: [4]u8 = undefined;

    while (true) {
        // Read packet header
        const header_read = conn.read(&header_buf) catch |err| {
            std.debug.print("[DISCONNECT] Read error: {}\n", .{err});
            break;
        };

        if (header_read == 0) {
            std.debug.print("[DISCONNECT] Client closed connection\n", .{});
            break;
        }

        if (header_read != 4) {
            std.debug.print("[ERROR] Incomplete header: {} bytes\n", .{header_read});
            continue;
        }

        const packet_len = std.mem.readInt(u32, &header_buf, .little);

        if (packet_len > 8192) {
            std.debug.print("[ERROR] Packet too large: {} bytes\n", .{packet_len});
            continue;
        }

        // Validate packet_len is even (i16 samples require 2 bytes each)
        if (packet_len % 2 != 0) {
            std.debug.print("[ERROR] Invalid packet length (must be even): {} bytes\n", .{packet_len});
            continue;
        }

        // Read audio data (aligned for i16 access)
        var audio_buf: [8192]u8 align(@alignOf(i16)) = undefined;
        var total_read: usize = 0;

        while (total_read < packet_len) {
            const n = conn.read(audio_buf[total_read..packet_len]) catch |err| {
                std.debug.print("[ERROR] Read audio error: {}\n", .{err});
                break;
            };
            if (n == 0) break;
            total_read += n;
        }

        if (total_read != packet_len) {
            std.debug.print("[ERROR] Incomplete packet: {}/{} bytes\n", .{ total_read, packet_len });
            continue;
        }

        // Convert bytes to samples and write to ring buffer
        const samples: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, audio_buf[0..packet_len]));
        const written = ring_buffer.write(samples);

        _ = stats.bytes_received.fetchAdd(packet_len, .monotonic);

        if (written < samples.len) {
            std.debug.print("[WARN] Ring buffer overflow, dropped {} samples\n", .{samples.len - written});
        }
    }

    std.debug.print("[DISCONNECT] Client disconnected: {any}\n", .{addr});
}

fn runServer(address: net.Address) !void {
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("\n===========================================\n", .{});
    std.debug.print("Mic Test Server\n", .{});
    std.debug.print("===========================================\n", .{});
    std.debug.print("Listening on port {}\n", .{config.port});
    std.debug.print("Sample rate: {} Hz\n", .{config.sample_rate});
    std.debug.print("Channels: {}\n", .{config.channels});
    if (config.generate_tone) {
        std.debug.print("Mode: Test tone ({} Hz)\n", .{config.tone_freq});
    } else {
        std.debug.print("Mode: Receive and play\n", .{});
    }
    std.debug.print("===========================================\n\n", .{});

    // Note: This is a test/debug tool, not a production server.
    // For production use, consider implementing a thread pool or connection limit.
    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("[ERROR] Accept failed: {}\n", .{err});
            continue;
        };

        // Handle client in separate thread
        _ = std.Thread.spawn(.{}, handleClient, .{conn}) catch |err| {
            std.debug.print("[ERROR] Thread spawn failed: {}\n", .{err});
            conn.stream.close();
        };
    }
}

// ============================================================================
// Stats Printer
// ============================================================================

fn printStats() void {
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);

        const received = stats.bytes_received.load(.monotonic);
        const played = stats.samples_played.load(.monotonic);
        const underruns = stats.underruns.load(.monotonic);
        const buffered = ring_buffer.available();

        std.debug.print("[STATS] Received: {} KB, Played: {} samples, Buffer: {}, Underruns: {}\n", .{
            received / 1024,
            played,
            buffered,
            underruns,
        });
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    // Parse args
    var args = std.process.args();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                config.port = std.fmt.parseInt(u16, port_str, 10) catch 9000;
            }
        } else if (std.mem.eql(u8, arg, "--tone")) {
            config.generate_tone = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--rate")) {
            if (args.next()) |rate_str| {
                config.sample_rate = std.fmt.parseInt(u32, rate_str, 10) catch 16000;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\Mic Test Server
                \\
                \\Usage: mic_server [options]
                \\
                \\Options:
                \\  -p, --port <port>   TCP port (default: 9000)
                \\  -r, --rate <hz>     Sample rate (default: 16000)
                \\  --tone              Generate test tone instead of receiving
                \\  -h, --help          Show this help
                \\
            , .{});
            return;
        }
    }

    // Initialize PortAudio
    var err = c.Pa_Initialize();
    if (err != c.paNoError) {
        std.debug.print("PortAudio init failed: {s}\n", .{c.Pa_GetErrorText(err)});
        return error.PortAudioInitFailed;
    }
    defer _ = c.Pa_Terminate();

    // Open audio stream
    var stream: ?*PaStream = null;
    err = c.Pa_OpenDefaultStream(
        &stream,
        0, // no input
        @intCast(config.channels), // output channels
        c.paInt16, // sample format
        @floatFromInt(config.sample_rate),
        @intCast(config.frames_per_buffer),
        audioCallback,
        null,
    );

    if (err != c.paNoError) {
        std.debug.print("Failed to open audio stream: {s}\n", .{c.Pa_GetErrorText(err)});
        return error.OpenStreamFailed;
    }
    defer _ = c.Pa_CloseStream(stream);

    // Start audio stream
    err = c.Pa_StartStream(stream);
    if (err != c.paNoError) {
        std.debug.print("Failed to start stream: {s}\n", .{c.Pa_GetErrorText(err)});
        return error.StartStreamFailed;
    }
    defer _ = c.Pa_StopStream(stream);

    // Start stats printer thread
    _ = std.Thread.spawn(.{}, printStats, .{}) catch {};

    // Run TCP server
    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, config.port);
    try runServer(address);
}
