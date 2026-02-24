//! Diagnostic: measure exact mic/ref offset with known tone.
//!
//! Plays 440Hz through speaker via DuplexAudio, records mic and ref.
//! No AEC, no feedback. Then analyzes cross-correlation at various lags
//! to find the exact offset between ref and mic echo.

const std = @import("std");
const pa = @import("portaudio");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 3;
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("\n=== Offset Measurement: 440Hz tone, no AEC ===\n\n", .{});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var duplex = try da.DuplexAudio.init(allocator);
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    defer duplex.stop();

    // Wait for offset measurement
    std.Thread.sleep(100 * std.time.ns_per_ms);
    const measured_offset = duplex.getRefOffset();
    std.debug.print("PortAudio measured offset: {d} samples ({d:.1}ms)\n\n", .{
        measured_offset,
        @as(f64, @floatFromInt(measured_offset)) / 16.0,
    });

    // Speaker thread: write 440Hz tone
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

    // Record mic and ref
    var mic_all: [TOTAL_SAMPLES]i16 = undefined;
    var ref_all: [TOTAL_SAMPLES]i16 = undefined;
    var pos: usize = 0;

    while (pos < TOTAL_SAMPLES) {
        var mic_frame: [FRAME_SIZE]i16 = undefined;
        var ref_frame: [FRAME_SIZE]i16 = undefined;
        _ = mic_drv.read(&mic_frame) catch break;
        _ = ref_rdr.read(&ref_frame) catch break;

        const n = @min(FRAME_SIZE, TOTAL_SAMPLES - pos);
        @memcpy(mic_all[pos..][0..n], mic_frame[0..n]);
        @memcpy(ref_all[pos..][0..n], ref_frame[0..n]);
        pos += n;
    }

    spk_running.store(false, .release);
    spk_thread.join();

    std.debug.print("Recorded {d} samples.\n\n", .{pos});

    // Skip first 0.5s (let things stabilize), analyze last 2s
    const skip = SAMPLE_RATE / 2;
    const mic_data = mic_all[skip..pos];
    const ref_data = ref_all[skip..pos];
    const n = @min(mic_data.len, ref_data.len);

    // Compute energies
    var mic_e: f64 = 0;
    var ref_e: f64 = 0;
    for (0..n) |i| {
        const mv: f64 = @floatFromInt(mic_data[i]);
        const rv: f64 = @floatFromInt(ref_data[i]);
        mic_e += mv * mv;
        ref_e += rv * rv;
    }

    var mic_rms = @sqrt(mic_e / @as(f64, @floatFromInt(n)));
    var ref_rms = @sqrt(ref_e / @as(f64, @floatFromInt(n)));
    std.debug.print("mic_rms={d:.0} ref_rms={d:.0}\n\n", .{ mic_rms, ref_rms });
    _ = &mic_rms;
    _ = &ref_rms;

    // Cross-correlation at many lags
    std.debug.print("Cross-correlation (lag → normalized corr):\n", .{});
    std.debug.print("Searching lag -500 to +1000 in steps of 10...\n", .{});

    var best_corr: f64 = -2;
    var best_lag: i32 = 0;

    var lag: i32 = -500;
    while (lag <= 1000) : (lag += 10) {
        var corr: f64 = 0;
        for (0..n) |i| {
            const j: i64 = @as(i64, @intCast(i)) + lag;
            if (j >= 0 and j < n) {
                const mv: f64 = @floatFromInt(mic_data[@intCast(j)]);
                const rv: f64 = @floatFromInt(ref_data[i]);
                corr += mv * rv;
            }
        }
        const norm = corr / @sqrt(mic_e * ref_e);
        if (@abs(norm) > @abs(best_corr)) {
            best_corr = norm;
            best_lag = lag;
        }
        // Print notable values
        if (@abs(norm) > 0.5) {
            std.debug.print("  lag={d:>5}: {d:.4} ***\n", .{ lag, norm });
        }
    }

    // Fine search around best lag
    std.debug.print("\nFine search around lag={d} (±20, step 1):\n", .{best_lag});
    var fine_best_corr: f64 = -2;
    var fine_best_lag: i32 = 0;

    var fine_lag: i32 = best_lag - 20;
    while (fine_lag <= best_lag + 20) : (fine_lag += 1) {
        var corr: f64 = 0;
        for (0..n) |i| {
            const j: i64 = @as(i64, @intCast(i)) + fine_lag;
            if (j >= 0 and j < n) {
                const mv: f64 = @floatFromInt(mic_data[@intCast(j)]);
                const rv: f64 = @floatFromInt(ref_data[i]);
                corr += mv * rv;
            }
        }
        const norm = corr / @sqrt(mic_e * ref_e);
        if (@abs(norm) > @abs(fine_best_corr)) {
            fine_best_corr = norm;
            fine_best_lag = fine_lag;
        }
        std.debug.print("  lag={d:>5}: {d:.4}\n", .{ fine_lag, norm });
    }

    std.debug.print("\n=== Result ===\n", .{});
    std.debug.print("PortAudio timeInfo offset: {d} samples ({d:.1}ms)\n", .{
        measured_offset,
        @as(f64, @floatFromInt(measured_offset)) / 16.0,
    });
    std.debug.print("Best cross-correlation:    lag={d} samples ({d:.1}ms), corr={d:.4}\n", .{
        fine_best_lag,
        @as(f64, @floatFromInt(fine_best_lag)) / 16.0,
        fine_best_corr,
    });
    std.debug.print("Difference:                {d} samples\n\n", .{
        fine_best_lag - measured_offset,
    });

    try writeWav("/tmp/offset_mic.wav", mic_all[0..pos]);
    try writeWav("/tmp/offset_ref.wav", ref_all[0..pos]);
    std.debug.print("Saved: /tmp/offset_mic.wav, /tmp/offset_ref.wav\n\n", .{});
}
