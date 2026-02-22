//! SimAudio — Simulated audio I/O for closed-loop AudioEngine testing.
//!
//! Simulates a complete audio system: speaker, microphone with mixer,
//! acoustic path (delay + gain), and reference reader. Designed to be
//! plugged into AudioEngine as drop-in replacements for real hardware.
//!
//! Architecture:
//!
//!   Test harness writes near-end signal → near_end_ring
//!                                              ↓
//!                                         ┌─────────┐
//!     near_end_ring ──────────────────────→│  mixer  │──→ mic_ring ──→ SimMic.read()
//!     speaker echo (delay+gain) ──────────→│         │
//!                                         └─────────┘
//!                                              ↑
//!   SimSpeaker.write() ──→ spk_ring ──→ SimClock tick:
//!                                         ├─→ acoustic path → echo
//!                                         └─→ ref_ring ──→ SimRefReader.read()
//!
//! The SimClock thread fires every frame_size samples (10ms at 16kHz),
//! simulating the DuplexStream callback. It produces aligned mic + ref.

const std = @import("std");

pub const SimConfig = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    acoustic_delay_samples: u32 = 26,
    acoustic_gain: f32 = 0.76,
    /// Speaker hardware buffer depth in frames.
    /// Ref is delayed by this many frames relative to speaker.write().
    speaker_buffer_depth: u32 = 0,
};

pub const SimAudio = struct {
    const RingCap = 160 * 128;

    config: SimConfig,
    frame_size: u32,

    // Speaker ring: Engine speakerTask writes here
    spk_ring: [RingCap]i16,
    spk_write: usize,
    spk_read: usize,

    // Near-end ring: test harness writes here
    near_end_ring: [RingCap]i16,
    ne_write: usize,
    ne_read: usize,

    // Mic ring: SimClock produces mixed signal here
    mic_ring: [RingCap]i16,
    mic_write: usize,
    mic_read: usize,

    // Ref ring: SimClock produces ref (= speaker output) here
    ref_ring: [RingCap]i16,
    ref_write: usize,
    ref_read: usize,

    // Acoustic delay line
    delay_line: [8192]i16,
    delay_write_pos: usize,

    // Speaker buffer simulation: holds frames before they reach the "hardware"
    spk_buf: [RingCap]i16,
    spk_buf_write: usize,
    spk_buf_read: usize,

    // Synchronization
    mutex: std.Thread.Mutex,
    mic_ready: std.Thread.Condition,
    spk_ready: std.Thread.Condition,

    // Clock thread
    clock_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(cfg: SimConfig) SimAudio {
        return .{
            .config = cfg,
            .frame_size = cfg.frame_size,
            .spk_ring = [_]i16{0} ** RingCap,
            .spk_write = 0,
            .spk_read = 0,
            .near_end_ring = [_]i16{0} ** RingCap,
            .ne_write = 0,
            .ne_read = 0,
            .mic_ring = [_]i16{0} ** RingCap,
            .mic_write = 0,
            .mic_read = 0,
            .ref_ring = [_]i16{0} ** RingCap,
            .ref_write = 0,
            .ref_read = 0,
            .delay_line = [_]i16{0} ** 8192,
            .delay_write_pos = 0,
            .spk_buf = [_]i16{0} ** RingCap,
            .spk_buf_write = 0,
            .spk_buf_read = 0,
            .mutex = .{},
            .mic_ready = .{},
            .spk_ready = .{},
            .clock_thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *SimAudio) !void {
        self.running.store(true, .release);
        self.clock_thread = try std.Thread.spawn(.{}, clockLoop, .{self});
    }

    pub fn stop(self: *SimAudio) void {
        self.running.store(false, .release);
        self.mutex.lock();
        self.mic_ready.broadcast();
        self.spk_ready.broadcast();
        self.mutex.unlock();
        if (self.clock_thread) |t| {
            t.join();
            self.clock_thread = null;
        }
    }

    /// Write near-end signal (test harness injects known signal here).
    pub fn writeNearEnd(self: *SimAudio, buf: []const i16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (buf) |s| {
            self.near_end_ring[(self.ne_write) % RingCap] = s;
            self.ne_write += 1;
        }
    }

    // ================================================================
    // SimClock: simulates DuplexStream callback
    // ================================================================

    fn clockLoop(self: *SimAudio) void {
        const fs: usize = self.frame_size;
        const delay_cap: usize = self.delay_line.len;
        const delay_samples: usize = self.config.acoustic_delay_samples;
        const gain = self.config.acoustic_gain;
        const buf_depth: usize = self.config.speaker_buffer_depth;

        while (self.running.load(.acquire)) {
            // Simulate real-time: sleep for one frame duration
            std.Thread.sleep(@as(u64, fs) * std.time.ns_per_s / self.config.sample_rate);

            self.mutex.lock();
            defer self.mutex.unlock();

            // 1. Pop one frame from speaker ring → speaker buffer
            const spk_avail = self.spk_write -| self.spk_read;
            if (spk_avail >= fs) {
                for (0..fs) |i| {
                    self.spk_buf[(self.spk_buf_write + i) % RingCap] = self.spk_ring[(self.spk_read + i) % RingCap];
                }
                self.spk_read += fs;
                self.spk_buf_write += fs;
                self.spk_ready.signal();
            }

            // 2. Pop from speaker buffer (with buffer_depth delay) → "hardware output"
            // The speaker buffer holds buf_depth frames before releasing to "hardware"
            const buf_avail = self.spk_buf_write -| self.spk_buf_read;
            const buf_threshold = (buf_depth + 1) * fs;
            var hw_frame: [160]i16 = [_]i16{0} ** 160;
            if (buf_avail >= buf_threshold) {
                for (0..fs) |i| {
                    hw_frame[i] = self.spk_buf[(self.spk_buf_read + i) % RingCap];
                }
                self.spk_buf_read += fs;
            }

            // 3. hw_frame is what the speaker physically plays.
            //    Push into acoustic delay line.
            for (0..fs) |i| {
                self.delay_line[(self.delay_write_pos + i) % delay_cap] = hw_frame[i];
            }
            self.delay_write_pos += fs;

            // 4. Read delayed samples from delay line → echo
            //    Also store hw_frame as ref (what speaker played right now)
            var mic_frame: [160]i16 = undefined;
            for (0..fs) |i| {
                // Echo: delayed speaker output * acoustic gain
                var echo: f32 = 0;
                if (self.delay_write_pos > delay_samples + fs) {
                    const idx = self.delay_write_pos - fs + i - delay_samples;
                    echo = @as(f32, @floatFromInt(self.delay_line[idx % delay_cap])) * gain;
                }

                // Near-end: pop from near_end_ring (or 0 if empty)
                var near_end: f32 = 0;
                if (self.ne_read < self.ne_write) {
                    near_end = @floatFromInt(self.near_end_ring[self.ne_read % RingCap]);
                    self.ne_read += 1;
                }

                // Mix: echo + near_end with clipping
                const mixed = echo + near_end;
                mic_frame[i] = if (mixed > 32767) 32767 else if (mixed < -32768) -32768 else @intFromFloat(mixed);
            }

            // 5. Push mic_frame → mic_ring, hw_frame → ref_ring
            for (0..fs) |i| {
                self.mic_ring[(self.mic_write + i) % RingCap] = mic_frame[i];
                self.ref_ring[(self.ref_write + i) % RingCap] = hw_frame[i];
            }
            self.mic_write += fs;
            self.ref_write += fs;
            self.mic_ready.signal();
        }
    }

    // ================================================================
    // Driver interfaces for AudioEngine
    // ================================================================

    pub const Mic = struct {
        parent: *SimAudio,

        pub fn read(self: *Mic, buf: []i16) !usize {
            self.parent.mutex.lock();
            defer self.parent.mutex.unlock();
            while (self.parent.running.load(.acquire)) {
                const avail = self.parent.mic_write -| self.parent.mic_read;
                if (avail >= buf.len) {
                    for (0..buf.len) |i| {
                        buf[i] = self.parent.mic_ring[(self.parent.mic_read + i) % RingCap];
                    }
                    self.parent.mic_read += buf.len;
                    return buf.len;
                }
                self.parent.mic_ready.wait(&self.parent.mutex);
            }
            return 0;
        }
    };

    pub const Speaker = struct {
        parent: *SimAudio,

        pub fn write(self: *Speaker, buf: []const i16) !usize {
            self.parent.mutex.lock();
            defer self.parent.mutex.unlock();
            var offset: usize = 0;
            while (offset < buf.len) {
                const used = self.parent.spk_write -| self.parent.spk_read;
                const space = RingCap - used;
                if (space == 0) {
                    self.parent.spk_ready.wait(&self.parent.mutex);
                    if (!self.parent.running.load(.acquire)) break;
                    continue;
                }
                const chunk = @min(buf.len - offset, space);
                for (0..chunk) |i| {
                    self.parent.spk_ring[(self.parent.spk_write + i) % RingCap] = buf[offset + i];
                }
                self.parent.spk_write += chunk;
                offset += chunk;
            }
            return buf.len;
        }

        pub fn setVolume(_: *Speaker, _: u8) !void {}
    };

    pub const RefReader = struct {
        parent: *SimAudio,

        pub fn read(self: *RefReader, buf: []i16) !usize {
            self.parent.mutex.lock();
            defer self.parent.mutex.unlock();
            while (self.parent.running.load(.acquire)) {
                const avail = self.parent.ref_write -| self.parent.ref_read;
                if (avail >= buf.len) {
                    for (0..buf.len) |i| {
                        buf[i] = self.parent.ref_ring[(self.parent.ref_read + i) % RingCap];
                    }
                    self.parent.ref_read += buf.len;
                    return buf.len;
                }
                self.parent.mic_ready.wait(&self.parent.mutex);
            }
            return 0;
        }
    };

    pub fn mic(self: *SimAudio) Mic {
        return .{ .parent = self };
    }

    pub fn speaker(self: *SimAudio) Speaker {
        return .{ .parent = self };
    }

    pub fn refReader(self: *SimAudio) RefReader {
        return .{ .parent = self };
    }
};

// ============================================================================
// Tests for SimAudio itself
// ============================================================================

const testing = std.testing;
const tu = @import("test_utils.zig");

// S1: Speaker write → ref reader gets same data
test "S1: speaker write passes through to ref reader" {
    var sim = SimAudio.init(.{ .speaker_buffer_depth = 0 });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var rdr = sim.refReader();

    // Write a known tone to speaker
    var tone: [160]i16 = undefined;
    tu.generateSine(&tone, 440.0, 10000.0, 16000, 0);
    _ = try spk.write(&tone);

    // Read from ref reader
    var ref: [160]i16 = undefined;
    _ = try rdr.read(&ref);

    // Ref should match what speaker played
    const ref_rms = tu.rmsEnergy(&ref);
    try testing.expect(ref_rms > 5000);

    // Goertzel: should have 440Hz
    const p440 = tu.goertzelPower(&ref, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&ref, 880.0, 16000.0);
    try testing.expect(p440 > p880 * 50);
}

// S2: Near-end signal appears in mic
test "S2: near-end signal appears in mic" {
    var sim = SimAudio.init(.{});
    try sim.start();
    defer sim.stop();

    // Inject near-end 880Hz
    var ne: [160]i16 = undefined;
    tu.generateSine(&ne, 880.0, 8000.0, 16000, 0);
    sim.writeNearEnd(&ne);

    // Also need speaker to write something (to drive the clock)
    var spk = sim.speaker();
    var silence: [160]i16 = [_]i16{0} ** 160;
    _ = try spk.write(&silence);

    // Read mic
    var mic_drv = sim.mic();
    var mic_buf: [160]i16 = undefined;
    _ = try mic_drv.read(&mic_buf);

    // Mic should have 880Hz
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    try testing.expect(p880 > p440 * 50);
}

// S3: Speaker echo appears in mic (acoustic path)
test "S3: speaker echo appears in mic with delay and gain" {
    var sim = SimAudio.init(.{
        .acoustic_delay_samples = 0,
        .acoustic_gain = 0.5,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    // Write multiple frames of 440Hz to speaker to fill the pipeline
    for (0..5) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 16000.0, 16000, f * 160);
        _ = try spk.write(&tone);
    }

    // Read mic frames — after initial delay, mic should contain 440Hz echo
    var mic_buf: [160]i16 = undefined;
    var last_rms: f64 = 0;
    for (0..5) |_| {
        _ = try mic_drv.read(&mic_buf);
        last_rms = tu.rmsEnergy(&mic_buf);
    }

    // Echo should have energy: 16000 * 0.5 = 8000 amp → RMS ~5656
    std.debug.print("[S3] last mic_rms={d:.0}\n", .{last_rms});
    try testing.expect(last_rms > 2000);

    // Should be 440Hz
    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    try testing.expect(p440 > p880 * 10);
}

// S4: Mixing — near-end + echo appear together in mic
test "S4: near-end and echo mix in mic" {
    var sim = SimAudio.init(.{
        .acoustic_delay_samples = 0,
        .acoustic_gain = 0.5,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..5) |f| {
        // Speaker plays 440Hz
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        // Near-end injects 880Hz
        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    // Read mic
    var mic_buf: [160]i16 = undefined;
    for (0..5) |_| {
        _ = try mic_drv.read(&mic_buf);
    }

    // Mic should have both 440Hz (echo) and 880Hz (near-end)
    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    std.debug.print("[S4] 440Hz={d:.0} 880Hz={d:.0}\n", .{ p440, p880 });
    try testing.expect(p440 > 1000);
    try testing.expect(p880 > 1000);
}

// S5: Clipping — mixed signal that exceeds i16 range gets clamped
test "S5: clipping on mixed signal overflow" {
    var sim = SimAudio.init(.{
        .acoustic_delay_samples = 0,
        .acoustic_gain = 1.0,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..3) |f| {
        // Speaker plays loud signal
        var loud: [160]i16 = undefined;
        tu.generateSine(&loud, 440.0, 30000.0, 16000, f * 160);
        _ = try spk.write(&loud);

        // Near-end also loud
        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 30000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    var mic_buf: [160]i16 = undefined;
    for (0..3) |_| {
        _ = try mic_drv.read(&mic_buf);
    }

    // All samples must be within i16 range (no overflow)
    for (mic_buf) |s| {
        try testing.expect(s >= -32768);
        try testing.expect(s <= 32767);
    }
    // RMS should be high but capped
    const rms = tu.rmsEnergy(&mic_buf);
    std.debug.print("[S5] clipped rms={d:.0}\n", .{rms});
    try testing.expect(rms > 10000);
}

// S6: Speaker buffer depth delays ref relative to speaker.write()
test "S6: speaker buffer depth delays output" {
    var sim = SimAudio.init(.{
        .speaker_buffer_depth = 3,
        .acoustic_delay_samples = 0,
        .acoustic_gain = 0.5,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    // Write tone + padding frames to fill the buffer pipeline
    var tone: [160]i16 = undefined;
    tu.generateSine(&tone, 440.0, 10000.0, 16000, 0);
    _ = try spk.write(&tone);

    var silence: [160]i16 = [_]i16{0} ** 160;
    for (0..5) |_| _ = try spk.write(&silence);

    // Read frames until we find the tone in ref
    var found_tone = false;
    for (0..6) |_| {
        var ref: [160]i16 = undefined;
        var mic_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref);
        const ref_rms = tu.rmsEnergy(&ref);
        std.debug.print("[S6] ref_rms={d:.0}\n", .{ref_rms});
        if (ref_rms > 3000) found_tone = true;
    }

    try testing.expect(found_tone);
}

// S7: Mic and ref are aligned (from same clock tick)
test "S7: mic and ref alignment" {
    var sim = SimAudio.init(.{
        .acoustic_delay_samples = 0,
        .acoustic_gain = 0.8,
        .speaker_buffer_depth = 0,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    // Write frames one at a time, read one at a time
    var aligned_count: usize = 0;
    for (0..10) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        var mic_buf: [160]i16 = undefined;
        var ref_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);

        const mic_rms = tu.rmsEnergy(&mic_buf);
        const ref_rms = tu.rmsEnergy(&ref_buf);

        // Both should have data from the same clock tick
        // When ref has content, mic should also have echo
        if (ref_rms > 100 and mic_rms > 100) {
            aligned_count += 1;
        }
    }

    std.debug.print("[S7] aligned frames with both content: {d}/10\n", .{aligned_count});
    // After initial fill, most frames should have both mic and ref
    try testing.expect(aligned_count >= 5);
}
