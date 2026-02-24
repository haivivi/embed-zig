//! AEC Closed-Loop Test with SimAudio + AEC
//!
//! Simplified version that works - uses manual AEC.process() call

const std = @import("std");
const testing = std.testing;
const sim_audio = @import("sim_audio.zig");
const aec3_module = @import("aec3/aec3.zig");

const SimAudio = sim_audio.SimAudio;

const FRAME_SIZE: u32 = 160;
const SAMPLE_RATE: u32 = 16000;
const TTS_PATH = "/tmp/tts_input.wav";

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
        const bytes_read = try self.file.readAll(byte_buf[0..bytes_to_read]);
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

test "AEC Closed-Loop: SimAudio + AEC" {
    const allocator = testing.allocator;

    const SimA = SimAudio(.{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = 320,
        .echo_gain = 0.5,
        .has_hardware_loopback = true,
        .ambient_noise_rms = 0,
        .resonance_freq = 0,
    });

    var sim = SimA.init();
    try sim.start();
    defer sim.stop();

    var aec = try aec3_module.Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .num_partitions = 64,
        .step_size = 0.1,
        .regularization = 1000,
    });
    defer aec.deinit();

    var wav_reader = WavReader.init(TTS_PATH) catch |err| {
        std.debug.print("\n[ERROR] Cannot open TTS: {s}\n", .{TTS_PATH});
        return err;
    };
    defer wav_reader.close();

    var input_wav = try WavWriter.init("/tmp/aec_input.wav", SAMPLE_RATE);
    defer input_wav.close();

    var ref_wav = try WavWriter.init("/tmp/aec_ref.wav", SAMPLE_RATE);
    defer ref_wav.close();

    var mic_wav = try WavWriter.init("/tmp/aec_mic.wav", SAMPLE_RATE);
    defer mic_wav.close();

    var clean_wav = try WavWriter.init("/tmp/aec_clean.wav", SAMPLE_RATE);
    defer clean_wav.close();

    var tts_buf: [160]i16 = undefined;
    var ref_buf: [160]i16 = undefined;
    var mic_buf: [160]i16 = undefined;
    var clean_buf: [160]i16 = undefined;

    var spk = sim.speaker();
    var ref_rdr = sim.refReader();
    var mic_drv = sim.mic();

    var frame_idx: usize = 0;

    std.debug.print("[AEC Closed-Loop] Starting...\n", .{});

    while (frame_idx < 400) {
        const samples_read = try wav_reader.readFrames(&tts_buf);
        if (samples_read == 0) break;

        sim.writeNearEnd(&tts_buf);
        _ = spk.write(&tts_buf) catch continue;
        input_wav.writeSamples(&tts_buf) catch break;

        std.Thread.sleep(5 * std.time.ns_per_ms);

        _ = ref_rdr.read(&ref_buf) catch continue;
        ref_wav.writeSamples(&ref_buf) catch break;

        _ = mic_drv.read(&mic_buf) catch continue;
        mic_wav.writeSamples(&mic_buf) catch break;

        aec.process(&mic_buf, &ref_buf, &clean_buf);
        clean_wav.writeSamples(&clean_buf) catch break;

        frame_idx += 1;
        if (frame_idx % 50 == 0) {
            std.debug.print("  [{d:4}] input={d:6.0} ref={d:6.0} mic={d:6.0} clean={d:6.0}\n", .{
                frame_idx,
                rms(&tts_buf),
                rms(&ref_buf),
                rms(&mic_buf),
                rms(&clean_buf),
            });
        }
    }

    std.debug.print("\n[AEC Closed-Loop] Complete! {d} frames\n", .{frame_idx});
    std.debug.print("  Output: /tmp/aec_*.wav\n", .{});
}

fn rms(buf: []const i16) f64 {
    var sum: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        sum += v * v;
    }
    return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
}
