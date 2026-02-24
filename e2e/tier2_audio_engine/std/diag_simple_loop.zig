//! Simplest possible AEC loopback — NO Engine, NO mixer, NO tracks.
//!
//! Single loop:
//!   mic.read() → ref_reader.read() → aec3.process() → speaker.write()
//!
//! Records raw mic, ref, and clean to WAV for analysis.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 10;
const TOTAL_SAMPLES = SAMPLE_RATE * DURATION_S;

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

fn rms(buf: []const i16) f64 {
    var sum: f64 = 0;
    for (buf) |s| { const v: f64 = @floatFromInt(s); sum += v * v; }
    return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== AEC Loop + Record (no Engine) ===\n", .{});
    std.debug.print("mic → AEC → speaker. Recording mic/ref/clean. {d}s.\n", .{DURATION_S});
    std.debug.print("Stay quiet!\n\n", .{});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var duplex = try da.DuplexAudio.init(allocator);
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    var aec3 = try audio.aec3.aec3.Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .comfort_noise_rms = 0,
    });
    defer aec3.deinit();

    defer duplex.stop();

    // Wait a moment for offset to be measured
    std.Thread.sleep(100 * std.time.ns_per_ms);
    std.debug.print("Measured ref offset: {d} samples ({d:.1}ms)\n\n", .{
        duplex.getRefOffset(),
        @as(f64, @floatFromInt(duplex.getRefOffset())) / 16.0,
    });

    var mic_all: [TOTAL_SAMPLES]i16 = undefined;
    var ref_all: [TOTAL_SAMPLES]i16 = undefined;
    var clean_all: [TOTAL_SAMPLES]i16 = undefined;

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean: [FRAME_SIZE]i16 = undefined;

    var pos: usize = 0;
    var frame: usize = 0;

    while (pos < TOTAL_SAMPLES) {
        _ = mic_drv.read(&mic_buf) catch continue;
        _ = ref_rdr.read(&ref_buf) catch continue;

        aec3.process(&mic_buf, &ref_buf, &clean);

        _ = spk_drv.write(&clean) catch continue;

        const n = @min(FRAME_SIZE, TOTAL_SAMPLES - pos);
        @memcpy(mic_all[pos..][0..n], mic_buf[0..n]);
        @memcpy(ref_all[pos..][0..n], ref_buf[0..n]);
        @memcpy(clean_all[pos..][0..n], clean[0..n]);
        pos += n;
        frame += 1;

        if (frame % 100 == 0) {
            std.debug.print("[{d}s] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{
                frame / 100, rms(&mic_buf), rms(&ref_buf), rms(&clean),
            });
        }
    }

    try writeWav("/tmp/loop_mic.wav", mic_all[0..pos]);
    try writeWav("/tmp/loop_ref.wav", ref_all[0..pos]);
    try writeWav("/tmp/loop_clean.wav", clean_all[0..pos]);
    std.debug.print("\nSaved: /tmp/loop_mic.wav, /tmp/loop_ref.wav, /tmp/loop_clean.wav\n\n", .{});
}
