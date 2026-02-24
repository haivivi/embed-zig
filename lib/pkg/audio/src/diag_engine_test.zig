//! Minimal test to diagnose AudioEngine + SimAudio hanging issue

const std = @import("std");
const testing = std.testing;
const sim_audio = @import("sim_audio.zig");
const audio_engine = @import("engine.zig");

const SimAudio = sim_audio.SimAudio;

const FRAME_SIZE: u32 = 160;
const SAMPLE_RATE: u32 = 16000;

const TestRt = @import("std_impl").runtime;

test "Diag 1: SimAudio only" {
    std.debug.print("\n=== DIAG 1: SimAudio only ===\n", .{});

    const SimA = SimAudio(.{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = 320,
        .echo_gain = 0.5,
        .has_hardware_loopback = true,
    });

    std.debug.print("  Creating SimAudio...\n", .{});
    var sim = SimA.init();

    std.debug.print("  Starting SimAudio...\n", .{});
    try sim.start();

    std.debug.print("  SimAudio running, waiting 100ms...\n", .{});
    std.Thread.sleep(100 * std.time.ns_per_ms);

    std.debug.print("  Stopping SimAudio...\n", .{});
    sim.stop();

    std.debug.print("  DONE\n", .{});
}

test "Diag 2: Engine init only (no start)" {
    std.debug.print("\n=== DIAG 2: Engine init only ===\n", .{});

    const SimA = SimAudio(.{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = 320,
        .echo_gain = 0.5,
        .has_hardware_loopback = true,
    });

    const Engine = audio_engine.AudioEngine(
        TestRt,
        SimA.Mic,
        SimA.Speaker,
        .{
            .enable_aec = true,
            .frame_size = FRAME_SIZE,
            .sample_rate = SAMPLE_RATE,
            .RefReader = SimA.RefReader,
        },
    );

    std.debug.print("  Creating SimAudio...\n", .{});
    var sim = SimA.init();

    std.debug.print("  Getting drivers...\n", .{});
    var mic_drv = sim.mic();
    var spk_drv = sim.speaker();
    var ref_drv = sim.refReader();

    std.debug.print("  Creating Engine...\n", .{});
    var engine = try Engine.init(testing.allocator, &mic_drv, &spk_drv, &ref_drv);
    defer engine.deinit();

    std.debug.print("  DONE (engine not started)\n", .{});
}

test "Diag 3: Engine + SimAudio start order A" {
    std.debug.print("\n=== DIAG 3: SimAudio start first, then Engine ===\n", .{});

    const SimA = SimAudio(.{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = 320,
        .echo_gain = 0.5,
        .has_hardware_loopback = true,
    });

    const Engine = audio_engine.AudioEngine(
        TestRt,
        SimA.Mic,
        SimA.Speaker,
        .{
            .enable_aec = true,
            .frame_size = FRAME_SIZE,
            .sample_rate = SAMPLE_RATE,
            .RefReader = SimA.RefReader,
        },
    );

    std.debug.print("  1. Creating SimAudio...\n", .{});
    var sim = SimA.init();

    std.debug.print("  2. Getting drivers...\n", .{});
    var mic_drv = sim.mic();
    var spk_drv = sim.speaker();
    var ref_drv = sim.refReader();

    std.debug.print("  3. Creating Engine...\n", .{});
    var engine = try Engine.init(testing.allocator, &mic_drv, &spk_drv, &ref_drv);
    defer engine.deinit();

    std.debug.print("  4. Starting SimAudio...\n", .{});
    try sim.start();
    defer sim.stop();

    std.debug.print("  5. Starting Engine (will hang here?)...\n", .{});
    try engine.start();
    defer engine.stop();

    std.debug.print("  6. Waiting 100ms...\n", .{});
    std.Thread.sleep(100 * std.time.ns_per_ms);

    std.debug.print("  DONE\n", .{});
}

test "Diag 4: Engine start without SimAudio start" {
    std.debug.print("\n=== DIAG 4: Engine start WITHOUT SimAudio start ===\n", .{});

    const SimA = SimAudio(.{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = 320,
        .echo_gain = 0.5,
        .has_hardware_loopback = true,
    });

    const Engine = audio_engine.AudioEngine(
        TestRt,
        SimA.Mic,
        SimA.Speaker,
        .{
            .enable_aec = true,
            .frame_size = FRAME_SIZE,
            .sample_rate = SAMPLE_RATE,
            .RefReader = SimA.RefReader,
        },
    );

    std.debug.print("  1. Creating SimAudio (NOT starting it)...\n", .{});
    var sim = SimA.init();

    std.debug.print("  2. Getting drivers...\n", .{});
    var mic_drv = sim.mic();
    var spk_drv = sim.speaker();
    var ref_drv = sim.refReader();

    std.debug.print("  3. Creating Engine...\n", .{});
    var engine = try Engine.init(testing.allocator, &mic_drv, &spk_drv, &ref_drv);
    defer engine.deinit();

    std.debug.print("  4. Starting Engine (will hang here?)...\n", .{});
    try engine.start();
    defer engine.stop();

    std.debug.print("  5. Waiting 100ms...\n", .{});
    std.Thread.sleep(100 * std.time.ns_per_ms);

    std.debug.print("  DONE\n", .{});
}
