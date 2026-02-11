//! ADC Piano — press ADC buttons to play Do Re Mi Fa
//!
//! Combines ADC button group with speaker output.
//! Each of the 4 ADC buttons maps to a musical note:
//!   Button 0 → Do  (C4 = 262 Hz)
//!   Button 1 → Re  (D4 = 294 Hz)
//!   Button 2 → Mi  (E4 = 330 Hz)
//!   Button 3 → Fa  (F4 = 349 Hz)

const std = @import("std");
const hal = @import("hal");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// Note frequencies (Hz)
const NOTE_DO: u32 = 262; // C4
const NOTE_RE: u32 = 294; // D4
const NOTE_MI: u32 = 330; // E4
const NOTE_FA: u32 = 349; // F4

const SAMPLE_RATE = platform.Hardware.sample_rate;

// Sine wave amplitude
const SINE_AMPLITUDE: f32 = 12000.0;

/// Generate a sine wave tone at specified frequency
fn generateSineWave(buffer: []i16, frequency: u32, phase: *f32) void {
    if (frequency == 0) {
        @memset(buffer, 0);
        return;
    }

    const phase_increment = @as(f32, @floatFromInt(frequency)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(SAMPLE_RATE));

    for (buffer) |*sample| {
        sample.* = @intFromFloat(@sin(phase.*) * SINE_AMPLITUDE);
        phase.* += phase_increment;
        if (phase.* >= 2.0 * std.math.pi) {
            phase.* -= 2.0 * std.math.pi;
        }
    }
}

fn noteFreq(id: platform.ButtonId) u32 {
    return switch (id) {
        .do_ => NOTE_DO,
        .re => NOTE_RE,
        .mi => NOTE_MI,
        .fa => NOTE_FA,
    };
}

fn noteName(id: platform.ButtonId) []const u8 {
    return switch (id) {
        .do_ => "Do",
        .re => "Re",
        .mi => "Mi",
        .fa => "Fa",
    };
}

/// Play a fixed-duration note (blocking)
fn playNote(board: *Board, buffer: []i16, freq: u32, duration_ms: u32, phase: *f32) void {
    phase.* = 0;
    const duration_samples = SAMPLE_RATE * duration_ms / 1000;
    var played: u32 = 0;
    while (played < duration_samples) {
        generateSineWave(buffer, freq, phase);
        const written = board.speaker.write(buffer) catch 0;
        played += @intCast(written);
    }
}

/// Write silence to flush the DMA buffer
fn flushSilence(board: *Board, buffer: []i16, duration_ms: u32) void {
    @memset(buffer, 0);
    const flush_samples = SAMPLE_RATE * duration_ms / 1000;
    var flushed: u32 = 0;
    while (flushed < flush_samples) {
        const written = board.speaker.write(buffer) catch 0;
        flushed += @intCast(written);
    }
}

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  ADC Piano — Do Re Mi Fa", .{});
    log.info("  Board: {s}", .{Board.meta.id});
    log.info("  Sample rate: {} Hz", .{SAMPLE_RATE});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    // Enable PA (power amplifier)
    board.pa_switch.on() catch |err| {
        log.err("PA enable failed: {}", .{err});
        return;
    };
    defer board.pa_switch.off() catch {};

    board.speaker.setVolume(200) catch {};

    log.info("Playing startup melody: Do Re Mi Fa...", .{});

    var buffer: [160]i16 = undefined;
    var phase: f32 = 0;

    // Startup melody: Do Re Mi Fa
    const melody = [_]u32{ NOTE_DO, NOTE_RE, NOTE_MI, NOTE_FA };
    for (melody) |note| {
        playNote(&board, &buffer, note, 250, &phase);
        flushSilence(&board, &buffer, 60);
    }
    flushSilence(&board, &buffer, 300);

    // Play it again louder to confirm speaker works
    log.info("Playing again...", .{});
    for (melody) |note| {
        playNote(&board, &buffer, note, 400, &phase);
        flushSilence(&board, &buffer, 100);
    }
    flushSilence(&board, &buffer, 500);

    log.info("Ready! Press buttons to play notes.", .{});

    // Discard initial ADC readings (settling time)
    for (0..30) |_| {
        board.buttons.poll();
        while (board.nextEvent()) |_| {}
        Board.time.sleepMs(10);
    }

    var debug_counter: u32 = 0;
    var poll_counter: u32 = 0;

    phase = 0;
    var current_freq: u32 = 0;
    var prev_freq: u32 = 0;

    while (Board.isRunning()) {
        // Poll ADC buttons every ~10 iterations (not every loop — ADC read is slow)
        poll_counter += 1;
        if (poll_counter >= 10) {
            poll_counter = 0;
            board.buttons.poll();
        }

        // Process events
        while (board.nextEvent()) |event| {
            switch (event) {
                .button => |btn| {
                    switch (btn.action) {
                        .press => {
                            const freq = noteFreq(btn.id);
                            log.info("[PIANO] {s} ({} Hz)", .{ noteName(btn.id), freq });
                            current_freq = freq;
                            phase = 0;
                        },
                        .release => {
                            current_freq = 0;
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // When switching from tone to silence, flush the DMA buffer
        if (prev_freq != 0 and current_freq == 0) {
            flushSilence(&board, &buffer, 200);
        }
        prev_freq = current_freq;

        if (current_freq != 0) {
            // Playing a tone — write audio continuously
            generateSineWave(&buffer, current_freq, &phase);
            _ = board.speaker.write(&buffer) catch {};
        } else {
            // Idle — sleep briefly, ADC poll handles timing
            Board.time.sleepMs(5);
        }

        // Debug
        debug_counter += 1;
        if (debug_counter >= 400) {
            debug_counter = 0;
            const raw = board.buttons.getLastRaw();
            log.info("[ADC] {}", .{raw});
        }
    }
}
