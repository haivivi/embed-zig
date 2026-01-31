//! AEC Test Example
//!
//! Tests AEC (Acoustic Echo Cancellation) with mic -> speaker loopback.
//! Speak into the microphone and hear your voice through the speaker.
//! AEC cancels the speaker feedback from the microphone input.
//!
//! Hardware: ESP32-S3-Korvo-2 V3 with ES7210 ADC + ES8311 DAC

const std = @import("std");

const platform = @import("platform.zig");
const Board = platform.Board;
const Hardware = platform.Hardware;
const log = Board.log;

// Audio parameters
const SAMPLE_RATE: u32 = Hardware.sample_rate;
const BUFFER_SIZE: usize = 256;
const MIC_GAIN: i32 = 16;

/// Application entry point
pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("AEC (Echo Cancellation) Test", .{});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{Hardware.name});
    log.info("Sample Rate: {}Hz", .{SAMPLE_RATE});
    log.info("Buffer Size: {} samples", .{BUFFER_SIZE});
    log.info("Mic Gain:    {}x", .{MIC_GAIN});
    log.info("==========================================", .{});

    // Initialize board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };
    defer board.deinit();

    // Enable PA (Power Amplifier)
    board.pa_switch.on() catch |err| {
        log.err("Failed to enable PA: {}", .{err});
        return;
    };
    defer board.pa_switch.off() catch {};

    // Set speaker volume
    board.audio.setVolume(150);

    log.info("Board initialized. Starting loopback...", .{});
    log.info("Speak into the mic - AEC cancels speaker feedback.", .{});

    // Audio buffers
    var input_buffer: [BUFFER_SIZE]i16 = undefined;
    var output_buffer: [BUFFER_SIZE]i16 = undefined;

    var total_samples: u64 = 0;
    var error_count: u32 = 0;

    while (true) {
        // Read from microphone (AEC-processed)
        const samples_read = board.audio.readMic(&input_buffer) catch |err| {
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

        // Apply gain
        for (0..samples_read) |i| {
            const amplified: i32 = @as(i32, input_buffer[i]) * MIC_GAIN;
            output_buffer[i] = @intCast(std.math.clamp(amplified, std.math.minInt(i16), std.math.maxInt(i16)));
        }

        // Play through speaker
        _ = board.audio.writeSpeaker(output_buffer[0..samples_read]) catch |err| {
            log.err("Speaker write error: {}", .{err});
            platform.time.sleepMs(10);
            continue;
        };

        total_samples += samples_read;

        // Log every 10 seconds
        if (total_samples > 0 and total_samples % (SAMPLE_RATE * 10) < BUFFER_SIZE) {
            const seconds = total_samples / SAMPLE_RATE;
            log.info("Running {}s, {} samples, {} errors", .{ seconds, total_samples, error_count });
        }
    }
}
