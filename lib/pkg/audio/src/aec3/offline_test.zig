//! 离线 AEC 测试 - 使用实际音频文件

const std = @import("std");
const aec3 = @import("aec3");

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

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

fn rms(buf: []const i16) f64 {
    var sum: f64 = 0;
    for (buf) |s| {
        const v: f64 = @floatFromInt(s);
        sum += v * v;
    }
    return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== AEC3 Offline Test with Real Audio ===\n\n", .{});

    const mic_data = try loadWav("/tmp/diag_mic.wav", allocator);
    defer allocator.free(mic_data);
    const ref_data = try loadWav("/tmp/diag_ref.wav", allocator);
    defer allocator.free(ref_data);

    std.debug.print("Loaded: mic={d} samples, ref={d} samples\n", .{ mic_data.len, ref_data.len });

    const n_samples = @min(mic_data.len, ref_data.len);
    const n_frames = n_samples / FRAME_SIZE;

    var aec = try aec3.aec3.Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
    });
    defer aec.deinit();

    const clean_data = try allocator.alloc(i16, n_samples);
    defer allocator.free(clean_data);

    std.debug.print("\nProcessing {d} frames...\n", .{n_frames});

    for (0..n_frames) |f| {
        const offset = f * FRAME_SIZE;
        const mic_frame = mic_data[offset..][0..FRAME_SIZE];
        const ref_frame = ref_data[offset..][0..FRAME_SIZE];
        const clean_frame = clean_data[offset..][0..FRAME_SIZE];

        aec.process(mic_frame, ref_frame, clean_frame);

        if (f < 5 or f % 100 == 0) {
            const mr = rms(mic_frame);
            const rr = rms(ref_frame);
            const cr = rms(clean_frame);
            const erle = if (cr > 1) 20.0 * @log10(mr / cr) else 60.0;
            std.debug.print("frame {d:>4}: mic={d:>8.1} ref={d:>8.1} clean={d:>8.1} ERLE={d:>5.1}dB\n", .{
                f, mr, rr, cr, erle,
            });
        }
    }

    try writeWav("/tmp/diag_clean.wav", clean_data[0 .. n_frames * FRAME_SIZE]);

    // 计算总体统计
    const total_mic_rms = rms(mic_data[0..(n_frames * FRAME_SIZE)]);
    const total_ref_rms = rms(ref_data[0..(n_frames * FRAME_SIZE)]);
    const total_clean_rms = rms(clean_data[0..(n_frames * FRAME_SIZE)]);

    std.debug.print("\n=== Total Results ===\n", .{});
    std.debug.print("  Ref RMS:   {d:.2}\n", .{total_ref_rms});
    std.debug.print("  Mic RMS:   {d:.2}\n", .{total_mic_rms});
    std.debug.print("  Clean RMS: {d:.2}\n", .{total_clean_rms});

    const total_erle = if (total_clean_rms > 1) 20.0 * @log10(total_mic_rms / total_clean_rms) else 60.0;
    std.debug.print("  Total ERLE: {d:.1f} dB\n", .{total_erle});

    if (total_clean_rms < total_mic_rms * 0.5) {
        std.debug.print("\n✅ AEC is working! Echo reduced by {d:.1f}%\n", .{(1.0 - total_clean_rms / total_mic_rms) * 100.0});
    } else {
        std.debug.print("\n⚠️  AEC not effective\n", .{});
    }

    std.debug.print("\nSaved: /tmp/diag_clean.wav\n\n", .{});
}
