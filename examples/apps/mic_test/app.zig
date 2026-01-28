//! Microphone Test Example - Platform Independent App
//!
//! Demonstrates microphone input with AEC using HAL.
//! Hardware: ESP32-S3-Korvo-2 V3 with ES7210 4-channel ADC

const std = @import("std");
const hal = @import("hal");

const platform = @import("platform.zig");
const Board = platform.Board;
const Hardware = platform.Hardware;
const log = Board.log;

const BUILD_TAG = "mic_test_v1";

fn printBoardInfo() void {
    log.info("==========================================", .{});
    log.info("Microphone Test Example", .{});
    log.info("Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{Hardware.name});
    log.info("ADC:         ES7210 (4-channel)", .{});
    log.info("Sample Rate: {}Hz", .{Hardware.sample_rate});
    log.info("==========================================", .{});
}

pub fn run() void {
    printBoardInfo();

    // Initialize board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Board initialized", .{});

    // Test individual channels (factory test mode)
    log.info("==========================================", .{});
    log.info("Factory Test: Testing individual channels", .{});
    log.info("==========================================", .{});

    // Test MIC1 only
    testChannel(&board, 0, "MIC1");

    // Test MIC2 only (if enabled)
    testChannel(&board, 1, "MIC2");

    // Test MIC3 (AEC reference)
    testChannel(&board, 2, "MIC3 (AEC Ref)");

    log.info("==========================================", .{});
    log.info("Factory test complete!", .{});
    log.info("==========================================", .{});

    // Normal operation: enable all configured channels
    log.info("Switching to normal recording mode...", .{});

    // Set recommended gains
    board.mic.setGain(30) catch |err| {
        log.err("Failed to set gain: {}", .{err});
    };

    log.info("Recording... (press Ctrl+C to stop)", .{});

    // Main recording loop
    var buffer: [160]i16 = undefined; // 10ms @ 16kHz
    var total_samples: u64 = 0;
    var max_amplitude: i16 = 0;

    while (true) {
        const samples = board.mic.read(&buffer) catch |err| {
            log.err("Read error: {}", .{err});
            Board.time.sleepMs(100);
            continue;
        };

        if (samples > 0) {
            total_samples += samples;

            // Find max amplitude for level meter
            for (buffer[0..samples]) |sample| {
                const abs = if (sample < 0) -sample else sample;
                if (abs > max_amplitude) max_amplitude = abs;
            }

            // Log level every second
            if (total_samples % 16000 == 0) {
                const level_db = amplitudeToDb(max_amplitude);
                log.info("Audio level: {}dB (max amplitude: {})", .{ level_db, max_amplitude });
                max_amplitude = 0;
            }
        }

        Board.time.sleepMs(10);
    }
}

fn testChannel(board: *Board, channel: u8, name: []const u8) void {
    log.info("Testing {s}...", .{name});

    // Enable only this channel
    for (0..4) |i| {
        board.mic.setChannelEnabled(@intCast(i), i == channel) catch {};
    }

    // Read some samples
    var buffer: [160]i16 = undefined;
    var max_amplitude: i16 = 0;

    for (0..10) |_| { // Read 100ms
        const samples = board.mic.read(&buffer) catch continue;
        for (buffer[0..samples]) |sample| {
            const abs = if (sample < 0) -sample else sample;
            if (abs > max_amplitude) max_amplitude = abs;
        }
        Board.time.sleepMs(10);
    }

    const level_db = amplitudeToDb(max_amplitude);
    const status = if (max_amplitude > 100) "OK" else "LOW/NO SIGNAL";
    log.info("  {s}: {s} (level: {}dB, amplitude: {})", .{ name, status, level_db, max_amplitude });
}

fn amplitudeToDb(amplitude: i16) i16 {
    if (amplitude <= 0) return -96;
    // 20 * log10(amplitude / 32768)
    const normalized = @as(f32, @floatFromInt(amplitude)) / 32768.0;
    const db = 20.0 * @log10(normalized);
    return @intFromFloat(db);
}
