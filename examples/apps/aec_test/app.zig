//! AEC Test Example - Platform Independent App
//!
//! Tests AEC (Acoustic Echo Cancellation) functionality.
//! Mode 1: Mic -> Speaker loopback (tests AEC locally)
//! Mode 2: Mic -> TCP stream (sends raw PCM to server for analysis)
//!
//! Hardware: ESP32-S3-Korvo-2 V3 with ES7210 ADC + ES8311 DAC

const std = @import("std");
const hal = @import("hal");
const idf = @import("esp");

const platform = @import("platform.zig");
const Board = platform.Board;
const Hardware = platform.Hardware;
const log = Board.log;

const BUILD_TAG = "aec_test_v3_tcp";

// ============================================================================
// Configuration - CHANGE THESE!
// ============================================================================

// WiFi credentials
const WIFI_SSID = "HAIVIVI-MFG";
const WIFI_PASSWORD = "!haivivi";

// TCP server (your computer running tcp_audio_server.py)
const TCP_SERVER_IP = "192.168.4.221";
const TCP_SERVER_PORT: u16 = 8888;

// Test mode: true = TCP streaming, false = speaker loopback
const USE_TCP_MODE = false; // TCP mode disabled - waiting for WiFi PR

// ============================================================================
// Audio Parameters
// ============================================================================

const SAMPLE_RATE: u32 = Hardware.sample_rate;
const BUFFER_SIZE: usize = 256; // Matches AEC chunk size
const MIC_GAIN: i32 = 16; // Amplification factor for mic audio

fn printBoardInfo() void {
    log.info("==========================================", .{});
    log.info("AEC (Echo Cancellation) Test", .{});
    log.info("Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{Hardware.name});
    log.info("ADC:         ES7210 (4-channel)", .{});
    log.info("DAC:         ES8311 (mono)", .{});
    log.info("Sample Rate: {}Hz", .{SAMPLE_RATE});
    log.info("AEC Format:  MR (Mic+Ref)", .{});
    log.info("==========================================", .{});
    if (USE_TCP_MODE) {
        log.info("Mode: TCP streaming to {s}:{}", .{ TCP_SERVER_IP, TCP_SERVER_PORT });
    } else {
        log.info("Mode: Speaker loopback", .{});
    }
    log.info("==========================================", .{});
}

/// Application entry point
pub fn run(_: anytype) void {
    printBoardInfo();

    // Initialize board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Board initialized", .{});

    if (USE_TCP_MODE) {
        runTcpMode(&board);
    } else {
        runLoopbackMode(&board);
    }
}

/// TCP streaming mode - sends mic audio to server
fn runTcpMode(board: *Board) void {
    log.info("=== TCP Mode ===", .{});

    // Connect to WiFi
    log.info("Connecting to WiFi: {s}...", .{WIFI_SSID});

    var wifi = idf.Wifi.init() catch |err| {
        log.err("WiFi init failed: {}", .{err});
        return;
    };

    wifi.connect(.{
        .ssid = WIFI_SSID,
        .password = WIFI_PASSWORD,
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("WiFi connect failed: {}", .{err});
        return;
    };

    const ip = wifi.getIpAddress();
    log.info("WiFi connected! IP: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });

    // Parse server IP
    const server_ip = idf.net.Socket.parseIpv4(TCP_SERVER_IP) orelse {
        log.err("Invalid server IP: {s}", .{TCP_SERVER_IP});
        return;
    };

    // Connect to TCP server
    log.info("Connecting to TCP server {s}:{}...", .{ TCP_SERVER_IP, TCP_SERVER_PORT });

    var socket = idf.net.Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };
    defer socket.close();

    socket.connect(server_ip, TCP_SERVER_PORT) catch |err| {
        log.err("TCP connect failed: {}", .{err});
        log.err("Make sure tcp_audio_server.py is running on {s}:{}", .{ TCP_SERVER_IP, TCP_SERVER_PORT });
        return;
    };

    log.info("TCP connected! Streaming audio...", .{});
    log.info("Run 'python3 tools/tcp_audio_server.py' on your computer to receive", .{});

    // Audio buffer
    var audio_buffer: [BUFFER_SIZE]i16 = undefined;
    var total_samples: u64 = 0;
    var total_bytes_sent: u64 = 0;

    while (true) {
        // Read from microphone
        const samples_read = board.audio.readMic(&audio_buffer) catch |err| {
            log.err("Mic read error: {}", .{err});
            platform.time.sleepMs(10);
            continue;
        };

        if (samples_read == 0) {
            platform.time.sleepMs(1);
            continue;
        }

        // Send raw PCM data over TCP
        const bytes_to_send = samples_read * @sizeOf(i16);
        const data_ptr: [*]const u8 = @ptrCast(&audio_buffer);

        _ = socket.send(data_ptr[0..bytes_to_send]) catch |err| {
            log.err("TCP send error: {}", .{err});
            break;
        };

        total_samples += samples_read;
        total_bytes_sent += bytes_to_send;

        // Log progress every 5 seconds
        if (total_samples > 0 and total_samples % (SAMPLE_RATE * 5) < BUFFER_SIZE) {
            const seconds = total_samples / SAMPLE_RATE;
            log.info("Streaming... {}s, {} bytes sent", .{ seconds, total_bytes_sent });
        }
    }

    log.info("TCP streaming ended. Total bytes sent: {}", .{total_bytes_sent});
}

/// Speaker loopback mode - tests AEC with mic -> speaker
fn runLoopbackMode(board: *Board) void {
    log.info("=== Loopback Mode (Mic -> Speaker with AEC) ===", .{});

    // Enable PA (Power Amplifier)
    board.pa_switch.on() catch |err| {
        log.err("Failed to enable PA: {}", .{err});
        return;
    };
    defer board.pa_switch.off() catch {};
    log.info("PA enabled", .{});

    // Set speaker volume
    board.audio.setVolume(150);

    log.info("Starting mic -> speaker loopback...", .{});
    log.info("AEC should cancel speaker feedback from microphone.", .{});

    // Audio buffer
    var audio_buffer: [BUFFER_SIZE]i16 = undefined;
    var output_buffer: [BUFFER_SIZE]i16 = undefined;

    var total_samples: u64 = 0;
    var error_count: u32 = 0;

    while (true) {
        // Read from microphone (AEC-processed audio)
        const samples_read = board.audio.readMic(&audio_buffer) catch |err| {
            error_count += 1;
            if (error_count <= 5 or error_count % 100 == 0) {
                log.err("Mic read error #{}: {}", .{ error_count, err });
            }
            platform.time.sleepMs(10);
            continue;
        };

        if (samples_read == 0) {
            platform.time.sleepMs(1);
            continue;
        }

        // Apply gain to mic audio
        for (0..samples_read) |i| {
            const amplified: i32 = @as(i32, audio_buffer[i]) * MIC_GAIN;
            output_buffer[i] = @intCast(std.math.clamp(amplified, std.math.minInt(i16), std.math.maxInt(i16)));
        }

        // Play through speaker
        _ = board.audio.writeSpeaker(output_buffer[0..samples_read]) catch |err| {
            log.err("Speaker write error: {}", .{err});
            platform.time.sleepMs(10);
            continue;
        };

        total_samples += samples_read;

        // Log progress every 5 seconds
        if (total_samples > 0 and total_samples % (SAMPLE_RATE * 5) < BUFFER_SIZE) {
            const seconds = total_samples / SAMPLE_RATE;
            log.info("Running... {}s elapsed, {} samples, {} errors", .{ seconds, total_samples, error_count });
        }
    }
}
