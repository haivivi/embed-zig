//! SimAudio — Simulated audio I/O for closed-loop AudioEngine testing.
//!
//! Simulates a complete audio system with configurable echo path.
//! Designed as drop-in replacement for real hardware in AudioEngine.
//!
//!   Test harness ──writeNearEnd()──→ near_end_ring
//!                                         ↓
//!                                    ┌─────────┐
//!     near_end ──────────────────────│  mixer  │──→ mic_ring ──→ SimMic.read()
//!     echo (delayed speaker output) ─│         │
//!                                    └─────────┘
//!   SimSpeaker.write() ──→ spk_ring ──→ SimClock:
//!                                        ├─→ echo path (delay + gain) → mixer
//!                                        └─→ ref_ring ──→ SimRefReader.read()
//!
//! SimClock fires once per frame, producing aligned mic + ref.

const std = @import("std");

pub const SimConfig = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    /// Total delay from speaker.write() to echo appearing in mic.read(), in samples.
    /// Includes hardware buffer, physical propagation, and ADC latency.
    echo_delay_samples: u32 = 160,
    /// Echo attenuation (0.0 = no echo, 1.0 = full echo)
    echo_gain: f32 = 0.76,
    /// Whether hardware provides aligned reference (like DuplexStream).
    /// true: SimRefReader available, Engine uses RefReader mode.
    /// false: no RefReader, Engine uses speaker_buffer_depth mode.
    has_hardware_loopback: bool = true,
};

pub const SimAudio = struct {
    const RingCap = 160 * 128;

    config: SimConfig,

    // Speaker ring: Engine speakerTask writes here
    spk_ring: [RingCap]i16,
    spk_write: usize,
    spk_read: usize,

    // Near-end ring: test harness injects signals here
    near_end_ring: [RingCap]i16,
    ne_write: usize,
    ne_read: usize,

    // Mic ring: clock produces mixed signal (echo + near_end) here
    mic_ring: [RingCap]i16,
    mic_write: usize,
    mic_read: usize,

    // Ref ring: clock produces ref (speaker output) here
    ref_ring: [RingCap]i16,
    ref_write: usize,
    ref_read: usize,

    // Echo delay line: speaker samples travel through here
    echo_line: [16384]i16,
    echo_write_pos: usize,
    echo_read_pos: usize,

    // Synchronization
    mutex: std.Thread.Mutex,
    data_ready: std.Thread.Condition,
    spk_space: std.Thread.Condition,

    clock_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(cfg: SimConfig) SimAudio {
        return .{
            .config = cfg,
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
            .echo_line = [_]i16{0} ** 16384,
            .echo_write_pos = 0,
            .echo_read_pos = 0,
            .mutex = .{},
            .data_ready = .{},
            .spk_space = .{},
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
        self.data_ready.broadcast();
        self.spk_space.broadcast();
        self.mutex.unlock();
        if (self.clock_thread) |t| {
            t.join();
            self.clock_thread = null;
        }
    }

    /// Inject near-end signal into mic mixer (test harness calls this).
    pub fn writeNearEnd(self: *SimAudio, buf: []const i16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (buf) |s| {
            self.near_end_ring[self.ne_write % RingCap] = s;
            self.ne_write += 1;
        }
    }

    // ================================================================
    // SimClock: one tick per frame, produces aligned mic + ref
    // ================================================================

    fn clockLoop(self: *SimAudio) void {
        const fs: usize = self.config.frame_size;
        const echo_delay: usize = self.config.echo_delay_samples;
        const gain = self.config.echo_gain;
        const echo_cap: usize = self.echo_line.len;

        while (self.running.load(.acquire)) {
            std.Thread.sleep(@as(u64, fs) * std.time.ns_per_s / self.config.sample_rate);

            self.mutex.lock();
            defer self.mutex.unlock();

            // 1. Pop one frame from speaker ring
            var spk_frame: [160]i16 = [_]i16{0} ** 160;
            const spk_avail = self.spk_write -| self.spk_read;
            if (spk_avail >= fs) {
                for (0..fs) |i| {
                    spk_frame[i] = self.spk_ring[(self.spk_read + i) % RingCap];
                }
                self.spk_read += fs;
                self.spk_space.signal();
            }

            // 2. Push speaker frame into echo delay line
            for (0..fs) |i| {
                self.echo_line[(self.echo_write_pos + i) % echo_cap] = spk_frame[i];
            }
            self.echo_write_pos += fs;

            // 3. Build mic frame: echo + near_end
            var mic_frame: [160]i16 = undefined;
            for (0..fs) |i| {
                // Echo: read from delay line at (write_pos - echo_delay)
                var echo: f32 = 0;
                if (self.echo_write_pos > echo_delay) {
                    const idx = self.echo_write_pos - echo_delay + i;
                    // Only read if we have enough history
                    if (idx >= fs) {
                        echo = @as(f32, @floatFromInt(self.echo_line[(idx - fs) % echo_cap])) * gain;
                    }
                }

                // Near-end
                var near_end: f32 = 0;
                if (self.ne_read < self.ne_write) {
                    near_end = @floatFromInt(self.near_end_ring[self.ne_read % RingCap]);
                    self.ne_read += 1;
                }

                // Mix with clipping
                const mixed = echo + near_end;
                mic_frame[i] = if (mixed > 32767) 32767 else if (mixed < -32768) -32768 else @intFromFloat(mixed);
            }

            // 4. Push mic_frame → mic_ring, spk_frame → ref_ring
            for (0..fs) |i| {
                self.mic_ring[(self.mic_write + i) % RingCap] = mic_frame[i];
                self.ref_ring[(self.ref_write + i) % RingCap] = spk_frame[i];
            }
            self.mic_write += fs;
            self.ref_write += fs;
            self.data_ready.broadcast();
        }
    }

    // ================================================================
    // Driver interfaces
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
                self.parent.data_ready.wait(&self.parent.mutex);
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
                if (!self.parent.running.load(.acquire)) break;
                const used = self.parent.spk_write -| self.parent.spk_read;
                const space = RingCap - used;
                if (space == 0) {
                    self.parent.spk_space.wait(&self.parent.mutex);
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
                self.parent.data_ready.wait(&self.parent.mutex);
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

// S1: Speaker → ref passthrough — ref contains what speaker wrote
test "S1: speaker output appears in ref reader" {
    var sim = SimAudio.init(.{});
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var rdr = sim.refReader();

    var tone: [160]i16 = undefined;
    tu.generateSine(&tone, 440.0, 10000.0, 16000, 0);
    _ = try spk.write(&tone);

    var ref: [160]i16 = undefined;
    _ = try rdr.read(&ref);

    // Goertzel: ref should have 440Hz
    const p440 = tu.goertzelPower(&ref, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&ref, 880.0, 16000.0);
    try testing.expect(p440 > p880 * 50);
    try testing.expect(tu.rmsEnergy(&ref) > 5000);
}

// S2: Near-end injection — near_end signal appears in mic
test "S2: near-end signal appears in mic" {
    var sim = SimAudio.init(.{});
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    // Inject near-end 880Hz
    var ne: [160]i16 = undefined;
    tu.generateSine(&ne, 880.0, 8000.0, 16000, 0);
    sim.writeNearEnd(&ne);

    // Speaker must also write to drive the clock
    var silence: [160]i16 = [_]i16{0} ** 160;
    _ = try spk.write(&silence);

    var mic_buf: [160]i16 = undefined;
    _ = try mic_drv.read(&mic_buf);

    // Mic should have 880Hz from near-end
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    try testing.expect(p880 > p440 * 50);
}

// S3: Echo path — speaker output appears in mic after echo_delay with gain
test "S3: speaker echo in mic with delay and gain" {
    var sim = SimAudio.init(.{
        .echo_delay_samples = 160,
        .echo_gain = 0.5,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    // Write several frames of 440Hz to speaker
    for (0..5) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 16000.0, 16000, f * 160);
        _ = try spk.write(&tone);
    }

    // Read mic frames — echo should appear after delay
    var found_echo = false;
    for (0..5) |_| {
        var mic_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        const rms = tu.rmsEnergy(&mic_buf);
        if (rms > 3000) {
            found_echo = true;
            // Should be 440Hz
            const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
            const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
            try testing.expect(p440 > p880 * 10);
        }
    }

    try testing.expect(found_echo);
}

// S4: Mixing — echo + near-end both appear in mic
test "S4: echo and near-end mix in mic" {
    var sim = SimAudio.init(.{
        .echo_delay_samples = 0,
        .echo_gain = 0.5,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..5) |f| {
        // Speaker: 440Hz
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        // Near-end: 880Hz
        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    // Last mic frame should have both frequencies
    var mic_buf: [160]i16 = undefined;
    for (0..5) |_| _ = try mic_drv.read(&mic_buf);

    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    std.debug.print("[S4] 440Hz={d:.0} 880Hz={d:.0}\n", .{ p440, p880 });
    try testing.expect(p440 > 1000);
    try testing.expect(p880 > 1000);
}

// S5: Clipping — overflow is clamped to i16 range
test "S5: clipping on overflow" {
    var sim = SimAudio.init(.{
        .echo_delay_samples = 0,
        .echo_gain = 1.0,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..3) |f| {
        var loud: [160]i16 = undefined;
        tu.generateSine(&loud, 440.0, 30000.0, 16000, f * 160);
        _ = try spk.write(&loud);

        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 30000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    var mic_buf: [160]i16 = undefined;
    for (0..3) |_| _ = try mic_drv.read(&mic_buf);

    // All samples within i16 range
    for (mic_buf) |s| {
        try testing.expect(s >= -32768);
        try testing.expect(s <= 32767);
    }
    try testing.expect(tu.rmsEnergy(&mic_buf) > 10000);
}

// S6: Mic and ref alignment — both come from same clock tick
test "S6: mic and ref from same clock tick" {
    var sim = SimAudio.init(.{
        .echo_delay_samples = 0,
        .echo_gain = 0.8,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    var aligned: usize = 0;
    for (0..10) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        var mic_buf: [160]i16 = undefined;
        var ref_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);

        const mr = tu.rmsEnergy(&mic_buf);
        const rr = tu.rmsEnergy(&ref_buf);
        if (mr > 100 and rr > 100) aligned += 1;
    }

    std.debug.print("[S6] aligned={d}/10\n", .{aligned});
    try testing.expect(aligned >= 5);
}

// S7: Echo delay — with echo_delay_samples=320, echo is delayed by 2 frames
test "S7: echo delay timing" {
    var sim = SimAudio.init(.{
        .echo_delay_samples = 320,
        .echo_gain = 0.8,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    // Write 1 loud frame then silence
    var tone: [160]i16 = undefined;
    tu.generateSine(&tone, 440.0, 16000.0, 16000, 0);
    _ = try spk.write(&tone);

    var silence: [160]i16 = [_]i16{0} ** 160;
    for (0..5) |_| _ = try spk.write(&silence);

    // Read frames and find when echo appears
    var echo_frame: ?usize = null;
    for (0..6) |f| {
        var mic_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        const rms = tu.rmsEnergy(&mic_buf);
        if (rms > 1000 and echo_frame == null) {
            echo_frame = f;
        }
    }

    std.debug.print("[S7] echo appeared at frame {?d} (delay=320 samples = 2 frames)\n", .{echo_frame});
    // Echo should appear around frame 2-3 (320 samples / 160 = 2 frames delay)
    if (echo_frame) |ef| {
        try testing.expect(ef >= 1 and ef <= 4);
    } else {
        return error.TestUnexpectedResult;
    }
}

// S8: Echo gain — mic echo amplitude matches speaker * gain
test "S8: echo gain accuracy" {
    var sim = SimAudio.init(.{
        .echo_delay_samples = 0,
        .echo_gain = 0.5,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    // Write steady tone
    for (0..10) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);
    }

    // Read last few frames (after steady state)
    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    for (0..10) |_| {
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
    }

    const mic_rms = tu.rmsEnergy(&mic_buf);
    const ref_rms = tu.rmsEnergy(&ref_buf);
    const ratio = mic_rms / ref_rms;

    std.debug.print("[S8] mic_rms={d:.0} ref_rms={d:.0} ratio={d:.2} (expect ~0.5)\n", .{ mic_rms, ref_rms, ratio });
    // Ratio should be close to echo_gain (0.5)
    try testing.expect(ratio > 0.3 and ratio < 0.7);
}

// S9: No echo — echo_gain=0, mic only has near-end
test "S9: zero echo gain — mic has only near-end" {
    var sim = SimAudio.init(.{
        .echo_gain = 0.0,
    });
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..3) |f| {
        // Speaker plays 440Hz but gain=0 so no echo
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        // Near-end: 880Hz
        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    var mic_buf: [160]i16 = undefined;
    for (0..3) |_| _ = try mic_drv.read(&mic_buf);

    // Should have 880Hz but NOT 440Hz
    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    std.debug.print("[S9] 440Hz={d:.0} 880Hz={d:.0}\n", .{ p440, p880 });
    try testing.expect(p880 > p440 * 50);
}

// S10: Silence — no speaker, no near-end → mic is silence
test "S10: silence when no input" {
    var sim = SimAudio.init(.{});
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    var silence: [160]i16 = [_]i16{0} ** 160;
    for (0..3) |_| _ = try spk.write(&silence);

    var mic_buf: [160]i16 = undefined;
    for (0..3) |_| _ = try mic_drv.read(&mic_buf);

    try testing.expect(tu.rmsEnergy(&mic_buf) < 1.0);
}
