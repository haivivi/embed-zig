//! E3: Multi-round conversation — 3 rounds of TTS + human reply
//!
//! Uses DuplexStream + RefReader for precise alignment.
//! Each round: Engine plays TTS → wait → human speaks → readClean saves WAV.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const std_impl = @import("std_impl");
const Rt = std_impl.runtime;
const da = std_impl.audio_engine;
const Format = audio.resampler.Format;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;

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

    std.debug.print("\n=== E3: Multi-round Conversation (DuplexStream + RefReader) ===\n", .{});
    std.debug.print("Each round: TTS plays → you speak → clean saved\n\n", .{});

    const tts_data = loadWav("/tmp/tts_ref.wav", allocator) catch {
        std.debug.print("ERROR: /tmp/tts_ref.wav not found.\n", .{});
        return;
    };
    defer allocator.free(tts_data);
    const tts_ms = tts_data.len * 1000 / SAMPLE_RATE;

    try pa.init();
    defer pa.deinit();

    var duplex = da.DuplexAudio.init();
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    var engine = try Engine.init(allocator, &mic_drv, &spk_drv, &ref_rdr);
    defer engine.deinit();

    try duplex.start();
    defer duplex.stop();

    const format = Format{ .rate = SAMPLE_RATE, .channels = .mono };

    const ReaderState = struct {
        eng: *Engine,
        buf: []i16,
        pos: std.atomic.Value(usize),
        running: std.atomic.Value(bool),
    };

    const clean_max = SAMPLE_RATE * 60;
    const clean_buf = try allocator.alloc(i16, clean_max);
    defer allocator.free(clean_buf);

    var rs = ReaderState{
        .eng = &engine,
        .buf = clean_buf,
        .pos = std.atomic.Value(usize).init(0),
        .running = std.atomic.Value(bool).init(true),
    };

    try engine.start();

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(state: *ReaderState) void {
            var frame: [160]i16 = undefined;
            while (state.running.load(.acquire)) {
                const n = state.eng.readClean(&frame) orelse break;
                const pos = state.pos.load(.acquire);
                if (pos + n <= state.buf.len) {
                    @memcpy(state.buf[pos..][0..n], frame[0..n]);
                    state.pos.store(pos + n, .release);
                }
            }
        }
    }.run, .{&rs});

    for (0..3) |round| {
        std.debug.print("--- Round {d}/3 ---\n", .{round + 1});

        const h = try engine.createTrack(.{ .label = "tts" });
        try h.track.write(format, tts_data);
        h.ctrl.closeWrite();

        std.debug.print("  TTS playing ({d}ms)...\n", .{tts_ms});
        std.Thread.sleep(@as(u64, tts_ms + 1000) * std.time.ns_per_ms);

        const before_speak = rs.pos.load(.acquire);
        std.debug.print("  Speak now! (3s)\n", .{});
        std.Thread.sleep(3 * std.time.ns_per_s);
        const after_speak = rs.pos.load(.acquire);
        const round_samples = after_speak - before_speak;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/E3_round{d}_clean.wav", .{round + 1}) catch "/tmp/E3_clean.wav";
        if (round_samples > 0) {
            writeWav(path, clean_buf[before_speak..after_speak]) catch {};
            std.debug.print("  Saved: {s} ({d} samples)\n", .{ path, round_samples });
        }

        std.debug.print("  Round {d} done.\n\n", .{round + 1});
    }

    rs.running.store(false, .release);
    engine.stop();
    reader.join();

    std.debug.print("[E3] 3 rounds completed.\n\n", .{});
}
