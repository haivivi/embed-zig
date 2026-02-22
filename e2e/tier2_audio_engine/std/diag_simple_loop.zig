//! Simplest possible AEC loopback — NO Engine, NO mixer, NO tracks.
//!
//! Single loop:
//!   mic.read() → ref_reader.read() → aec3.process() → speaker.write()
//!
//! If this has echo, the problem is AEC3 or DuplexAudio.
//! If this has NO echo, the problem is in Engine/mixer/track.

const std = @import("std");
const pa = @import("portaudio");
const audio = @import("audio");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 15;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Simple AEC Loop (no Engine) ===\n", .{});
    std.debug.print("mic → AEC → speaker. Speak into mic. {d}s.\n\n", .{DURATION_S});

    try pa.init();
    defer pa.deinit();
    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    var duplex = da.DuplexAudio.init();
    var mic_drv = duplex.mic();
    var spk_drv = duplex.speaker();
    var ref_rdr = duplex.refReader();

    var aec = try audio.aec3.aec3.Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .comfort_noise_rms = 0,
    });
    defer aec.deinit();

    try duplex.start();
    defer duplex.stop();

    std.debug.print(">>> SPEAK NOW! <<<\n\n", .{});

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean: [FRAME_SIZE]i16 = undefined;

    const total_frames = SAMPLE_RATE * DURATION_S / FRAME_SIZE;
    var frame: usize = 0;

    while (frame < total_frames) {
        _ = mic_drv.read(&mic_buf) catch continue;
        _ = ref_rdr.read(&ref_buf) catch continue;

        aec.process(&mic_buf, &ref_buf, &clean);

        _ = spk_drv.write(&clean) catch continue;

        if (frame % 100 == 0) {
            var me: f64 = 0;
            var re: f64 = 0;
            var ce: f64 = 0;
            for (0..FRAME_SIZE) |i| {
                const mv: f64 = @floatFromInt(mic_buf[i]);
                const rv: f64 = @floatFromInt(ref_buf[i]);
                const cv: f64 = @floatFromInt(clean[i]);
                me += mv * mv;
                re += rv * rv;
                ce += cv * cv;
            }
            const mr = @sqrt(me / FRAME_SIZE);
            const rr = @sqrt(re / FRAME_SIZE);
            const cr = @sqrt(ce / FRAME_SIZE);
            std.debug.print("[{d}s] mic={d:.0} ref={d:.0} clean={d:.0}\n", .{
                frame / 100, mr, rr, cr,
            });
        }

        frame += 1;
    }

    std.debug.print("\n[Done]\n\n", .{});
}
