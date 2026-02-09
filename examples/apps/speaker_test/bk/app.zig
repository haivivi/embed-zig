//! Speaker Test — BK7258
//!
//! Plays "Twinkle Twinkle Little Star" via onboard DAC.

const std = @import("std");
const bk = @import("bk");
const armino = bk.armino;
const board = bk.boards.bk7258;

const NOTE_C4: u32 = 262;
const NOTE_D4: u32 = 294;
const NOTE_E4: u32 = 330;
const NOTE_F4: u32 = 349;
const NOTE_G4: u32 = 392;
const NOTE_A4: u32 = 440;
const NOTE_REST: u32 = 0;

const NOTE_DURATION_MS: u32 = 400;
const SINE_AMPLITUDE: f32 = 12000.0;

const melody = [_]u32{
    NOTE_C4, NOTE_C4, NOTE_G4, NOTE_G4, NOTE_A4, NOTE_A4, NOTE_G4, NOTE_REST,
    NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_D4, NOTE_C4, NOTE_REST,
    NOTE_G4, NOTE_G4, NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_REST,
    NOTE_G4, NOTE_G4, NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_REST,
    NOTE_C4, NOTE_C4, NOTE_G4, NOTE_G4, NOTE_A4, NOTE_A4, NOTE_G4, NOTE_REST,
    NOTE_F4, NOTE_F4, NOTE_E4, NOTE_E4, NOTE_D4, NOTE_D4, NOTE_C4, NOTE_REST,
};

fn generateSineWave(buffer: []i16, sample_rate: u32, frequency: u32, phase: *f32) void {
    if (frequency == 0) { @memset(buffer, 0); return; }
    const phase_inc = @as(f32, @floatFromInt(frequency)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(sample_rate));
    for (buffer) |*sample| {
        sample.* = @intFromFloat(@sin(phase.*) * SINE_AMPLITUDE);
        phase.* += phase_inc;
        if (phase.* >= 2.0 * std.math.pi) phase.* -= 2.0 * std.math.pi;
    }
}

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "  Speaker Test - Twinkle Star (BK7258)");
    armino.log.info("ZIG", "==========================================");
    armino.log.logFmt("ZIG", "Sample rate: {d}Hz", .{board.audio.sample_rate});

    // Init speaker via audio pipeline
    var speaker = armino.speaker.Speaker.init(
        board.audio.sample_rate,
        board.audio.channels,
        board.audio.bits,
        board.audio.dig_gain,
    ) catch {
        armino.log.err("ZIG", "Speaker init failed!");
        return;
    };
    defer speaker.deinit();

    armino.log.info("ZIG", "Speaker initialized! Playing melody...");

    var buffer: [160]i16 = undefined;
    var phase: f32 = 0;
    var loop_count: u32 = 0;

    const samples_per_note = board.audio.sample_rate * NOTE_DURATION_MS / 1000;
    const rest_samples = board.audio.sample_rate * 50 / 1000;

    while (true) {
        loop_count += 1;
        armino.log.logFmt("ZIG", "Loop #{d}", .{loop_count});

        for (melody) |note| {
            phase = 0;
            const dur = if (note == NOTE_REST) rest_samples else samples_per_note;
            var played: u32 = 0;

            while (played < dur) {
                generateSineWave(&buffer, board.audio.sample_rate, note, &phase);
                const written = speaker.write(&buffer) catch {
                    armino.time.sleepMs(10);
                    continue;
                };
                played += @intCast(written);
            }
            armino.time.sleepMs(20);
        }

        armino.log.info("ZIG", "Melody done, restarting...");
        armino.time.sleepMs(1000);
    }
}
