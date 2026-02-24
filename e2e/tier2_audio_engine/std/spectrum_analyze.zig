//! FFT Spectrum Analyzer for noise diagnosis
const std = @import("std");
const wav = @import("wav_reader");

const SAMPLE_RATE = 16000;
const FRAME_SIZE = 512;  // FFT size for frequency resolution

// Simple FFT (Cooley-Tukey iterative)
fn fft(samples: []f32, real_out: []f32, imag_out: []f32) void {
    const n = samples.len;
    @memset(real_out, 0);
    @memset(imag_out, 0);

    // Copy input to real
    for (0..n) |i| {
        real_out[i] = samples[i];
    }

    // Bit-reverse permutation
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            const tmp = real_out[i];
            real_out[i] = real_out[j];
            real_out[j] = tmp;
        }
    }

    // Iterative FFT
    var len: usize = 2;
    while (len <= n) {
        const angle = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wlen_real = @cos(angle);
        const wlen_imag = @sin(angle);

        var i: usize = 0;
        while (i < n) {
            var w_real: f32 = 1.0;
            var w_imag: f32 = 0.0;

            for (0..len / 2) |k| {
                const u_real = real_out[i + k];
                const u_imag = imag_out[i + k];
                const v_real = real_out[i + k + len / 2] * w_real - imag_out[i + k + len / 2] * w_imag;
                const v_imag = real_out[i + k + len / 2] * w_imag + imag_out[i + k + len / 2] * w_real;

                real_out[i + k] = u_real + v_real;
                imag_out[i + k] = u_imag + v_imag;
                real_out[i + k + len / 2] = u_real - v_real;
                imag_out[i + k + len / 2] = u_imag - v_imag;

                const next_w_real = w_real * wlen_real - w_imag * wlen_imag;
                const next_w_imag = w_real * wlen_imag + w_imag * wlen_real;
                w_real = next_w_real;
                w_imag = next_w_imag;
            }
            i += len;
        }
        len <<= 1;
    }
}

// Calculate magnitude spectrum
fn magnitudeSpectrum(real: []f32, imag: []f32, mag: []f32) void {
    for (0..mag.len) |i| {
        mag[i] = @sqrt(real[i] * real[i] + imag[i] * imag[i]);
    }
}

// Hann window
fn applyWindow(buf: []f32) void {
    const n = buf.len;
    for (0..n) |i| {
        const hann = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)));
        buf[i] *= hann;
    }
}

// Frequency bands analysis
const Band = struct {
    name: []const u8,
    low_hz: f32,
    high_hz: f32,
    energy: f32 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: spectrum_analyze <file.wav>\n", .{});
        return;
    }

    const filename = args[1];
    var w = try wav.WavReader.init(filename);
    defer w.deinit();

    std.debug.print("\n=== Spectrum Analysis: {s} ===\n", .{filename});
    std.debug.print("Sample rate: {d} Hz, FFT size: {d}\n", .{ SAMPLE_RATE, FRAME_SIZE });
    std.debug.print("Frequency resolution: {d:.1} Hz/bin\n\n", .{@as(f32, @floatFromInt(SAMPLE_RATE)) / @as(f32, @floatFromInt(FRAME_SIZE))});

    // Frequency bands
    var bands = [_]Band{
        .{ .name = "Sub-bass", .low_hz = 20, .high_hz = 60 },
        .{ .name = "Bass", .low_hz = 60, .high_hz = 250 },
        .{ .name = "Low-mid", .low_hz = 250, .high_hz = 500 },
        .{ .name = "Mid", .low_hz = 500, .high_hz = 2000 },
        .{ .name = "High-mid", .low_hz = 2000, .high_hz = 4000 },
        .{ .name = "Presence", .low_hz = 4000, .high_hz = 6000 },
        .{ .name = "Brilliance", .low_hz = 6000, .high_hz = 8000 },
    };

    var buf_i16: [FRAME_SIZE]i16 = undefined;
    var buf_f32: [FRAME_SIZE]f32 = undefined;
    var real: [FRAME_SIZE]f32 = undefined;
    var imag: [FRAME_SIZE]f32 = undefined;
    var mag: [FRAME_SIZE / 2]f32 = undefined;

    // Accumulate spectrum over multiple frames
    var spectrum_sum: [FRAME_SIZE / 2]f32 = std.mem.zeroes([FRAME_SIZE / 2]f32);
    var frame_count: usize = 0;
    const max_frames = 100;  // Analyze first ~3 seconds

    // Skip first few frames (startup)
    for (0..10) |_| {
        _ = try w.readSamples(&buf_i16);
    }

    while (frame_count < max_frames) {
        const n = try w.readSamples(&buf_i16);
        if (n < FRAME_SIZE) break;

        // Convert to float and apply window
        for (0..FRAME_SIZE) |i| {
            buf_f32[i] = @as(f32, @floatFromInt(buf_i16[i]));
        }
        applyWindow(&buf_f32);

        // FFT
        fft(&buf_f32, &real, &imag);
        magnitudeSpectrum(&real, &imag, &mag);

        // Accumulate
        for (0..FRAME_SIZE / 2) |i| {
            spectrum_sum[i] += mag[i];
        }
        frame_count += 1;
    }

    if (frame_count == 0) {
        std.debug.print("No frames read\n", .{});
        return;
    }

    // Average spectrum
    for (0..FRAME_SIZE / 2) |i| {
        spectrum_sum[i] /= @as(f32, @floatFromInt(frame_count));
    }

    // Calculate band energies
    const bin_size = @as(f32, @floatFromInt(SAMPLE_RATE)) / @as(f32, @floatFromInt(FRAME_SIZE));

    for (&bands) |*band| {
        const start_bin: usize = @intFromFloat(band.low_hz / bin_size);
        const end_bin: usize = @intFromFloat(band.high_hz / bin_size);

        var sum: f32 = 0;
        var count: usize = 0;
        for (start_bin..@min(end_bin, FRAME_SIZE / 2)) |i| {
            sum += spectrum_sum[i];
            count += 1;
        }
        band.energy = if (count > 0) sum / @as(f32, @floatFromInt(count)) else 0;
    }

    // Print band analysis
    std.debug.print("=== Frequency Band Energy (Average over {d} frames) ===\n", .{frame_count});
    std.debug.print("{s:>12} {s:>8} - {s:>8}  {s:>12}\n", .{ "Band", "Low(Hz)", "High(Hz)", "Energy" });
    std.debug.print("{s}\n", .{"-" ** 50});

    var total_energy: f32 = 0;
    for (bands) |band| {
        total_energy += band.energy;
    }

    for (bands) |band| {
        const percent = if (total_energy > 0) (band.energy / total_energy) * 100.0 else 0;
        std.debug.print("{s:>12} {d:>8.0} - {d:>8.0}  {d:>10.1} ({d:>5.1}%)\n", .{
            band.name, band.low_hz, band.high_hz, band.energy, percent,
        });
    }

    // Noise type diagnosis
    std.debug.print("\n=== Noise Type Diagnosis ===\n", .{});

    const bass_energy = bands[0].energy + bands[1].energy;  // 20-250 Hz
    const mid_energy = bands[2].energy + bands[3].energy;   // 250-2000 Hz
    const high_energy = bands[4].energy + bands[5].energy + bands[6].energy;  // 2-8 kHz

    std.debug.print("Low energy (20-250 Hz):    {d:.1}\n", .{bass_energy});
    std.debug.print("Mid energy (250-2000 Hz):  {d:.1}\n", .{mid_energy});
    std.debug.print("High energy (2-8 kHz):     {d:.1}\n", .{high_energy});

    // Determine noise type
    if (high_energy > bass_energy * 2 and high_energy > mid_energy * 2) {
        std.debug.print("\nDIAGNOSIS: HIGH-FREQUENCY NOISE (hiss)\n", .{});
        std.debug.print("Possible causes: quantization noise, codec artifacts, aliasing\n", .{});
    } else if (bass_energy > high_energy * 2) {
        std.debug.print("\nDIAGNOSIS: LOW-FREQUENCY NOISE (hum)\n", .{});
        std.debug.print("Possible causes: 50/60Hz power hum, ground loop, mechanical vibration\n", .{});
    } else if (mid_energy > bass_energy and mid_energy > high_energy * 0.5) {
        std.debug.print("\nDIAGNOSIS: BROADBAND NOISE (white noise like)\n", .{});
        std.debug.print("Possible causes: analog noise, microphone self-noise, buffer underrun\n", .{});
    } else {
        std.debug.print("\nDIAGNOSIS: BALANCED NOISE\n", .{});
    }

    // Find peaks in spectrum
    std.debug.print("\n=== Peak Frequencies (Top 5) ===\n", .{});
    var peaks: [5]struct { bin: usize, mag: f32 } = undefined;
    @memset(&peaks, .{ .bin = 0, .mag = 0 });

    for (1..FRAME_SIZE / 2 - 1) |i| {
        if (spectrum_sum[i] > spectrum_sum[i - 1] and spectrum_sum[i] > spectrum_sum[i + 1]) {
            const freq = @as(f32, @floatFromInt(i)) * bin_size;
            if (freq > 50) {  // Ignore very low frequencies
                // Find position to insert
                for (0..5) |p| {
                    if (spectrum_sum[i] > peaks[p].mag) {
                        // Shift down
                        var k: usize = 4;
                        while (k > p) : (k -= 1) {
                            peaks[k] = peaks[k - 1];
                        }
                        peaks[p] = .{ .bin = i, .mag = spectrum_sum[i] };
                        break;
                    }
                }
            }
        }
    }

    for (peaks, 0..) |peak, i| {
        if (peak.mag > 0) {
            const freq = @as(f32, @floatFromInt(peak.bin)) * bin_size;
            std.debug.print("  {d}. {d:.0} Hz: magnitude {d:.1}\n", .{ i + 1, freq, peak.mag });
        }
    }

    std.debug.print("\n", .{});
}
