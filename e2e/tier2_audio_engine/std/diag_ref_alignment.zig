//! Diagnostic: Compare ref and mic alignment in feedback loop
//!
//! Hypothesis: RefReader returns ref that is NOT aligned with mic's echo.
//! If ref_delay_samples is wrong, AEC cannot cancel the echo.
//!
//! Test: Run feedback loop, save mic and ref, analyze cross-correlation
//! to find the ACTUAL delay between mic echo and ref.

const std = @import("std");
const pa = @import("portaudio");
const wav = @import("wav_writer");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 3;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("\n=== Ref Alignment Diagnostic ===\n", .{});
    std.debug.print("Testing if RefReader returns correctly aligned ref.\n\n", .{});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var duplex = try da.DuplexAudio.init(allocator);
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    std.Thread.sleep(100 * std.time.ns_per_ms);

    const offset = duplex.getRefOffset();
    std.debug.print("PortAudio hardware offset: {d} samples ({d:.1}ms)\n", .{ offset, @as(f64, @floatFromInt(offset)) / 16.0 });
    std.debug.print("RefReader uses delay: {d} samples ({d:.1}ms)\n\n", .{ 160 + offset, @as(f64, @floatFromInt(160 + offset)) / 16.0 });

    // Play white noise through speaker, record mic and ref
    std.debug.print("Playing white noise, recording mic and ref...\n\n", .{});

    var prng = std.Random.DefaultPrng.init(42);
    const total_samples = SAMPLE_RATE * DURATION_S;
    var mic_all: []i16 = try std.heap.page_allocator.alloc(i16, total_samples);
    defer std.heap.page_allocator.free(mic_all);
    var ref_all: []i16 = try std.heap.page_allocator.alloc(i16, total_samples);
    defer std.heap.page_allocator.free(ref_all);

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var noise_buf: [FRAME_SIZE]i16 = undefined;
    var pos: usize = 0;

    const deadline = std.time.milliTimestamp() + DURATION_S * 1000;

    // First second: silence to let things stabilize
    var silence_buf: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE;
    const warmup = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < warmup) {
        _ = mic_drv.read(&mic_buf) catch continue;
        _ = ref_rdr.read(&ref_buf) catch continue;
        _ = spk_drv.write(&silence_buf) catch continue;
    }

    // Generate white noise
    for (&noise_buf) |*s| {
        s.* = @intFromFloat(@as(f32, @floatFromInt(prng.random().int(i16))) * 0.3); // 30% volume
    }

    while (std.time.milliTimestamp() < deadline and pos < total_samples) {
        _ = mic_drv.read(&mic_buf) catch continue;
        _ = ref_rdr.read(&ref_buf) catch continue;
        _ = spk_drv.write(&noise_buf) catch continue; // Play same noise repeatedly

        const n = @min(FRAME_SIZE, total_samples - pos);
        @memcpy(mic_all[pos..][0..n], mic_buf[0..n]);
        @memcpy(ref_all[pos..][0..n], ref_buf[0..n]);
        pos += n;
    }

    duplex.stop();

    std.debug.print("Recorded {d} samples.\n\n", .{pos});

    // Save WAV files
    var mic_wav = try wav.WavWriter.init("diag_align_mic.wav", SAMPLE_RATE);
    var ref_wav = try wav.WavWriter.init("diag_align_ref.wav", SAMPLE_RATE);
    for (0..pos) |i| {
        const frame: [1]i16 = .{mic_all[i]};
        try mic_wav.writeSamples(&frame);
        try ref_wav.writeSamples(&.{ref_all[i]});
    }
    try mic_wav.close();
    try ref_wav.close();

    // Compute cross-correlation at many lags
    std.debug.print("Cross-correlation analysis:\n", .{});
    std.debug.print("If ref is correctly aligned, correlation should peak near lag=0.\n", .{});
    std.debug.print("If peak is far from 0, RefReader delay is wrong.\n\n", .{});

    // Skip first 0.5s for stability
    const skip = SAMPLE_RATE / 2;
    const data_len = pos - skip;

    // Compute energies
    var mic_e: f64 = 0;
    var ref_e: f64 = 0;
    for (0..data_len) |i| {
        const mv: f64 = @floatFromInt(mic_all[skip + i]);
        const rv: f64 = @floatFromInt(ref_all[skip + i]);
        mic_e += mv * mv;
        ref_e += rv * rv;
    }

    std.debug.print("mic_rms = {d:.0}, ref_rms = {d:.0}\n\n", .{
        @sqrt(mic_e / @as(f64, @floatFromInt(data_len))),
        @sqrt(ref_e / @as(f64, @floatFromInt(data_len))),
    });

    // Search lags from -500 to +500
    var best_corr: f64 = 0;
    var best_lag: i32 = 0;

    std.debug.print("Lag search (-500 to +500, step 10):\n", .{});
    var lag: i32 = -500;
    while (lag <= 500) : (lag += 10) {
        var corr: f64 = 0;
        for (0..data_len) |i| {
            const j: i64 = @as(i64, @intCast(i)) + lag;
            if (j >= 0 and j < data_len) {
                const mv: f64 = @floatFromInt(mic_all[skip + @as(usize, @intCast(j))]);
                const rv: f64 = @floatFromInt(ref_all[skip + i]);
                corr += mv * rv;
            }
        }
        const norm = corr / @sqrt(mic_e * ref_e);
        if (@abs(norm) > @abs(best_corr)) {
            best_corr = norm;
            best_lag = lag;
        }
        if (@abs(norm) > 0.3) {
            std.debug.print("  lag={d:>5}: {d:.4}\n", .{ lag, norm });
        }
    }

    // Fine search
    std.debug.print("\nFine search around lag={d}:\n", .{best_lag});
    var fine_lag: i32 = best_lag - 20;
    while (fine_lag <= best_lag + 20) : (fine_lag += 1) {
        var corr: f64 = 0;
        for (0..data_len) |i| {
            const j: i64 = @as(i64, @intCast(i)) + fine_lag;
            if (j >= 0 and j < data_len) {
                const mv: f64 = @floatFromInt(mic_all[skip + @as(usize, @intCast(j))]);
                const rv: f64 = @floatFromInt(ref_all[skip + i]);
                corr += mv * rv;
            }
        }
        const norm = corr / @sqrt(mic_e * ref_e);
        if (@abs(norm) > @abs(best_corr)) {
            best_corr = norm;
            best_lag = fine_lag;
        }
        if (@abs(norm) > 0.3) {
            std.debug.print("  lag={d:>5}: {d:.4}\n", .{ fine_lag, norm });
        }
    }

    std.debug.print("\n=== Result ===\n", .{});
    std.debug.print("Best correlation: lag={d} samples ({d:.1}ms), corr={d:.4}\n", .{
        best_lag,
        @as(f64, @floatFromInt(best_lag)) / 16.0,
        best_corr,
    });
    std.debug.print("RefReader delay:   {d} samples ({d:.1}ms)\n", .{
        160 + offset,
        @as(f64, @floatFromInt(160 + offset)) / 16.0,
    });

    if (@abs(best_lag) < 50) {
        std.debug.print("\n✓ ref appears ALIGNED with mic (lag near 0)\n", .{});
    } else {
        std.debug.print("\n✗ ref is MISALIGNED! Need to adjust RefReader delay by {d} samples.\n", .{best_lag});
        std.debug.print("  Suggested delay: {d} samples instead of {d}\n", .{ 160 + offset - best_lag, 160 + offset });
    }

    std.debug.print("\nSaved: diag_align_mic.wav, diag_align_ref.wav\n\n", .{});
}
