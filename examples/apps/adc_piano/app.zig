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

// Sine wave amplitude (reduced to avoid clipping)
const SINE_AMPLITUDE: f32 = 12000.0;

/// Generate a sine wave tone at specified frequency
fn generateSineWave(buffer: []i16, sample_rate: u32, frequency: u32, phase: *f32) void {
    if (frequency == 0) {
        @memset(buffer, 0);
        return;
    }

    const phase_increment = @as(f32, @floatFromInt(frequency)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(sample_rate));

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

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  ADC Piano — Do Re Mi Fa", .{});
    log.info("  Board: {s}", .{Board.meta.id});
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

    log.info("Ready! Press buttons to play notes.", .{});

    var buffer: [160]i16 = undefined; // 10ms @ 16kHz (or 20ms @ 8kHz)
    var phase: f32 = 0;
    var current_freq: u32 = 0;

    while (Board.isRunning()) {
        // Poll ADC buttons
        board.buttons.poll();

        // Process events
        while (board.nextEvent()) |event| {
            switch (event) {
                .button => |btn| {
                    switch (btn.action) {
                        .press => {
                            const freq = noteFreq(btn.id);
                            log.info("[PIANO] {s} ({} Hz)", .{ noteName(btn.id), freq });
                            current_freq = freq;
                            phase = 0; // reset phase for clean attack
                        },
                        .release => {
                            current_freq = 0; // silence
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // Continuously write audio (tone or silence)
        generateSineWave(&buffer, platform.Hardware.sample_rate, current_freq, &phase);
        _ = board.speaker.write(&buffer) catch {};

        if (current_freq == 0) {
            Board.time.sleepMs(5);
        }
    }
}
