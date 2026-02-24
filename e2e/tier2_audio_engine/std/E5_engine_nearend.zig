//! E5: Near-end detection — TTS plays, then human speaks mid-stream
//!
//! Uses DuplexStream + RefReader.
//! Phase 1 (5s): TTS plays, stay quiet. Clean should have low energy.
//! Phase 2 (7s): Human speaks. Clean should show voice energy.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const std_impl = @import("std_impl");
const Rt = std_impl.runtime;
const da = std_impl.audio_engine;
const Format = audio.resampler.Format;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 12;

const Engine = audio.engine.AudioEngine(
    Rt,
    da.DuplexAudio.Mic,
    da.DuplexAudio.Speaker,
    .{
        .enable_aec = true,
        .enable_ns = true,
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .RefReader = da.DuplexAudio.RefReader,
    },
);

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

    std.debug.print("\n=== E5: Near-end Detection (DuplexStream + RefReader) ===\n", .{});
    std.debug.print("TTS plays. Stay quiet until prompted.\n\n", .{});

    const tts_data = loadWav("/tmp/tts_ref.wav", allocator) catch {
        std.debug.print("ERROR: /tmp/tts_ref.wav not found.\n", .{});
        return;
    };
    defer allocator.free(tts_data);

    try pa.init();
    defer pa.deinit();

    var duplex = try da.DuplexAudio.init(allocator);
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, &ref_rdr);
    defer engine.deinit();

    defer duplex.stop();

    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };

    var writer_running = std.atomic.Value(bool).init(true);
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, fmt: Format, tts: []const i16, r: *std.atomic.Value(bool)) void {
            while (r.load(.acquire)) {
                const h = eng.createTrack(.{ .label = "tts" }) catch break;
                h.track.write(fmt, tts) catch { h.ctrl.closeWrite(); break; };
                h.ctrl.closeWrite();
                std.Thread.sleep((@as(u64, tts.len) * std.time.ns_per_s / 16000) + 500 * std.time.ns_per_ms);
            }
        }
    }.run, .{ &engine, format, tts_data, &writer_running });

    const total = SAMPLE_RATE * DURATION_S;
    const clean_buf = try allocator.alloc(i16, total);
    defer allocator.free(clean_buf);

    var running = std.atomic.Value(bool).init(true);
    var clean_pos = std.atomic.Value(usize).init(0);

    try engine.start();

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, buf: []i16, pos: *std.atomic.Value(usize), r: *std.atomic.Value(bool)) void {
            var frame: [160]i16 = undefined;
            while (r.load(.acquire)) {
                const n = eng.readClean(&frame) orelse break;
                const p = pos.load(.acquire);
                if (p + n <= buf.len) {
                    @memcpy(buf[p..][0..n], frame[0..n]);
                    pos.store(p + n, .release);
                }
            }
        }
    }.run, .{ &engine, clean_buf, &clean_pos, &running });

    std.debug.print("Phase 1: TTS playing, stay QUIET (5s)...\n", .{});
    std.Thread.sleep(5 * std.time.ns_per_s);

    std.debug.print("Phase 2: >>> SPEAK NOW! <<< (7s)\n", .{});
    std.Thread.sleep(7 * std.time.ns_per_s);

    writer_running.store(false, .release);
    running.store(false, .release);
    engine.stop();
    reader.join();
    writer.join();

    const n = clean_pos.load(.acquire);
    std.debug.print("\nRecorded {d} clean samples ({d:.1}s)\n", .{
        n, @as(f64, @floatFromInt(n)) / 16000.0,
    });

    const boundary = @min(5 * SAMPLE_RATE, n);
    var quiet_energy: f64 = 0;
    for (clean_buf[0..boundary]) |s| {
        const v: f64 = @floatFromInt(s);
        quiet_energy += v * v;
    }
    const quiet_rms = @sqrt(quiet_energy / @as(f64, @floatFromInt(boundary)));

    const speak_start = @min(5 * SAMPLE_RATE, n);
    const speak_end = n;
    var speak_energy: f64 = 0;
    if (speak_end > speak_start) {
        for (clean_buf[speak_start..speak_end]) |s| {
            const v: f64 = @floatFromInt(s);
            speak_energy += v * v;
        }
    }
    const speak_rms = if (speak_end > speak_start)
        @sqrt(speak_energy / @as(f64, @floatFromInt(speak_end - speak_start)))
    else
        0;

    std.debug.print("Quiet phase RMS:  {d:.1}\n", .{quiet_rms});
    std.debug.print("Speak phase RMS:  {d:.1}\n", .{speak_rms});
    std.debug.print("Ratio: {d:.1}x\n", .{speak_rms / @max(quiet_rms, 1.0)});

    if (speak_rms > quiet_rms * 2.0) {
        std.debug.print("\n[E5] PASS — voice detected ({d:.1}x quiet)\n", .{
            speak_rms / @max(quiet_rms, 1.0),
        });
    } else {
        std.debug.print("\n[E5] FAIL — voice not detected (ratio {d:.1}x, need >2x)\n", .{
            speak_rms / @max(quiet_rms, 1.0),
        });
    }

    try writeWav("/tmp/E5_clean.wav", clean_buf[0..n]);
    std.debug.print("Saved: /tmp/E5_clean.wav\n\n", .{});
}
