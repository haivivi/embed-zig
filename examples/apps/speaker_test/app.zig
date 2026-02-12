//! Speaker Test Example - Platform Independent App
//!
//! Demonstrates mono speaker output using HAL.
//! Hardware: ESP32-S3-Korvo-2 V3 with ES8311 DAC
//!
//! This example plays "Twinkle Twinkle Little Star" melody.

const std = @import("std");
const hal = @import("hal");

const platform = @import("platform.zig");
const Board = platform.Board;
const Hardware = platform.Hardware;
const log = Board.log;

const BUILD_TAG = "speaker_test_v3_twinkle";

// Note frequencies (Hz) - C4 major scale
const NOTE_C4: u32 = 262;
const NOTE_D4: u32 = 294;
const NOTE_E4: u32 = 330;
const NOTE_F4: u32 = 349;
const NOTE_G4: u32 = 392;
const NOTE_A4: u32 = 440;
const NOTE_REST: u32 = 0;

// Note duration in milliseconds
const NOTE_DURATION_MS: u32 = 400;
const REST_DURATION_MS: u32 = 50;

// Sine wave amplitude
const AMPLITUDE: i16 = 12000;

// 256-entry sine lookup table (comptime — @sin works at comptime, not runtime on freestanding)
const sine_table = blk: {
    var table: [256]i16 = undefined;
    for (0..256) |i| {
        const angle = @as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / 256.0;
        table[i] = @intFromFloat(@sin(angle) * 32767.0);
    }
    break :blk table;
};

// Twinkle Twinkle Little Star melody
const melody = [_]u32{
    // Twinkle twinkle little star
    NOTE_C4, NOTE_C4, NOTE_G4, NOTE_G4, NOTE_A4, NOTE_A4, NOTE_G4, NOTE_REST,
    // How I wonder what you are
    NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_D4, NOTE_C4, NOTE_REST,
    // Up above the world so high
    NOTE_G4, NOTE_G4, NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_REST,
    // Like a diamond in the sky
    NOTE_G4, NOTE_G4, NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_REST,
    // Twinkle twinkle little star
    NOTE_C4, NOTE_C4, NOTE_G4, NOTE_G4, NOTE_A4, NOTE_A4, NOTE_G4, NOTE_REST,
    // How I wonder what you are
    NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_D4, NOTE_C4, NOTE_REST,
};

fn printBoardInfo() void {
    log.info("==========================================", .{});
    log.info("Twinkle Twinkle Little Star", .{});
    log.info("Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{Hardware.name});
    log.info("DAC:         ES8311 (mono)", .{});
    log.info("Sample Rate: {}Hz", .{Hardware.sample_rate});
    log.info("PA GPIO:     {}", .{Hardware.pa_enable_gpio});
    log.info("==========================================", .{});
}

/// Generate sine wave using integer-only LUT (no runtime @sin — broken on freestanding ARM)
fn generateSineWave(buffer: []i16, sample_rate: u32, frequency: u32, phase: *u32) void {
    if (frequency == 0) {
        @memset(buffer, 0);
        return;
    }

    const phase_inc: u32 = frequency * 65536 / sample_rate;

    for (buffer) |*sample| {
        const idx: u8 = @truncate(phase.* >> 8);
        const sin_val = sine_table[idx];
        sample.* = @intCast(@divTrunc(@as(i32, sin_val) * @as(i32, AMPLITUDE), 32767));
        phase.* +%= phase_inc;
    }
}

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

    // Enable PA (Power Amplifier)
    board.pa_switch.on() catch |err| {
        log.err("Failed to enable PA: {}", .{err});
        return;
    };
    defer board.pa_switch.off() catch {};
    log.info("PA enabled", .{});

    // DAC gain range: 0x00-0x3F (-45dB to +18dB), 0x2D=0dB, 0x3F=+18dB
    // (NOT 0-255 like ESP!)
    board.speaker.setVolume(0x3F) catch {};

    log.info("Playing Twinkle Twinkle Little Star (loop)", .{});

    // Main playback loop
    var buffer: [160]i16 = undefined;
    var phase: u32 = 0;
    var loop_count: u32 = 0;

    const samples_per_note = (Hardware.sample_rate * NOTE_DURATION_MS) / 1000;
    const samples_per_rest = (Hardware.sample_rate * REST_DURATION_MS) / 1000;

    while (true) {
        loop_count += 1;
        log.info("Loop #{}", .{loop_count});

        for (melody) |note| {
            phase = 0; // Reset phase for each note

            const duration_samples = if (note == NOTE_REST) samples_per_rest else samples_per_note;
            var samples_played: u32 = 0;

            while (samples_played < duration_samples) {
                // Generate audio for this note
                generateSineWave(&buffer, Hardware.sample_rate, note, &phase);

                // Write to speaker
                const samples_written = board.speaker.write(&buffer) catch |err| {
                    log.err("Write error: {}", .{err});
                    Board.time.sleepMs(10);
                    continue;
                };

                samples_played += @intCast(samples_written);
            }

            // Small gap between notes for articulation
            Board.time.sleepMs(20);
        }

        // Pause between loops
        log.info("End of melody, restarting...", .{});
        Board.time.sleepMs(1000);
    }
}
