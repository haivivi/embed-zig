//! E2: AudioEngine TTS — play TTS through engine, verify AEC removes it from clean
//!
//! Uses AudioEngine.createTrack to play TTS. readClean() should NOT contain TTS.
//! Saves clean.wav for verification.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const Rt = @import("std_impl").runtime;
const Mixer = audio.mixer.Mixer(Rt);
const Format = audio.resampler.Format;
const Engine = audio.engine.AudioEngine(Rt, MicDriver, SpeakerDriver);

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

const MicDriver = struct {
    stream: pa.InputStream(i16),
    pub fn init() !MicDriver {
        var s = try pa.InputStream(i16).open(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE });
        try s.start();
        return .{ .stream = s };
    }
    pub fn deinit(self: *MicDriver) void { self.stream.stop() catch {}; self.stream.close(); }
    pub fn read(self: *MicDriver, buf: []i16) !usize { try self.stream.read(buf); return buf.len; }
};

const SpeakerDriver = struct {
    stream: pa.OutputStream(i16),
    pub fn init() !SpeakerDriver {
        var s = try pa.OutputStream(i16).open(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE });
        try s.start();
        return .{ .stream = s };
    }
    pub fn deinit(self: *SpeakerDriver) void { self.stream.stop() catch {}; self.stream.close(); }
    pub fn write(self: *SpeakerDriver, buf: []const i16) !usize { try self.stream.write(buf); return buf.len; }
};

fn loadWav(path: []const u8, allocator: std.mem.Allocator) ![]i16 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    var header: [44]u8 = undefined;
    _ = try file.read(&header);
    const buf = try allocator.alloc(i16, (stat.size - 44) / 2);
    const bytes = std.mem.sliceAsBytes(buf);
    var total: usize = 0;
    while (total < bytes.len) {
        const n = try file.read(bytes[total..]);
        if (n == 0) break;
        total += n;
    }
    return buf;
}

fn writeWav(path: []const u8, samples: []const i16) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const data_size: u32 = @intCast(samples.len * 2);
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_size, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little);
    std.mem.writeInt(u16, hdr[22..24], 1, .little);
    std.mem.writeInt(u32, hdr[24..28], SAMPLE_RATE, .little);
    std.mem.writeInt(u32, hdr[28..32], SAMPLE_RATE * 2, .little);
    std.mem.writeInt(u16, hdr[32..34], 2, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_size, .little);
    try file.writeAll(&hdr);
    try file.writeAll(std.mem.sliceAsBytes(samples));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== E2: AudioEngine TTS — verify AEC removes TTS from clean ===\n\n", .{});

    const tts_data = loadWav("/tmp/tts_ref.wav", allocator) catch {
        std.debug.print("ERROR: /tmp/tts_ref.wav not found.\n", .{});
        return;
    };
    defer allocator.free(tts_data);
    std.debug.print("TTS: {d} samples ({d:.1}s)\n", .{ tts_data.len, @as(f64, @floatFromInt(tts_data.len)) / 16000.0 });

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var mic_drv = try MicDriver.init();
    defer mic_drv.deinit();
    var spk_drv = try SpeakerDriver.init();
    defer spk_drv.deinit();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, .{
        .enable_aec = true,
        .enable_ns = true,
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
    });
    defer engine.deinit();

    // Write TTS to a track → mixer → speaker
    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };
    const h = try engine.createTrack(.{ .label = "tts" });
    try h.track.write(format, tts_data);
    h.ctrl.closeWrite();

    try engine.start();
    std.debug.print("Playing TTS through Engine...\n\n", .{});

    // Read clean audio in a separate thread (engine.readClean blocks)
    const total_samples = tts_data.len + SAMPLE_RATE * 2;
    const clean_buf = try allocator.alloc(i16, total_samples);
    defer allocator.free(clean_buf);

    const ReadState = struct {
        eng: *Engine,
        buf: []i16,
        pos: usize = 0,
        max: usize,
    };
    var rs = ReadState{ .eng = &engine, .buf = clean_buf, .max = total_samples };

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(state: *ReadState) void {
            var frame: [160]i16 = undefined;
            while (state.pos < state.max) {
                const n = state.eng.readClean(&frame) orelse break;
                const to_copy = @min(n, state.max - state.pos);
                @memcpy(state.buf[state.pos..][0..to_copy], frame[0..to_copy]);
                state.pos += to_copy;
            }
        }
    }.run, .{&rs});

    // Wait for TTS duration + 3s tail, then stop
    const wait_ms = tts_data.len * 1000 / SAMPLE_RATE + 3000;
    std.Thread.sleep(@as(u64, wait_ms) * std.time.ns_per_ms);
    engine.stop();
    reader.join();

    const clean_pos = rs.pos;

    std.debug.print("Collected {d} clean samples ({d:.1}s)\n", .{
        clean_pos, @as(f64, @floatFromInt(clean_pos)) / 16000.0,
    });

    try writeWav("/tmp/E2_clean.wav", clean_buf[0..clean_pos]);
    std.debug.print("Saved: /tmp/E2_clean.wav\n", .{});
    std.debug.print("Play this file — TTS should be removed, only background noise.\n\n", .{});
}
