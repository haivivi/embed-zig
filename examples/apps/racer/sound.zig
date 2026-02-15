//! Sound Effects — Programmatic 8-bit Style Audio
//!
//! Generates retro PCM waveforms for game events:
//! - Lane switch: short rising blip (square wave)
//! - Crash: noise burst
//! - Milestone: ascending tone
//!
//! Output: i16 samples at 16kHz mono.
//! Caller writes samples to the websim speaker ring buffer.

const ui = @import("ui.zig");

pub const SAMPLE_RATE: u32 = 16000;

/// Maximum samples per sound effect (~200ms)
pub const MAX_SAMPLES = SAMPLE_RATE / 5;

pub const SoundBuf = struct {
    samples: [MAX_SAMPLES]i16 = undefined,
    len: u32 = 0,
};

/// Generate sound samples for a game event.
pub fn generate(event: ui.SoundEvent) SoundBuf {
    var buf = SoundBuf{};
    switch (event) {
        .none => {},
        .lane_switch => genLaneSwitch(&buf),
        .crash => genCrash(&buf),
        .milestone => genMilestone(&buf),
    }
    return buf;
}

/// Lane switch: 50ms rising square wave (440→880Hz)
fn genLaneSwitch(buf: *SoundBuf) void {
    const duration = SAMPLE_RATE / 20; // 50ms = 800 samples
    const amp: i16 = 8000;
    var phase: u32 = 0;

    var i: u32 = 0;
    while (i < duration and i < MAX_SAMPLES) : (i += 1) {
        // Frequency rises from 440 to 880 over duration
        const freq = 440 + (440 * i / duration);
        const half_period = SAMPLE_RATE / (freq * 2);
        if (half_period == 0) {
            buf.samples[i] = 0;
        } else {
            // Square wave
            const cycle_pos = phase % (half_period * 2);
            buf.samples[i] = if (cycle_pos < half_period) amp else -amp;
        }
        phase += 1;
    }
    buf.len = i;
}

/// Crash: 150ms white noise with decay
fn genCrash(buf: *SoundBuf) void {
    const duration = SAMPLE_RATE * 15 / 100; // 150ms
    const amp: i32 = 12000;
    var rng: u32 = 0xDEADBEEF;

    var i: u32 = 0;
    while (i < duration and i < MAX_SAMPLES) : (i += 1) {
        // LCG pseudo-random noise
        rng = rng *% 1103515245 +% 12345;
        const noise: i32 = @rem(@as(i32, @bitCast(rng >> 16)), amp);

        // Decay envelope
        const env: i32 = @intCast(duration - i);
        const sample = @divTrunc(noise * env, @as(i32, @intCast(duration)));
        buf.samples[i] = @intCast(@min(32767, @max(-32768, sample)));
    }
    buf.len = i;
}

/// Milestone: 100ms ascending three-tone (C-E-G)
fn genMilestone(buf: *SoundBuf) void {
    const note_dur = SAMPLE_RATE / 30; // ~33ms per note
    const amp: i16 = 6000;
    const freqs = [_]u32{ 523, 659, 784 }; // C5, E5, G5
    var phase: u32 = 0;

    var total: u32 = 0;
    for (freqs) |freq| {
        var i: u32 = 0;
        while (i < note_dur and total < MAX_SAMPLES) : ({
            i += 1;
            total += 1;
        }) {
            const half_period = SAMPLE_RATE / (freq * 2);
            if (half_period == 0) {
                buf.samples[total] = 0;
            } else {
                const cycle_pos = phase % (half_period * 2);
                buf.samples[total] = if (cycle_pos < half_period) amp else -amp;
            }
            phase += 1;
        }
    }
    buf.len = total;
}
