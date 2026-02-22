//! Analyze recorded mic/ref/clean WAVs from diag-loop

const std = @import("std");
const tu = @import("audio").aec3.aec3;

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

fn rms(buf: []const i16) f64 {
    var sum: f64 = 0;
    for (buf) |s| { const v: f64 = @floatFromInt(s); sum += v * v; }
    return @sqrt(sum / @as(f64, @floatFromInt(buf.len)));
}

fn goertzel(samples: []const i16, freq: f64, sr: f64) f64 {
    const n: f64 = @floatFromInt(samples.len);
    const k = @round(freq * n / sr);
    const w = 2.0 * std.math.pi * k / n;
    const coeff = 2.0 * @cos(w);
    var s0: f64 = 0;
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (samples) |sample| {
        s0 = @as(f64, @floatFromInt(sample)) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const mic = try loadWav("/tmp/loop_mic.wav", allocator);
    defer allocator.free(mic);
    const ref = try loadWav("/tmp/loop_ref.wav", allocator);
    defer allocator.free(ref);
    const clean = try loadWav("/tmp/loop_clean.wav", allocator);
    defer allocator.free(clean);

    std.debug.print("\n=== Analysis of loop recordings ===\n\n", .{});
    std.debug.print("Total samples: mic={d} ref={d} clean={d}\n\n", .{ mic.len, ref.len, clean.len });

    // Per-frame analysis for first 150 frames
    const n_frames = @min(150, mic.len / 160);
    std.debug.print("Frame-by-frame analysis ({d} frames):\n", .{n_frames});
    std.debug.print("{s:>5} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{
        "frame", "mic_rms", "ref_rms", "cln_rms", "mic_max", "ref_max", "cln_max", "cln/mic",
    });
    for (0..n_frames) |f| {
        const start = f * 160;
        if (start + 160 > mic.len) break;
        const mic_frame = mic[start..][0..160];
        const ref_frame = ref[start..][0..160];
        const cln_frame = clean[start..][0..160];
        const mr = rms(mic_frame);
        const rr = rms(ref_frame);
        const cr = rms(cln_frame);
        var mic_max: i16 = 0;
        var ref_max: i16 = 0;
        var cln_max: i16 = 0;
        for (mic_frame) |s| { if (s > mic_max or -s > mic_max) mic_max = if (s < 0) -s else s; }
        for (ref_frame) |s| { if (s > ref_max or -s > ref_max) ref_max = if (s < 0) -s else s; }
        for (cln_frame) |s| { if (s > cln_max or -s > cln_max) cln_max = if (s < 0) -s else s; }
        const ratio = if (mr > 1) cr / mr else 0;
        std.debug.print("{d:>5} {d:>8.0} {d:>8.0} {d:>8.0} {d:>8} {d:>8} {d:>8} {d:>8.3}\n", .{
            f, mr, rr, cr, mic_max, ref_max, cln_max, ratio,
        });
    }

    // First 20 samples of each
    std.debug.print("\nFirst 20 samples:\n", .{});
    std.debug.print("{s:>5} {s:>8} {s:>8} {s:>8}\n", .{ "i", "mic", "ref", "clean" });
    for (0..20) |i| {
        std.debug.print("{d:>5} {d:>8} {d:>8} {d:>8}\n", .{ i, mic[i], ref[i], clean[i] });
    }

    // Frequency analysis on 1-second chunks
    std.debug.print("\nFrequency analysis (Goertzel, per-second chunks):\n", .{});
    const freqs = [_]f64{ 100, 200, 500, 1000, 2000, 4000 };
    for (0..@min(5, mic.len / 16000)) |s| {
        const start = s * 16000;
        const chunk = mic[start..][0..16000];
        std.debug.print("\n[mic sec {d}] rms={d:.0}\n", .{ s + 1, rms(chunk) });
        for (freqs) |freq| {
            const power = goertzel(chunk, freq, 16000.0);
            const db: f64 = if (power > 1) 10.0 * @log10(power) else -100;
            std.debug.print("  {d:>5.0}Hz: {d:.1}dB\n", .{ freq, db });
        }
    }

    // Cross-correlation mic vs ref at various lags
    std.debug.print("\nCross-correlation mic vs ref:\n", .{});
    const lags = [_]i32{ 0, 10, 20, 40, 80, 160, 320 };
    var mic_e: f64 = 0;
    var ref_e: f64 = 0;
    for (0..@min(mic.len, ref.len)) |i| {
        const mv: f64 = @floatFromInt(mic[i]);
        const rv: f64 = @floatFromInt(ref[i]);
        mic_e += mv * mv;
        ref_e += rv * rv;
    }
    for (lags) |lag| {
        var corr: f64 = 0;
        const n = @min(mic.len, ref.len);
        for (0..n) |i| {
            const j: i64 = @as(i64, @intCast(i)) + lag;
            if (j >= 0 and j < n) {
                const mv: f64 = @floatFromInt(mic[@intCast(j)]);
                const rv: f64 = @floatFromInt(ref[i]);
                corr += mv * rv;
            }
        }
        const norm = corr / @sqrt(mic_e * ref_e);
        std.debug.print("  lag={d:>4}: {d:.4}\n", .{ lag, norm });
    }
}
