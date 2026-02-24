//! AudioEngine Closed-Loop WAV Test (Correct Version)
//!
//! 正确的闭环流程：
//! 1. TTS 是近端语音，注入给麦克风
//! 2. 麦克风 = TTS + echo(clean延迟)
//! 3. AEC.process(mic, ref) → clean
//! 4. clean → track → speaker
//! 5. speaker声音 → echo → 回传麦克风 + 作为 ref 给 AEC
//!
//! 这样形成闭环，验证 AEC 是否能防止正反馈。
//!
//! 生成4个 WAV 文件：
//! - input.wav: 近端语音 (TTS)
//! - ref.wav: 参考信号 (speaker 播放的声音 = clean)
//! - mic.wav: 麦克风捕获 (echo + near-end)
//! - clean.wav: AEC 输出 (near-end preserved, echo removed)

const std = @import("std");
const sim_audio = @import("sim_audio.zig");
const engine_mod = @import("engine.zig");
const resampler_mod = @import("resampler.zig");
const TestRt = @import("std_impl").runtime;

const FRAME_SIZE: u32 = 160;
const SAMPLE_RATE: u32 = 16000;
const TTS_PATH = "/tmp/tts_input.wav";

// ============================================================================
// WAV I/O utilities
// ============================================================================

const WavHeader = extern struct {
    riff: [4]u8 = "RIFF".*,
    file_size: u32,
    wave: [4]u8 = "WAVE".*,
    fmt: [4]u8 = "fmt ".*,
    fmt_size: u32 = 16,
    audio_format: u16 = 1,
    num_channels: u16 = 1,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16 = 2,
    bits_per_sample: u16 = 16,
    data: [4]u8 = "data".*,
    data_size: u32,
};

const WavWriter = struct {
    file: std.fs.File,
    sample_rate: u32,
    data_size: u64,
    header_pos: u64,

    pub fn init(path: []const u8, sample_rate: u32) !WavWriter {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        errdefer file.close();

        const header = WavHeader{
            .file_size = 0,
            .sample_rate = sample_rate,
            .byte_rate = sample_rate * 2,
            .data_size = 0,
        };
        const header_pos = try file.getPos();
        try file.writeAll(std.mem.asBytes(&header));

        return WavWriter{
            .file = file,
            .sample_rate = sample_rate,
            .data_size = 0,
            .header_pos = header_pos,
        };
    }

    pub fn writeSamples(self: *WavWriter, samples: []const i16) !void {
        const bytes = std.mem.sliceAsBytes(samples);
        try self.file.writeAll(bytes);
        self.data_size += bytes.len;
    }

    pub fn close(self: *WavWriter) void {
        const file_size = @as(u32, @intCast(self.data_size + 36));
        const data_size = @as(u32, @intCast(self.data_size));

        self.file.seekTo(self.header_pos) catch return;

        const header = WavHeader{
            .file_size = file_size,
            .sample_rate = self.sample_rate,
            .byte_rate = self.sample_rate * 2,
            .data_size = data_size,
        };
        self.file.writeAll(std.mem.asBytes(&header)) catch return;

        self.file.close();
    }
};

const WavReader = struct {
    file: std.fs.File,
    data_remaining: usize,

    pub fn init(path: []const u8) !WavReader {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        var riff_id: [4]u8 = undefined;
        var riff_size: u32 = undefined;
        var wave_id: [4]u8 = undefined;
        _ = try file.readAll(&riff_id);
        _ = try file.readAll(std.mem.asBytes(&riff_size));
        _ = try file.readAll(&wave_id);

        if (!std.mem.eql(u8, &riff_id, "RIFF") or !std.mem.eql(u8, &wave_id, "WAVE")) {
            return error.InvalidWavFile;
        }

        var data_size: usize = 0;
        while (true) {
            var chunk_id: [4]u8 = undefined;
            var chunk_size: u32 = undefined;
            const bytes_read = try file.readAll(&chunk_id);
            if (bytes_read < 4) break;
            _ = try file.readAll(std.mem.asBytes(&chunk_size));

            if (std.mem.eql(u8, &chunk_id, "data")) {
                data_size = chunk_size;
                break;
            } else {
                try file.seekBy(@intCast(chunk_size));
            }
        }

        return WavReader{
            .file = file,
            .data_remaining = data_size,
        };
    }

    pub fn readFrames(self: *WavReader, buf: []i16) !usize {
        if (self.data_remaining == 0) return 0;

        const to_read = @min(buf.len, self.data_remaining / 2);
        const bytes_to_read = to_read * 2;

        var byte_buf: [4096]u8 = undefined;
        const bytes_to_read_actual = @min(bytes_to_read, byte_buf.len);
        const bytes_read = try self.file.readAll(byte_buf[0..bytes_to_read_actual]);
        const samples_read = bytes_read / 2;

        for (0..samples_read) |i| {
            const lo = byte_buf[i * 2];
            const hi = byte_buf[i * 2 + 1];
            buf[i] = @as(i16, lo) | (@as(i16, hi) << 8);
        }

        for (samples_read..buf.len) |i| {
            buf[i] = 0;
        }

        self.data_remaining -= bytes_read;
        return samples_read;
    }

    pub fn close(self: *WavReader) void {
        self.file.close();
    }
};

// ============================================================================
// Tapped drivers - capture signals while Engine processes them
// ============================================================================

const TapBuffer = struct {
    mutex: std.Thread.Mutex,
    data: []i16,
    write_pos: usize,
    capacity: usize,
    overflow: bool,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !TapBuffer {
        return TapBuffer{
            .mutex = .{},
            .data = try allocator.alloc(i16, capacity),
            .write_pos = 0,
            .capacity = capacity,
            .overflow = false,
        };
    }

    pub fn deinit(self: *TapBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn write(self: *TapBuffer, samples: []const i16) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (samples) |s| {
            if (self.write_pos < self.capacity) {
                self.data[self.write_pos] = s;
                self.write_pos += 1;
            } else {
                self.overflow = true;
                break;
            }
        }
    }

    pub fn readAll(self: *TapBuffer, out: []i16) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const to_copy = @min(out.len, self.write_pos);
        @memcpy(out[0..to_copy], self.data[0..to_copy]);
        return to_copy;
    }

    pub fn len(self: *const TapBuffer) usize {
        return self.write_pos;
    }
};

fn TappedMic(comptime BaseMic: type) type {
    return struct {
        base: *BaseMic,
        tap: *TapBuffer,

        pub fn read(self: *@This(), buf: []i16) !usize {
            const n = try self.base.read(buf);
            if (n > 0) {
                self.tap.write(buf[0..n]);
            }
            return n;
        }
    };
}

fn TappedRefReader(comptime BaseRef: type) type {
    return struct {
        base: *BaseRef,
        tap: *TapBuffer,

        pub fn read(self: *@This(), buf: []i16) !usize {
            const n = try self.base.read(buf);
            if (n > 0) {
                self.tap.write(buf[0..n]);
            }
            return n;
        }
    };
}

// ============================================================================
// Test configuration
// ============================================================================

const SimCfg = sim_audio.SimConfig{
    .frame_size = FRAME_SIZE,
    .sample_rate = SAMPLE_RATE,
    .echo_delay_samples = 320,
    .echo_gain = 0.5,
    .has_hardware_loopback = true,
    .ref_aligned_with_echo = false, // 不对齐模式：Ref 是当前 Speaker，Mic echo 是延迟后的
    .ambient_noise_rms = 0,
    .resonance_freq = 0,
};

const SimA = sim_audio.SimAudio(SimCfg);

const EngCfg: engine_mod.EngineConfig = .{
    .enable_aec = true,
    .enable_ns = false,
    .frame_size = FRAME_SIZE,
    .sample_rate = SAMPLE_RATE,
    .comfort_noise_rms = 0,
    .RefReader = TappedRefReader(SimA.RefReader),
};

// ============================================================================
// RMS calculation
// ============================================================================

fn rms(buf: []const i16) f64 {
    var sum: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        sum += v * v;
    }
    return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
}

// ============================================================================
// Main test
// ============================================================================

test "Engine WAV: closed-loop with AudioEngine pipeline" {
    const allocator = std.testing.allocator;

    // Initialize SimAudio
    var sim = SimA.init();
    try sim.start();
    defer sim.stop();

    // Create base drivers
    var base_mic = sim.mic();
    var base_spk = sim.speaker();
    var base_ref = sim.refReader();

    // Create tap buffers (capture 10 seconds)
    const tap_capacity = SAMPLE_RATE * 10;
    var mic_tap = try TapBuffer.init(allocator, tap_capacity);
    defer mic_tap.deinit(allocator);
    var ref_tap = try TapBuffer.init(allocator, tap_capacity);
    defer ref_tap.deinit(allocator);

    // Create tapped drivers
    var tapped_mic = TappedMic(SimA.Mic){
        .base = &base_mic,
        .tap = &mic_tap,
    };
    var tapped_ref = TappedRefReader(SimA.RefReader){
        .base = &base_ref,
        .tap = &ref_tap,
    };

    // Create AudioEngine with tapped drivers
    const Engine = engine_mod.AudioEngine(TestRt, TappedMic(SimA.Mic), SimA.Speaker, EngCfg);
    var engine = try Engine.init(allocator, &tapped_mic, &base_spk, &tapped_ref);
    defer engine.deinit();

    const format = resampler_mod.Format{ .rate = SAMPLE_RATE, .channels = .mono };

    // Create loopback track: clean → track → speaker → echo → mic
    const loopback = try engine.createTrack(.{ .label = "loopback" });

    // Open TTS input (near-end speech)
    var wav_reader = WavReader.init(TTS_PATH) catch |err| {
        std.debug.print("\n[ERROR] Cannot open TTS: {s}\n", .{TTS_PATH});
        std.debug.print("  Please generate it first with: minimax-tts 'your text' /tmp/tts_input.wav\n", .{});
        return err;
    };

    // Read all TTS into memory first
    const tts_samples = try allocator.alloc(i16, SAMPLE_RATE * 30); // 30 sec max
    defer allocator.free(tts_samples);
    var tts_len: usize = 0;
    while (true) {
        const n = try wav_reader.readFrames(tts_samples[tts_len..]);
        if (n == 0) break;
        tts_len += n;
    }
    wav_reader.close();
    std.debug.print("\n[Engine WAV] TTS: {d} samples ({d:.1}s)\n", .{ tts_len, @as(f64, @floatFromInt(tts_len)) / SAMPLE_RATE });

    // Open WAV writers
    var input_wav = try WavWriter.init("/tmp/engine_input.wav", SAMPLE_RATE);
    defer input_wav.close();
    var clean_wav = try WavWriter.init("/tmp/engine_clean.wav", SAMPLE_RATE);
    defer clean_wav.close();

    // Start engine
    try engine.start();

    std.debug.print("[Engine WAV] Starting closed-loop test...\n", .{});
    std.debug.print("  Correct flow:\n", .{});
    std.debug.print("    TTS (near-end) → mic\n", .{});
    std.debug.print("    mic = TTS + echo(clean)\n", .{});
    std.debug.print("    AEC(mic, ref) → clean\n", .{});
    std.debug.print("    clean → track → speaker → echo → mic\n", .{});
    std.debug.print("    speaker → ref → AEC\n", .{});

    // Frame buffer
    var clean_buf: [FRAME_SIZE]i16 = undefined;

    var frame_idx: usize = 0;
    var clean_energy: f64 = 0;

    // Near-end injection thread: inject TTS to SimAudio
    const tts_ptr = tts_samples[0..tts_len];
    const NearEndThread = struct {
        fn run(s: *SimA, tts: []const i16, wav: *WavWriter, energy: *f64) void {
            var offset: usize = 0;
            while (offset + FRAME_SIZE <= tts.len) {
                var frame: [FRAME_SIZE]i16 = undefined;
                @memcpy(&frame, tts[offset..][0..FRAME_SIZE]);

                // Inject TTS as near-end speech
                s.writeNearEnd(&frame);
                wav.writeSamples(&frame) catch break;
                energy.* += rms(&frame);

                offset += FRAME_SIZE;

                // Wait for one frame duration (10ms at 16kHz)
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
    };

    var ne_energy: f64 = 0;
    const ne_thread = try std.Thread.spawn(.{}, NearEndThread.run, .{ &sim, tts_ptr, &input_wav, &ne_energy });

    // Main loop: read clean from engine, write to loopback track
    while (frame_idx < 500) {
        // Read clean output from engine
        const n = engine.readClean(&clean_buf) orelse break;
        if (n == 0) continue;

        // Write clean to loopback track → speaker → creates echo
        loopback.track.write(format, clean_buf[0..n]) catch break;
        try clean_wav.writeSamples(clean_buf[0..n]);
        clean_energy += rms(clean_buf[0..n]);

        frame_idx += 1;
        if (frame_idx % 50 == 0) {
            std.debug.print("  [{d:4}] frames processed\n", .{frame_idx});
        }
    }

    // Wait for near-end thread to finish
    ne_thread.join();

    // Close loopback track
    loopback.ctrl.closeWrite();

    // Wait a bit for remaining processing
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Stop engine
    engine.stop();

    // Write mic and ref WAVs from tap buffers
    var mic_wav = try WavWriter.init("/tmp/engine_mic.wav", SAMPLE_RATE);
    defer mic_wav.close();
    var ref_wav = try WavWriter.init("/tmp/engine_ref.wav", SAMPLE_RATE);
    defer ref_wav.close();

    const mic_data = try allocator.alloc(i16, mic_tap.len());
    defer allocator.free(mic_data);
    const ref_data = try allocator.alloc(i16, ref_tap.len());
    defer allocator.free(ref_data);

    _ = mic_tap.readAll(mic_data);
    _ = ref_tap.readAll(ref_data);

    try mic_wav.writeSamples(mic_data);
    try ref_wav.writeSamples(ref_data);

    // Calculate statistics
    const avg_input = ne_energy / @as(f64, @floatFromInt(@max(tts_len / FRAME_SIZE, 1)));
    const avg_clean = clean_energy / @as(f64, @floatFromInt(@max(frame_idx, 1)));
    const mic_rms = if (mic_data.len > 0) rms(mic_data) else 0;
    const ref_rms = if (ref_data.len > 0) rms(ref_data) else 0;

    std.debug.print("\n[Engine WAV] Complete! {d} frames\n", .{frame_idx});
    std.debug.print("  Signals:\n", .{});
    std.debug.print("    input (near-end): avg_rms={d:.0}\n", .{avg_input});
    std.debug.print("    ref (speaker):    rms={d:.0} ({d} samples)\n", .{ ref_rms, ref_data.len });
    std.debug.print("    mic (echo+ne):    rms={d:.0} ({d} samples)\n", .{ mic_rms, mic_data.len });
    std.debug.print("    clean (output):   avg_rms={d:.0}\n", .{avg_clean});
    std.debug.print("\n  Output files:\n", .{});
    std.debug.print("    /tmp/engine_input.wav  - near-end speech (TTS)\n", .{});
    std.debug.print("    /tmp/engine_ref.wav    - reference (speaker = clean)\n", .{});
    std.debug.print("    /tmp/engine_mic.wav    - mic capture (echo + near-end)\n", .{});
    std.debug.print("    /tmp/engine_clean.wav  - AEC output\n", .{});

    // AEC verification
    std.debug.print("\n  AEC Verification:\n", .{});
    if (mic_rms > 0 and avg_clean > 0) {
        const echo_reduction_db = 20.0 * @log10(@max(mic_rms, 1.0) / @max(avg_clean, 1.0));
        std.debug.print("    mic_rms={d:.0} clean_rms={d:.0}\n", .{ mic_rms, avg_clean });
        std.debug.print("    echo reduction: {d:.1} dB\n", .{echo_reduction_db});

        if (mic_rms > avg_clean * 1.5) {
            std.debug.print("    ✓ mic_rms > clean_rms - echo is being removed\n", .{});
        } else {
            std.debug.print("    ⚠ mic_rms ≈ clean_rms - AEC may need tuning\n", .{});
        }
    }

    // Verify the system is stable (no runaway feedback)
    if (avg_clean < avg_input * 2.0) {
        std.debug.print("    ✓ System stable - no runaway feedback\n", .{});
    } else {
        std.debug.print("    ⚠ Warning: clean > 2x input - possible feedback issue\n", .{});
    }
}
