//! E1b: AudioEngine loopback — Separate streams + buffer_depth mode
//!
//! Uses independent PortAudio InputStream/OutputStream with speaker_buffer_depth
//! to compensate for hardware buffer delay. For comparison with E1 (DuplexStream).

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const std_impl = @import("std_impl");
const Rt = std_impl.runtime;
const MicDriver = std_impl.mic.Driver;
const SpeakerDriver = std_impl.speaker.Driver;
const Mixer = audio.mixer.Mixer(Rt);
const Format = audio.resampler.Format;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 15;
const BUFFER_DEPTH: u32 = 5;

const Engine = audio.engine.AudioEngine(Rt, MicDriver, SpeakerDriver, .{
    .enable_aec = true,
    .enable_ns = true,
    .frame_size = FRAME_SIZE,
    .sample_rate = SAMPLE_RATE,
    .speaker_buffer_depth = BUFFER_DEPTH,
});

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

    std.debug.print("\n=== E1b: Engine Loopback (Separate Streams, depth={d}) ===\n", .{BUFFER_DEPTH});
    std.debug.print("Duration: {d}s\n\n", .{DURATION_S});

    const tts_data = loadWav("/tmp/tts_ref.wav", allocator) catch {
        std.debug.print("ERROR: /tmp/tts_ref.wav not found.\n", .{});
        return;
    };
    defer allocator.free(tts_data);

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var mic_drv = try MicDriver.init(.{ .sample_rate = SAMPLE_RATE, .frames_per_buffer = FRAME_SIZE });
    defer mic_drv.deinit();
    var spk_drv = try SpeakerDriver.init(.{ .sample_rate = SAMPLE_RATE, .frames_per_buffer = FRAME_SIZE });
    defer spk_drv.deinit();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, {});
    defer engine.deinit();

    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };

    var tts_running = std.atomic.Value(bool).init(true);
    const tts_writer = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, fmt: Format, tts: []const i16, running: *std.atomic.Value(bool)) void {
            while (running.load(.acquire)) {
                const h = eng.createTrack(.{ .label = "tts" }) catch break;
                h.track.write(fmt, tts) catch { h.ctrl.closeWrite(); break; };
                h.ctrl.closeWrite();
                std.Thread.sleep((@as(u64, tts.len) * std.time.ns_per_s / 16000) + 2 * std.time.ns_per_s);
            }
        }
    }.run, .{ &engine, format, tts_data, &tts_running });

    const monitor = try engine.createTrack(.{ .label = "monitor" });

    const rec_max = SAMPLE_RATE * DURATION_S;
    const rec_buf = try allocator.alloc(i16, rec_max);
    defer allocator.free(rec_buf);
    var rec_pos = std.atomic.Value(usize).init(0);
    var reader_running = std.atomic.Value(bool).init(true);

    try engine.start();
    std.debug.print("Running...\n\n", .{});

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(
            eng: *Engine,
            track: *Mixer.Track,
            fmt: Format,
            buf: []i16,
            pos: *std.atomic.Value(usize),
            running: *std.atomic.Value(bool),
        ) void {
            var frame: [160]i16 = undefined;
            while (running.load(.acquire)) {
                const n = eng.readClean(&frame) orelse break;
                if (n == 0) continue;
                const p = pos.load(.acquire);
                if (p + n <= buf.len) {
                    @memcpy(buf[p..][0..n], frame[0..n]);
                    pos.store(p + n, .release);
                }
                track.write(fmt, frame[0..n]) catch break;
            }
        }
    }.run, .{ &engine, monitor.track, format, rec_buf, &rec_pos, &reader_running });

    std.Thread.sleep(@as(u64, DURATION_S) * std.time.ns_per_s);

    tts_running.store(false, .release);
    reader_running.store(false, .release);
    monitor.ctrl.closeWrite();
    engine.stop();
    tts_writer.join();
    reader.join();

    const recorded = rec_pos.load(.acquire);
    std.debug.print("Recorded {d} clean samples ({d:.1}s)\n", .{
        recorded, @as(f64, @floatFromInt(recorded)) / 16000.0,
    });

    try writeWav("/tmp/E1b_clean.wav", rec_buf[0..recorded]);
    std.debug.print("Saved: /tmp/E1b_clean.wav\n\n", .{});
}
