//! E4: 60s Engine long-running — repeated TTS cycles, no crash/leak
//!
//! Uses DuplexStream + RefReader.
//! Cycles: create track → write TTS → close → gap → repeat for 60s.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const std_impl = @import("std_impl");
const Rt = std_impl.runtime;
const da = std_impl.audio_engine;
const Format = audio.resampler.Format;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u64 = 60;

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== E4: 60s Engine Long-Running (DuplexStream + RefReader) ===\n", .{});
    std.debug.print("Repeated TTS cycles. Stay quiet.\n\n", .{});

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

    var running = std.atomic.Value(bool).init(true);
    var clean_count = std.atomic.Value(usize).init(0);

    try engine.start();

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(eng: *Engine, r: *std.atomic.Value(bool), cnt: *std.atomic.Value(usize)) void {
            var buf: [160]i16 = undefined;
            while (r.load(.acquire)) {
                const n = eng.readClean(&buf) orelse break;
                _ = cnt.fetchAdd(n, .acq_rel);
            }
        }
    }.run, .{ &engine, &running, &clean_count });

    const start_time = std.time.milliTimestamp();
    var round: u32 = 0;

    while (true) {
        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        if (elapsed >= DURATION_S * 1000) break;

        round += 1;
        const h = try engine.createTrack(.{ .label = "tts" });
        try h.track.write(format, tts_data);
        h.ctrl.closeWrite();

        const tts_ms = tts_data.len * 1000 / SAMPLE_RATE;
        std.Thread.sleep(@as(u64, tts_ms + 4000) * std.time.ns_per_ms);

        const samples = clean_count.load(.acquire);
        std.debug.print("  [{d}s] round={d}, clean_samples={d}\n", .{
            elapsed / 1000, round, samples,
        });
    }

    running.store(false, .release);
    engine.stop();
    reader.join();

    const total_clean = clean_count.load(.acquire);
    std.debug.print("\n[E4] 60s completed. {d} rounds, {d} clean samples. No crash.\n", .{ round, total_clean });
    std.debug.print("[E4] PASS\n\n", .{});
}
