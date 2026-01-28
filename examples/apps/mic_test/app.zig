//! Microphone Test Example - Platform Independent App
//!
//! Demonstrates microphone input with AEC using HAL.
//! Hardware: ESP32-S3-Korvo-2 V3 with ES7210 4-channel ADC
//!
//! This example reads audio from the microphone and logs level information.
//! For TCP streaming to a server, see the server/ directory and README.

const std = @import("std");
const hal = @import("hal");

const platform = @import("platform.zig");
const Board = platform.Board;
const Hardware = platform.Hardware;
const log = Board.log;

const BUILD_TAG = "mic_test_v2";

fn printBoardInfo() void {
    log.info("==========================================", .{});
    log.info("Microphone Test Example", .{});
    log.info("Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{Hardware.name});
    log.info("ADC:         ES7210 (4-channel)", .{});
    log.info("Sample Rate: {}Hz", .{Hardware.sample_rate});
    log.info("Mode:        Local (level monitoring)", .{});
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

    // Set recommended gains
    board.mic.setGain(30) catch |err| {
        log.err("Failed to set gain: {}", .{err});
    };

    log.info("Starting local recording mode...", .{});
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

fn amplitudeToDb(amplitude: i16) i16 {
    if (amplitude <= 0) return -96;
    // 20 * log10(amplitude / 32768)
    const normalized = @as(f32, @floatFromInt(amplitude)) / 32768.0;
    const db = 20.0 * @log10(normalized);
    return @intFromFloat(db);
}
