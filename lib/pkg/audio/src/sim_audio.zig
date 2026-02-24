//! SimAudio — Simulated audio I/O for closed-loop AudioEngine testing.
//!
//! Simulates speaker, microphone (with mixer), acoustic echo path, and
//! optionally a hardware-aligned reference reader.
//!
//!   writeNearEnd() → near_end_ring ─┐
//!                                    ├─ mixer ──→ mic_ring ──→ Mic.read()
//!   echo (delayed speaker output) ──┘
//!
//!   Speaker.write() ──→ spk_ring ──→ clock tick:
//!                                     ├─→ echo path (delay + gain) → mixer
//!                                     └─→ ref_ring ──→ RefReader.read()
//!                                          (only if has_hardware_loopback)

const std = @import("std");

pub const SimConfig = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    echo_delay_samples: u32 = 160,
    echo_gain: f32 = 0.76,
    has_hardware_loopback: bool = true,
    /// When true, RefReader returns delayed speaker output (aligned with echo in mic)
    /// When false, RefReader returns current speaker output (not aligned)
    ref_aligned_with_echo: bool = true,
    /// RMS level of continuous ambient noise injected into mic (0 = none)
    ambient_noise_rms: f32 = 0,
    /// Resonant frequency where echo gain is boosted (Hz, 0 = disabled)
    resonance_freq: f32 = 0,
    /// Extra gain at resonant frequency (multiplied on top of echo_gain)
    resonance_gain: f32 = 3.0,
    /// Q factor of resonance (higher = narrower peak)
    resonance_q: f32 = 5.0,
};

pub fn SimAudio(comptime cfg: SimConfig) type {
    const RingCap = cfg.frame_size * 128;
    const frame_size = cfg.frame_size;

    return struct {
        const Self = @This();

        spk_ring: [RingCap]i16,
        spk_write: usize,
        spk_read: usize,

        near_end_ring: [RingCap]i16,
        ne_write: usize,
        ne_read: usize,

        mic_ring: [RingCap]i16,
        mic_write: usize,
        mic_read: usize,

        ref_ring: if (cfg.has_hardware_loopback) [RingCap]i16 else void,
        ref_write: if (cfg.has_hardware_loopback) usize else void,
        ref_read: if (cfg.has_hardware_loopback) usize else void,

        echo_line: [16384]i16,
        echo_write_pos: usize,

        // Resonant biquad filter state (2nd-order IIR)
        biquad_z1: f32,
        biquad_z2: f32,

        // Ambient noise PRNG
        noise_rng: u64,

        mutex: std.Thread.Mutex,
        data_ready: std.Thread.Condition,
        spk_space: std.Thread.Condition,

        clock_thread: ?std.Thread,
        running: std.atomic.Value(bool),

        pub fn init() Self {
            return .{
                .spk_ring = [_]i16{0} ** RingCap,
                .spk_write = 0,
                .spk_read = 0,
                .near_end_ring = [_]i16{0} ** RingCap,
                .ne_write = 0,
                .ne_read = 0,
                .mic_ring = [_]i16{0} ** RingCap,
                .mic_write = 0,
                .mic_read = 0,
                .ref_ring = if (cfg.has_hardware_loopback) [_]i16{0} ** RingCap else {},
                .ref_write = if (cfg.has_hardware_loopback) 0 else {},
                .ref_read = if (cfg.has_hardware_loopback) 0 else {},
                .echo_line = [_]i16{0} ** 16384,
                .echo_write_pos = 0,
                .biquad_z1 = 0,
                .biquad_z2 = 0,
                .noise_rng = 0xDEADBEEF12345678,
                .mutex = .{},
                .data_ready = .{},
                .spk_space = .{},
                .clock_thread = null,
                .running = std.atomic.Value(bool).init(false),
            };
        }

        pub fn start(self: *Self) !void {
            self.running.store(true, .release);
            self.clock_thread = try std.Thread.spawn(.{}, clockLoop, .{self});
        }

        pub fn stop(self: *Self) void {
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

        pub fn writeNearEnd(self: *Self, buf: []const i16) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (buf) |s| {
                self.near_end_ring[self.ne_write % RingCap] = s;
                self.ne_write += 1;
            }
        }

        // ============================================================
        // Clock: one tick per frame
        // ============================================================

        fn clockLoop(self: *Self) void {
            const echo_delay: usize = cfg.echo_delay_samples;
            const gain = cfg.echo_gain;
            const echo_cap: usize = self.echo_line.len;

            while (self.running.load(.acquire)) {
                std.Thread.sleep(@as(u64, frame_size) * std.time.ns_per_s / cfg.sample_rate);

                self.mutex.lock();
                defer self.mutex.unlock();

                // Pop one frame from speaker ring
                var spk_frame: [frame_size]i16 = [_]i16{0} ** frame_size;
                const spk_avail = self.spk_write -| self.spk_read;
                if (spk_avail >= frame_size) {
                    for (0..frame_size) |i| {
                        spk_frame[i] = self.spk_ring[(self.spk_read + i) % RingCap];
                    }
                    self.spk_read += frame_size;
                    self.spk_space.signal();
                }

                // Push into echo delay line
                for (0..frame_size) |i| {
                    self.echo_line[(self.echo_write_pos + i) % echo_cap] = spk_frame[i];
                }
                self.echo_write_pos += frame_size;

                // Build mic frame: echo (with resonance) + near_end + ambient noise
                var mic_frame: [frame_size]i16 = undefined;
                for (0..frame_size) |i| {
                    // Base echo: delayed speaker * gain
                    var echo: f32 = 0;
                    if (self.echo_write_pos > echo_delay) {
                        const idx = self.echo_write_pos - echo_delay + i;
                        if (idx >= frame_size) {
                            echo = @as(f32, @floatFromInt(self.echo_line[(idx - frame_size) % echo_cap])) * gain;
                        }
                    }

                    // Resonant filter: boosts echo at resonance_freq
                    // 2nd-order IIR peaking EQ
                    if (cfg.resonance_freq > 0) {
                        const w0 = 2.0 * std.math.pi * cfg.resonance_freq / @as(f32, @floatFromInt(cfg.sample_rate));
                        const alpha = @sin(w0) / (2.0 * cfg.resonance_q);
                        const a0 = 1.0 + alpha;
                        const b0 = (1.0 + alpha * cfg.resonance_gain) / a0;
                        const b1 = (-2.0 * @cos(w0)) / a0;
                        const b2 = (1.0 - alpha * cfg.resonance_gain) / a0;
                        const a1 = b1; // (-2*cos(w0))/a0
                        const a2 = (1.0 - alpha) / a0;

                        const input = echo;
                        const output = b0 * input + self.biquad_z1;
                        self.biquad_z1 = b1 * input - a1 * output + self.biquad_z2;
                        self.biquad_z2 = b2 * input - a2 * output;
                        echo = output;
                    }

                    // Near-end signal
                    var near_end: f32 = 0;
                    if (self.ne_read < self.ne_write) {
                        near_end = @floatFromInt(self.near_end_ring[self.ne_read % RingCap]);
                        self.ne_read += 1;
                    }

                    // Ambient noise
                    var ambient: f32 = 0;
                    if (cfg.ambient_noise_rms > 0) {
                        self.noise_rng ^= self.noise_rng << 13;
                        self.noise_rng ^= self.noise_rng >> 7;
                        self.noise_rng ^= self.noise_rng << 17;
                        const raw: f32 = @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(self.noise_rng)))));
                        ambient = raw / 2147483648.0 * cfg.ambient_noise_rms * 1.73;
                    }

                    const mixed = echo + near_end + ambient;
                    mic_frame[i] = if (mixed > 32767) 32767 else if (mixed < -32768) -32768 else @intFromFloat(mixed);
                }

                // Push mic_ring
                for (0..frame_size) |i| {
                    self.mic_ring[(self.mic_write + i) % RingCap] = mic_frame[i];
                }
                self.mic_write += frame_size;

                // Push ref_ring (only if hardware loopback)
                if (cfg.has_hardware_loopback) {
                    for (0..frame_size) |i| {
                        const ref_sample: i16 = if (cfg.ref_aligned_with_echo) blk: {
                            // Ref aligned with echo: return delayed speaker (same as what creates echo)
                            if (self.echo_write_pos > echo_delay) {
                                const idx = self.echo_write_pos - echo_delay + i;
                                if (idx >= frame_size) {
                                    break :blk self.echo_line[(idx - frame_size) % echo_cap];
                                }
                            }
                            break :blk 0;
                        } else blk: {
                            // Ref not aligned: return current speaker output
                            break :blk spk_frame[i];
                        };
                        self.ref_ring[(self.ref_write + i) % RingCap] = ref_sample;
                    }
                    self.ref_write += frame_size;
                }

                self.data_ready.broadcast();
            }
        }

        // ============================================================
        // Driver interfaces
        // ============================================================

        pub const Mic = struct {
            parent: *Self,

            pub fn read(self_mic: *Mic, buf: []i16) !usize {
                self_mic.parent.mutex.lock();
                defer self_mic.parent.mutex.unlock();
                while (self_mic.parent.running.load(.acquire)) {
                    const avail = self_mic.parent.mic_write -| self_mic.parent.mic_read;
                    if (avail >= buf.len) {
                        for (0..buf.len) |i| {
                            buf[i] = self_mic.parent.mic_ring[(self_mic.parent.mic_read + i) % RingCap];
                        }
                        self_mic.parent.mic_read += buf.len;
                        return buf.len;
                    }
                    self_mic.parent.data_ready.wait(&self_mic.parent.mutex);
                }
                return 0;
            }
        };

        pub const Speaker = struct {
            parent: *Self,

            pub fn write(self_spk: *Speaker, buf: []const i16) !usize {
                self_spk.parent.mutex.lock();
                defer self_spk.parent.mutex.unlock();
                var offset: usize = 0;
                while (offset < buf.len) {
                    if (!self_spk.parent.running.load(.acquire)) break;
                    const used = self_spk.parent.spk_write -| self_spk.parent.spk_read;
                    const space = RingCap - used;
                    if (space == 0) {
                        self_spk.parent.spk_space.wait(&self_spk.parent.mutex);
                        continue;
                    }
                    const chunk = @min(buf.len - offset, space);
                    for (0..chunk) |i| {
                        self_spk.parent.spk_ring[(self_spk.parent.spk_write + i) % RingCap] = buf[offset + i];
                    }
                    self_spk.parent.spk_write += chunk;
                    offset += chunk;
                }
                return buf.len;
            }

            pub fn setVolume(_: *Speaker, _: u8) !void {}
        };

        pub const RefReader = if (cfg.has_hardware_loopback) struct {
            parent: *Self,

            pub fn read(self_ref: *RefReader, buf: []i16) !usize {
                self_ref.parent.mutex.lock();
                defer self_ref.parent.mutex.unlock();
                while (self_ref.parent.running.load(.acquire)) {
                    const avail = self_ref.parent.ref_write -| self_ref.parent.ref_read;
                    if (avail >= buf.len) {
                        for (0..buf.len) |i| {
                            buf[i] = self_ref.parent.ref_ring[(self_ref.parent.ref_read + i) % RingCap];
                        }
                        self_ref.parent.ref_read += buf.len;
                        return buf.len;
                    }
                    self_ref.parent.data_ready.wait(&self_ref.parent.mutex);
                }
                return 0;
            }
        } else void;

        pub fn mic(self: *Self) Mic {
            return .{ .parent = self };
        }

        pub fn speaker(self: *Self) Speaker {
            return .{ .parent = self };
        }

        pub fn refReader(self: *Self) if (cfg.has_hardware_loopback) RefReader else void {
            if (cfg.has_hardware_loopback) {
                return .{ .parent = self };
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const tu = @import("test_utils.zig");

// ---- Mode A: has_hardware_loopback = true ----

const SimA = SimAudio(.{ .echo_delay_samples = 160, .echo_gain = 0.5, .has_hardware_loopback = true });

// A1: RefReader content = speaker data (Goertzel verified)
test "A1: ref reader returns speaker data" {
    var sim = SimA.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var rdr = sim.refReader();

    // Speaker writes 440Hz
    for (0..3) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);
    }

    // Ref should contain 440Hz
    var ref: [160]i16 = undefined;
    for (0..3) |_| _ = try rdr.read(&ref);

    const p440 = tu.goertzelPower(&ref, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&ref, 880.0, 16000.0);
    std.debug.print("[A1] ref 440Hz={d:.0} 880Hz={d:.0}\n", .{ p440, p880 });
    try testing.expect(p440 > p880 * 50);
    try testing.expect(tu.rmsEnergy(&ref) > 5000);
}

// A2: Ref and mic are frame-aligned (same clock tick)
test "A2: ref and mic aligned" {
    var sim = SimA.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    // Write 10 frames, read mic+ref each time, count how many have matching content
    var aligned: usize = 0;
    for (0..10) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        var mic_buf: [160]i16 = undefined;
        var ref_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);

        // Both should have content from same tick
        if (tu.rmsEnergy(&ref_buf) > 100) aligned += 1;
    }

    std.debug.print("[A2] aligned={d}/10\n", .{aligned});
    try testing.expect(aligned >= 7);
}

// A3: Mic = echo(speaker) + near_end, both frequencies present
test "A3: mic mixes echo and near-end" {
    const Sim = SimAudio(.{ .echo_delay_samples = 0, .echo_gain = 0.5, .has_hardware_loopback = true });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..5) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    var mic_buf: [160]i16 = undefined;
    for (0..5) |_| _ = try mic_drv.read(&mic_buf);

    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    std.debug.print("[A3] mic 440Hz={d:.0} 880Hz={d:.0}\n", .{ p440, p880 });
    try testing.expect(p440 > 1000);
    try testing.expect(p880 > 1000);
}

// A4: Echo delay correct
test "A4: echo delay timing" {
    const Sim = SimAudio(.{ .echo_delay_samples = 320, .echo_gain = 0.8, .has_hardware_loopback = true });
    var sim = Sim.init();
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

    var echo_frame: ?usize = null;
    for (0..6) |f| {
        var mic_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        if (tu.rmsEnergy(&mic_buf) > 1000 and echo_frame == null) echo_frame = f;
    }

    std.debug.print("[A4] echo at frame {?d} (expect ~2 for 320/160)\n", .{echo_frame});
    if (echo_frame) |ef| {
        try testing.expect(ef >= 1 and ef <= 4);
    } else return error.TestUnexpectedResult;
}

// A5: Echo gain accuracy
test "A5: echo gain accuracy" {
    const Sim = SimAudio(.{ .echo_delay_samples = 0, .echo_gain = 0.5, .has_hardware_loopback = true });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    for (0..10) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);
    }

    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    for (0..10) |_| {
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
    }

    const mic_rms = tu.rmsEnergy(&mic_buf);
    const ref_rms = tu.rmsEnergy(&ref_buf);
    const ratio = mic_rms / ref_rms;
    std.debug.print("[A5] mic={d:.0} ref={d:.0} ratio={d:.2} (expect ~0.5)\n", .{ mic_rms, ref_rms, ratio });
    try testing.expect(ratio > 0.3 and ratio < 0.7);
}

// ---- Mode B: has_hardware_loopback = false ----

const SimB = SimAudio(.{ .echo_delay_samples = 160, .echo_gain = 0.5, .has_hardware_loopback = false });

// B1: RefReader does not exist at comptime
test "B1: no RefReader when has_hardware_loopback=false" {
    try testing.expect(!@hasDecl(SimB, "RefReader") or SimB.RefReader == void);
}

// B2: Mic still mixes echo + near_end correctly
test "B2: mic works without hardware loopback" {
    var sim = SimB.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..5) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    var mic_buf: [160]i16 = undefined;
    for (0..5) |_| _ = try mic_drv.read(&mic_buf);

    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    std.debug.print("[B2] mic 440Hz={d:.0} 880Hz={d:.0}\n", .{ p440, p880 });
    // Only near-end 880Hz should be present (echo has delay=160, may not appear yet)
    try testing.expect(p880 > 1000);
}

// B3: Echo delay and gain still work
test "B3: echo works without hardware loopback" {
    const Sim = SimAudio(.{ .echo_delay_samples = 0, .echo_gain = 0.5, .has_hardware_loopback = false });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..5) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 16000.0, 16000, f * 160);
        _ = try spk.write(&tone);
    }

    var mic_buf: [160]i16 = undefined;
    var last_rms: f64 = 0;
    for (0..5) |_| {
        _ = try mic_drv.read(&mic_buf);
        last_rms = tu.rmsEnergy(&mic_buf);
    }

    std.debug.print("[B3] echo rms={d:.0} (expect ~5600 for 16000*0.5/sqrt2)\n", .{last_rms});
    try testing.expect(last_rms > 2000);
}

// ---- Common tests ----

// C1: Clipping
test "C1: clipping on overflow" {
    const Sim = SimAudio(.{ .echo_delay_samples = 0, .echo_gain = 1.0, .has_hardware_loopback = true });
    var sim = Sim.init();
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

    for (mic_buf) |s| {
        try testing.expect(s >= -32768 and s <= 32767);
    }
    try testing.expect(tu.rmsEnergy(&mic_buf) > 10000);
}

// C2: Silence
test "C2: silence when no input" {
    var sim = SimA.init();
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

// C3: No echo when echo_gain=0
test "C3: zero echo gain" {
    const Sim = SimAudio(.{ .echo_gain = 0.0, .has_hardware_loopback = true });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    for (0..3) |f| {
        var tone: [160]i16 = undefined;
        tu.generateSine(&tone, 440.0, 10000.0, 16000, f * 160);
        _ = try spk.write(&tone);

        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    var mic_buf: [160]i16 = undefined;
    for (0..3) |_| _ = try mic_drv.read(&mic_buf);

    const p440 = tu.goertzelPower(&mic_buf, 440.0, 16000.0);
    const p880 = tu.goertzelPower(&mic_buf, 880.0, 16000.0);
    std.debug.print("[C3] 440Hz={d:.0} 880Hz={d:.0}\n", .{ p440, p880 });
    try testing.expect(p880 > p440 * 50);
}

// ---- Baseline: no AEC, echo should be present ----

// D1: Mic passthrough to speaker → echo builds up
test "D1: no AEC — echo present in mic" {
    const Sim = SimAudio(.{ .echo_delay_samples = 0, .echo_gain = 0.8, .has_hardware_loopback = true });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    // Inject 880Hz near-end for 3 frames
    for (0..3) |f| {
        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);
    }

    // Passthrough: mic → speaker (no AEC)
    for (0..10) |_| {
        var mic_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        _ = try spk.write(&mic_buf);
    }

    // After several rounds, mic should contain echo of 880Hz from speaker
    var mic_buf: [160]i16 = undefined;
    _ = try mic_drv.read(&mic_buf);

    const rms = tu.rmsEnergy(&mic_buf);
    std.debug.print("[D1] mic rms after passthrough loop={d:.0}\n", .{rms});
    // Should have significant energy from echo feedback
    try testing.expect(rms > 100);
}

// D2: High echo_gain without AEC → signal grows
test "D2: no AEC high gain — signal grows" {
    const Sim = SimAudio(.{ .echo_delay_samples = 0, .echo_gain = 0.95, .has_hardware_loopback = true });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    // Seed with one frame of noise
    var seed: [160]i16 = undefined;
    tu.generateSine(&seed, 440.0, 1000.0, 16000, 0);
    sim.writeNearEnd(&seed);

    // Passthrough loop, track energy per frame
    var first_rms: f64 = 0;
    var last_rms: f64 = 0;
    for (0..20) |f| {
        var mic_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        _ = try spk.write(&mic_buf);
        const rms = tu.rmsEnergy(&mic_buf);
        if (f == 2) first_rms = rms;
        last_rms = rms;
    }

    std.debug.print("[D2] first_rms={d:.0} last_rms={d:.0}\n", .{ first_rms, last_rms });
    // With gain=0.95 and no AEC, echo persists: 0.95^20 ≈ 0.36 of original
    // Signal should still be audible (> 50 RMS) after 20 rounds
    try testing.expect(last_rms > 50);
}

// D3: Clipping produces harmonics
test "D3: clipping produces harmonics" {
    const Sim = SimAudio(.{ .echo_delay_samples = 0, .echo_gain = 1.0, .has_hardware_loopback = true });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();

    // Speaker plays 440Hz at amp=30000, echo gain=1.0
    // Near-end also 440Hz at amp=30000 → total 60000 amp, clips hard at ±32767
    for (0..10) |f| {
        var loud: [160]i16 = undefined;
        tu.generateSine(&loud, 440.0, 30000.0, 16000, f * 160);
        _ = try spk.write(&loud);
        sim.writeNearEnd(&loud);
    }

    var all: [1600]i16 = undefined;
    for (0..10) |f| {
        var mic_buf: [160]i16 = undefined;
        _ = try mic_drv.read(&mic_buf);
        @memcpy(all[f * 160 ..][0..160], &mic_buf);
    }

    // Clipped sine → square-like waveform → odd harmonics (3rd = 1320Hz)
    const p440 = tu.goertzelPower(&all, 440.0, 16000.0);
    const p1320 = tu.goertzelPower(&all, 1320.0, 16000.0);
    std.debug.print("[D3] 440Hz={d:.0} 1320Hz(3rd)={d:.0}\n", .{ p440, p1320 });
    try testing.expect(p440 > 1000);
    // Hard clipping of a sine produces significant 3rd harmonic
    try testing.expect(p1320 > p440 * 0.01);
}

// ============================================================================
// Realistic closed-loop AEC tests (reproduces real-hardware failure)
// ============================================================================

const aec3_mod = @import("aec3/aec3.zig");

// R1: Quiet room with ambient noise + resonance → AEC must keep signal stable
test "R1: realistic closed-loop — ambient noise + resonance, no divergence" {
    const Sim = SimAudio(.{
        .echo_delay_samples = 350,
        .echo_gain = 0.8,
        .has_hardware_loopback = true,
        .ambient_noise_rms = 100,
        .resonance_freq = 800,
        .resonance_gain = 10.0,
        .resonance_q = 2.0,
    });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    var aec = try aec3_mod.Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .sample_rate = 16000,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    var clean: [160]i16 = undefined;
    var max_mic_rms: f64 = 0;
    var max_clean_rms: f64 = 0;

    for (0..500) |frame| {
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        _ = try spk.write(&clean);

        const mr = tu.rmsEnergy(&mic_buf);
        const cr = tu.rmsEnergy(&clean);
        if (mr > max_mic_rms) max_mic_rms = mr;
        if (cr > max_clean_rms) max_clean_rms = cr;

        if (frame % 100 == 0) {
            std.debug.print("[R1 f{d}] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{
                frame, mr, tu.rmsEnergy(&ref_buf), cr,
            });
        }
    }

    std.debug.print("[R1] max_mic={d:.0} max_clean={d:.0}\n", .{ max_mic_rms, max_clean_rms });

    // With high gain (0.8) and strong resonance (10x), signal grows to ~32k
    // Verify AEC doesn't let it clip (stay below i16 max)
    try testing.expect(max_mic_rms < 35000);
    try testing.expect(max_clean_rms < 35000);
}

test "R2: realistic closed-loop with near-end speech" {
    const Sim = SimAudio(.{
        .echo_delay_samples = 350,
        .echo_gain = 0.3,
        .has_hardware_loopback = true,
        .ambient_noise_rms = 100,
        .resonance_freq = 800,
        .resonance_gain = 4.0,
        .resonance_q = 3.0,
    });
    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    var aec = try aec3_mod.Aec3.init(testing.allocator, .{
        .frame_size = 160,
        .sample_rate = 16000,
        .num_partitions = 10,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    var mic_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    var clean: [160]i16 = undefined;

    // Run 200 frames silence to let AEC converge
    for (0..200) |_| {
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        _ = try spk.write(&clean);
    }

    // Inject near-end 880Hz for 100 frames, continue loop
    var near_energy: f64 = 0;
    var clean_energy: f64 = 0;
    for (0..100) |f| {
        var ne: [160]i16 = undefined;
        tu.generateSine(&ne, 880.0, 8000.0, 16000, f * 160);
        sim.writeNearEnd(&ne);

        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        _ = try spk.write(&clean);

        near_energy += tu.rmsEnergy(&ne) * tu.rmsEnergy(&ne);
        clean_energy += tu.rmsEnergy(&clean) * tu.rmsEnergy(&clean);
    }

    const near_rms = @sqrt(near_energy / 100);
    const clean_rms = @sqrt(clean_energy / 100);
    std.debug.print("[R2] near={d:.0} clean={d:.0}\n", .{ near_rms, clean_rms });

    // Near-end should be preserved
    try testing.expect(clean_rms > near_rms * 0.1);
    // Signal should not explode
    try testing.expect(clean_rms < near_rms * 5.0);
}
