//! Reproduce PortAudio feedback issue in SimAudio
//!
//! PortAudio phenomenon:
//! 1. Hardware delay ~611 samples (38ms)
//! 2. RefReader was returning ref with wrong delay
//! 3. AEC couldn't cancel echo → feedback buildup
//!
//! This test simulates both scenarios:
//! - aligned ref (should work)
//! - misaligned ref (should fail like PortAudio)

const std = @import("std");
const tu = @import("test_utils.zig");
const sim_mod = @import("sim_audio.zig");
const aec3_mod = @import("aec3/aec3.zig");

const FRAME_SIZE = 160;
const SAMPLE_RATE = 16000;
const HARDWARE_DELAY = 611; // PortAudio measured delay
const ECHO_GAIN = 0.8;

// Test 1: ref_aligned_with_echo = true (correct alignment)
test "T1: aligned ref — AEC should cancel echo" {
    const Sim = sim_mod.SimAudio(.{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = HARDWARE_DELAY,
        .echo_gain = ECHO_GAIN,
        .has_hardware_loopback = true,
        .ref_aligned_with_echo = true, // CORRECT
        .ambient_noise_rms = 50, // Quiet room
    });

    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    var aec = try aec3_mod.Aec3.init(std.testing.allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .num_partitions = 64, // Cover 64 * 160 = 10240 samples delay
    });
    defer aec.deinit();

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean: [FRAME_SIZE]i16 = undefined;

    var max_mic_rms: f64 = 0;
    var max_clean_rms: f64 = 0;
    var clean_sum: f64 = 0;
    const num_frames = 500;

    std.debug.print("\n=== T1: Aligned ref (correct) ===\n", .{});

    for (0..num_frames) |frame| {
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        _ = try spk.write(&clean);

        const mr = tu.rmsEnergy(&mic_buf);
        const cr = tu.rmsEnergy(&clean);
        if (mr > max_mic_rms) max_mic_rms = mr;
        if (cr > max_clean_rms) max_clean_rms = cr;
        clean_sum += cr;

        if (frame % 100 == 0) {
            std.debug.print("[{d:0>3}] mic={d:>6.0} ref={d:>6.0} clean={d:>6.0}\n", .{
                frame, mr, tu.rmsEnergy(&ref_buf), cr,
            });
        }
    }

    const avg_clean = clean_sum / num_frames;
    std.debug.print("\n[T1] max_mic={d:.0} max_clean={d:.0} avg_clean={d:.0}\n", .{
        max_mic_rms, max_clean_rms, avg_clean,
    });

    // With aligned ref, AEC should keep signal stable
    try std.testing.expect(max_clean_rms < 5000); // Should not explode
}

// Test 2: ref_aligned_with_echo = false (MISALIGNED — reproduces PortAudio bug)
test "T2: misaligned ref — AEC fails, feedback builds up" {
    const Sim = sim_mod.SimAudio(.{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = HARDWARE_DELAY,
        .echo_gain = ECHO_GAIN,
        .has_hardware_loopback = true,
        .ref_aligned_with_echo = false, // MISALIGNED (like old PortAudio)
        .ambient_noise_rms = 50,
    });

    var sim = Sim.init();
    try sim.start();
    defer sim.stop();

    var spk = sim.speaker();
    var mic_drv = sim.mic();
    var rdr = sim.refReader();

    var aec = try aec3_mod.Aec3.init(std.testing.allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .num_partitions = 64,
    });
    defer aec.deinit();

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean: [FRAME_SIZE]i16 = undefined;

    var max_mic_rms: f64 = 0;
    var max_clean_rms: f64 = 0;
    var prev_clean: f64 = 0;
    var growth_count: usize = 0;

    std.debug.print("\n=== T2: Misaligned ref (reproduces PortAudio bug) ===\n", .{});

    for (0..500) |frame| {
        _ = try mic_drv.read(&mic_buf);
        _ = try rdr.read(&ref_buf);
        aec.process(&mic_buf, &ref_buf, &clean);
        _ = try spk.write(&clean);

        const mr = tu.rmsEnergy(&mic_buf);
        const cr = tu.rmsEnergy(&clean);
        if (mr > max_mic_rms) max_mic_rms = mr;
        if (cr > max_clean_rms) max_clean_rms = cr;

        // Detect feedback growth
        if (prev_clean > 100 and cr > prev_clean * 1.1) {
            growth_count += 1;
        }
        prev_clean = cr;

        if (frame % 100 == 0) {
            const warning = if (cr > 5000) " ⚠️ FEEDBACK!" else "";
            std.debug.print("[{d:0>3}] mic={d:>6.0} ref={d:>6.0} clean={d:>6.0}{s}\n", .{
                frame, mr, tu.rmsEnergy(&ref_buf), cr, warning,
            });
        }
    }

    std.debug.print("\n[T2] max_mic={d:.0} max_clean={d:.0} growth_events={d}\n", .{
        max_mic_rms, max_clean_rms, growth_count,
    });

    // With misaligned ref, AEC CANNOT cancel echo → feedback builds up
    // This reproduces the PortAudio bug!
    std.debug.print("\n*** If max_clean > 5000, feedback occurred (BAD) ***\n", .{});
    std.debug.print("*** If max_clean < 5000, AEC somehow worked (unexpected) ***\n\n", .{});
}

// Test 3: Inject near-end speech to see if AEC preserves it
test "T3: near-end speech with aligned vs misaligned ref" {
    std.debug.print("\n=== T3: Near-end speech comparison ===\n", .{});

    // Run both aligned and misaligned, compare clean output
    const results = struct {
        var aligned_clean_avg: f64 = 0;
        var misaligned_clean_avg: f64 = 0;
    };

    // Aligned
    {
        const Sim = sim_mod.SimAudio(.{
            .frame_size = FRAME_SIZE,
            .sample_rate = SAMPLE_RATE,
            .echo_delay_samples = HARDWARE_DELAY,
            .echo_gain = ECHO_GAIN,
            .has_hardware_loopback = true,
            .ref_aligned_with_echo = true,
            .ambient_noise_rms = 50,
        });

        var sim = Sim.init();
        try sim.start();
        defer sim.stop();

        var spk = sim.speaker();
        var mic_drv = sim.mic();
        var rdr = sim.refReader();

        var aec = try aec3_mod.Aec3.init(std.testing.allocator, .{
            .frame_size = FRAME_SIZE,
            .sample_rate = SAMPLE_RATE,
            .num_partitions = 64,
        });
        defer aec.deinit();

        var mic_buf: [FRAME_SIZE]i16 = undefined;
        var ref_buf: [FRAME_SIZE]i16 = undefined;
        var clean: [FRAME_SIZE]i16 = undefined;

        // Warm up
        for (0..100) |_| {
            _ = try mic_drv.read(&mic_buf);
            _ = try rdr.read(&ref_buf);
            aec.process(&mic_buf, &ref_buf, &clean);
            _ = try spk.write(&clean);
        }

        // Inject near-end speech
        var clean_sum: f64 = 0;
        for (0..100) |f| {
            var ne: [FRAME_SIZE]i16 = undefined;
            tu.generateSine(&ne, 880.0, 8000.0, SAMPLE_RATE, f * FRAME_SIZE);
            sim.writeNearEnd(&ne);

            _ = try mic_drv.read(&mic_buf);
            _ = try rdr.read(&ref_buf);
            aec.process(&mic_buf, &ref_buf, &clean);
            _ = try spk.write(&clean);

            clean_sum += tu.rmsEnergy(&clean);
        }

        results.aligned_clean_avg = clean_sum / 100;
        std.debug.print("[T3 aligned] avg_clean={d:.0}\n", .{results.aligned_clean_avg});
    }

    // Misaligned
    {
        const Sim = sim_mod.SimAudio(.{
            .frame_size = FRAME_SIZE,
            .sample_rate = SAMPLE_RATE,
            .echo_delay_samples = HARDWARE_DELAY,
            .echo_gain = ECHO_GAIN,
            .has_hardware_loopback = true,
            .ref_aligned_with_echo = false,
            .ambient_noise_rms = 50,
        });

        var sim = Sim.init();
        try sim.start();
        defer sim.stop();

        var spk = sim.speaker();
        var mic_drv = sim.mic();
        var rdr = sim.refReader();

        var aec = try aec3_mod.Aec3.init(std.testing.allocator, .{
            .frame_size = FRAME_SIZE,
            .sample_rate = SAMPLE_RATE,
            .num_partitions = 64,
        });
        defer aec.deinit();

        var mic_buf: [FRAME_SIZE]i16 = undefined;
        var ref_buf: [FRAME_SIZE]i16 = undefined;
        var clean: [FRAME_SIZE]i16 = undefined;

        // Warm up
        for (0..100) |_| {
            _ = try mic_drv.read(&mic_buf);
            _ = try rdr.read(&ref_buf);
            aec.process(&mic_buf, &ref_buf, &clean);
            _ = try spk.write(&clean);
        }

        // Inject near-end speech
        var clean_sum: f64 = 0;
        var max_clean: f64 = 0;
        for (0..100) |f| {
            var ne: [FRAME_SIZE]i16 = undefined;
            tu.generateSine(&ne, 880.0, 8000.0, SAMPLE_RATE, f * FRAME_SIZE);
            sim.writeNearEnd(&ne);

            _ = try mic_drv.read(&mic_buf);
            _ = try rdr.read(&ref_buf);
            aec.process(&mic_buf, &ref_buf, &clean);
            _ = try spk.write(&clean);

            const cr = tu.rmsEnergy(&clean);
            clean_sum += cr;
            if (cr > max_clean) max_clean = cr;
        }

        results.misaligned_clean_avg = clean_sum / 100;
        std.debug.print("[T3 misaligned] avg_clean={d:.0} max_clean={d:.0}\n", .{
            results.misaligned_clean_avg, max_clean,
        });
    }

    std.debug.print("\n[T3] Comparison: aligned={d:.0} vs misaligned={d:.0}\n", .{
        results.aligned_clean_avg, results.misaligned_clean_avg,
    });
}
