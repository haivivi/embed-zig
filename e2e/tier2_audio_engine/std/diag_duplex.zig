//! Diagnostic: verify DuplexAudio mic/ref frame pairing
//!
//! Plays a 440Hz tone through Speaker. Reads Mic and RefReader frame by frame.
//! For each frame pair, checks if ref has the expected tone content and
//! whether mic/ref frame indices match (no frame skipping or duplication).

const std = @import("std");
const pa = @import("portaudio");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 5;
const TOTAL_FRAMES = SAMPLE_RATE * DURATION_S / FRAME_SIZE;

fn rms(buf: []const i16) f64 {
    var sum: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        sum += v * v;
    }
    return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
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
    std.debug.print("\n=== Diagnostic: DuplexAudio frame pairing ===\n\n", .{});

    try pa.init();
    defer pa.deinit();

    var duplex = try da.DuplexAudio.init(allocator);
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    defer duplex.stop();

    // Speaker thread: write 440Hz tone continuously
    var spk_running = std.atomic.Value(bool).init(true);
    const spk_thread = try std.Thread.spawn(.{}, struct {
        fn run(spk: *da.DuplexAudio.Speaker, running: *std.atomic.Value(bool)) void {
            var phase: usize = 0;
            var buf: [160]i16 = undefined;
            while (running.load(.acquire)) {
                for (&buf, 0..) |*s, i| {
                    const t: f32 = @as(f32, @floatFromInt(phase + i)) / 16000.0;
                    s.* = @intFromFloat(@sin(t * 440.0 * 2.0 * std.math.pi) * 16000.0);
                }
                phase += 160;
                _ = spk.write(&buf) catch break;
            }
        }
    }.run, .{ &spk_drv, &spk_running });

    // Read frame by frame, log per-frame RMS
    const total_samples = SAMPLE_RATE * DURATION_S;
    var mic_all: [total_samples]i16 = undefined;
    var ref_all: [total_samples]i16 = undefined;

    var ref_zero_frames: usize = 0;
    var mic_zero_frames: usize = 0;
    var frame_idx: usize = 0;

    while (frame_idx < TOTAL_FRAMES) {
        var mic_frame: [FRAME_SIZE]i16 = undefined;
        var ref_frame: [FRAME_SIZE]i16 = undefined;

        _ = mic_drv.read(&mic_frame) catch break;
        _ = ref_rdr.read(&ref_frame) catch break;

        const pos = frame_idx * FRAME_SIZE;
        @memcpy(mic_all[pos..][0..FRAME_SIZE], &mic_frame);
        @memcpy(ref_all[pos..][0..FRAME_SIZE], &ref_frame);

        const mr = rms(&mic_frame);
        const rr = rms(&ref_frame);

        if (rr < 10) ref_zero_frames += 1;
        if (mr < 10) mic_zero_frames += 1;

        // Print first 20 frames and every 100th frame
        if (frame_idx < 20 or frame_idx % 100 == 0) {
            std.debug.print("frame {d:>4}: mic_rms={d:>8.1} ref_rms={d:>8.1}\n", .{
                frame_idx, mr, rr,
            });
        }

        frame_idx += 1;
    }

    spk_running.store(false, .release);
    spk_thread.join();

    std.debug.print("\nTotal frames: {d}\n", .{frame_idx});
    std.debug.print("Ref zero-energy frames: {d}\n", .{ref_zero_frames});
    std.debug.print("Mic zero-energy frames: {d}\n", .{mic_zero_frames});

    // Save WAVs
    const n = frame_idx * FRAME_SIZE;
    try writeWav("/tmp/diag_mic.wav", mic_all[0..n]);
    try writeWav("/tmp/diag_ref.wav", ref_all[0..n]);
    std.debug.print("Saved: /tmp/diag_mic.wav, /tmp/diag_ref.wav\n\n", .{});
}
