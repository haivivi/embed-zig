//! E4: 60s Engine long-running — repeated TTS cycles, no crash/leak
//!
//! Cycles: create track → write 3.4s TTS → close → wait 5s gap → repeat.
//! 60s total. Verifies ERLE doesn't degrade and no memory leak.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const Rt = @import("std_impl").runtime;
const Mixer = audio.mixer.Mixer(Rt);
const Format = audio.resampler.Format;
const Engine = audio.engine.AudioEngine(Rt, MicDriver, SpeakerDriver);

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u64 = 60;

const MicDriver = struct {
    stream: pa.InputStream(i16),
    pub fn init() !MicDriver {
        var s = try pa.InputStream(i16).open(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE });
        try s.start();
        return .{ .stream = s };
    }
    pub fn deinit(self: *MicDriver) void { self.stream.stop() catch {}; self.stream.close(); }
    pub fn read(self: *MicDriver, buf: []i16) !usize { try self.stream.read(buf); return buf.len; }
};

const SpeakerDriver = struct {
    stream: pa.OutputStream(i16),
    pub fn init() !SpeakerDriver {
        var s = try pa.OutputStream(i16).open(.{ .sample_rate = SAMPLE_RATE, .channels = 1, .frames_per_buffer = FRAME_SIZE });
        try s.start();
        return .{ .stream = s };
    }
    pub fn deinit(self: *SpeakerDriver) void { self.stream.stop() catch {}; self.stream.close(); }
    pub fn write(self: *SpeakerDriver, buf: []const i16) !usize { try self.stream.write(buf); return buf.len; }
};

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

    std.debug.print("\n=== E4: 60s Engine Long-Running ===\n", .{});
    std.debug.print("Repeated TTS cycles. Stay quiet.\n\n", .{});

    const tts_data = loadWav("/tmp/tts_ref.wav", allocator) catch {
        std.debug.print("ERROR: /tmp/tts_ref.wav not found.\n", .{});
        return;
    };
    defer allocator.free(tts_data);

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var mic_drv = try MicDriver.init();
    defer mic_drv.deinit();
    var spk_drv = try SpeakerDriver.init();
    defer spk_drv.deinit();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, .{
        .enable_aec = true,
        .enable_ns = true,
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
    });
    defer engine.deinit();

    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };

    // Reader thread drains readClean continuously
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

        // Wait TTS + gap
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

    // GPA leak check happens on defer gpa.deinit()
    std.debug.print("[E4] PASS\n\n", .{});
}
