//! UI Render Benchmark — Compositor vs LVGL
//!
//! Runs identical event sequences through both rendering approaches
//! and compares dirty bytes (SPI bandwidth) per scenario.
//!
//! Run:
//!   bazel test //e2e/benchmark/ui_render:bench --test_output=all

const std = @import("std");
const testing = std.testing;
const ui_state = @import("ui_state");
const flux = @import("flux");

const app = @import("state.zig");
const State = app.State;
const Event = app.Event;

const comp_ui = @import("compositor/ui.zig");

const Store = flux.Store(State, Event);

const W: u32 = 240;
const H: u32 = 240;
const BPP: u32 = 2;
const TOTAL_BYTES: u32 = W * H * BPP;

// ============================================================================
// Compositor measurement
// ============================================================================

fn measureCompositor(initial: State, events: []const Event) struct { total_dirty: u64, frames: u32, max_dirty: u32 } {
    var store = Store.init(initial, app.reduce);
    var fb = comp_ui.FB.init(0);
    var prev = initial;

    // Initial render (first frame always full)
    _ = comp_ui.render(&fb, store.getState(), &prev);
    fb.clearDirty();
    store.commitFrame();
    prev = store.getState().*;

    var total_dirty: u64 = 0;
    var frames: u32 = 0;
    var max_dirty: u32 = 0;

    for (events) |event| {
        store.dispatch(event);

        if (store.isDirty()) {
            fb.clearDirty();
            _ = comp_ui.render(&fb, store.getState(), &prev);

            var frame_dirty: u32 = 0;
            for (fb.getDirtyRects()) |r| frame_dirty += r.area() * BPP;
            total_dirty += frame_dirty;
            max_dirty = @max(max_dirty, frame_dirty);
            frames += 1;

            prev = store.getState().*;
            store.commitFrame();
        }
    }

    return .{ .total_dirty = total_dirty, .frames = frames, .max_dirty = max_dirty };
}

// ============================================================================
// Monolithic measurement (baseline — always full screen)
// ============================================================================

fn measureMonolithic(initial: State, events: []const Event) struct { total_dirty: u64, frames: u32 } {
    var store = Store.init(initial, app.reduce);
    var frames: u32 = 0;

    for (events) |event| {
        store.dispatch(event);
        if (store.isDirty()) {
            frames += 1;
            store.commitFrame();
        }
    }

    return .{ .total_dirty = @as(u64, frames) * TOTAL_BYTES, .frames = frames };
}

// ============================================================================
// Tests
// ============================================================================

test "benchmark: compositor vs monolithic per scenario" {
    std.debug.print(
        \\
        \\╔═══════════════════════════════════════════════════════════════════════╗
        \\║  UI Render Benchmark: Compositor vs Monolithic (240x240 RGB565)     ║
        \\╚═══════════════════════════════════════════════════════════════════════╝
        \\
        \\  {s:<25} {s:>8} {s:>12} {s:>12} {s:>8}
        \\
    , .{ "Scenario", "Frames", "Monolithic", "Compositor", "Saved" });

    for (app.scenarios) |sc| {
        const mono = measureMonolithic(sc.initial, sc.events);
        const comp = measureCompositor(sc.initial, sc.events);

        const saved: u64 = if (mono.total_dirty > 0 and comp.total_dirty < mono.total_dirty)
            (mono.total_dirty - comp.total_dirty) * 100 / mono.total_dirty
        else
            0;

        std.debug.print("  {s:<25} {d:>6}   {d:>9}B   {d:>9}B   {d:>5}%\n", .{
            sc.name,
            comp.frames,
            mono.total_dirty,
            comp.total_dirty,
            saved,
        });
    }
}

test "benchmark: compositor per-frame detail" {
    std.debug.print(
        \\
        \\=== Per-Frame Dirty Bytes (Compositor) ===
        \\
    , .{});

    // Run the game scenario frame by frame
    const game_init = State{ .page = .game, .score = 100, .player_x = 110 };
    var store = Store.init(game_init, app.reduce);
    var prev = game_init;

    var fb = comp_ui.FB.init(0);
    _ = comp_ui.render(&fb, store.getState(), &prev);
    fb.clearDirty();
    prev = store.getState().*;

    std.debug.print("  {s:>5}  {s:>10}  {s:>8}  {s}\n", .{ "Frame", "Dirty(B)", "Pct", "Changed" });

    for (0..10) |frame| {
        store.dispatch(.tick);
        if (store.isDirty()) {
            fb.clearDirty();
            const n = comp_ui.render(&fb, store.getState(), &prev);

            var dirty: u32 = 0;
            for (fb.getDirtyRects()) |r| dirty += r.area() * BPP;
            const pct = dirty * 100 / TOTAL_BYTES;

            std.debug.print("  {d:>5}  {d:>10}  {d:>6}%  {d} components\n", .{
                frame, dirty, pct, n,
            });

            prev = store.getState().*;
            store.commitFrame();
        }
    }
}

test "benchmark: RAM usage comparison" {
    std.debug.print(
        \\
        \\=== RAM Usage ===
        \\
    , .{});

    const fb_size = @sizeOf(comp_ui.FB);
    const state_size = @sizeOf(State);
    const store_size = @sizeOf(Store);

    std.debug.print("  Compositor approach:\n", .{});
    std.debug.print("    Framebuffer (240x240 RGB565): {d:>8} bytes ({d} KB)\n", .{ fb_size, fb_size / 1024 });
    std.debug.print("    State:                        {d:>8} bytes\n", .{state_size});
    std.debug.print("    Store (state + prev + dirty):  {d:>8} bytes\n", .{store_size});
    std.debug.print("    Total:                        {d:>8} bytes ({d} KB)\n", .{ fb_size + store_size, (fb_size + store_size) / 1024 });

    std.debug.print("\n  LVGL approach (estimated):\n", .{});
    std.debug.print("    LV_MEM_SIZE heap:             {d:>8} bytes (1024 KB)\n", .{@as(u32, 1024 * 1024)});
    std.debug.print("    Draw buffer (240*20*2):        {d:>8} bytes\n", .{@as(u32, 240 * 20 * 2)});
    std.debug.print("    State + Store:                 {d:>8} bytes\n", .{store_size});
    std.debug.print("    Total:                        ~{d:>7} bytes ({d} KB)\n", .{
        @as(u32, 1024 * 1024 + 240 * 20 * 2) + store_size,
        (@as(u32, 1024 * 1024 + 240 * 20 * 2) + store_size) / 1024,
    });
}

test "benchmark: SPI transfer time at different speeds" {
    const SpiSpeed = struct { name: []const u8, mhz: u32 };
    const speeds = [_]SpiSpeed{
        .{ .name = "10MHz", .mhz = 10 },
        .{ .name = "20MHz", .mhz = 20 },
        .{ .name = "40MHz", .mhz = 40 },
        .{ .name = "80MHz", .mhz = 80 },
    };

    std.debug.print(
        \\
        \\=== Max FPS at Different SPI Speeds ===
        \\
        \\  {s:<25}
    , .{"Scenario"});
    for (speeds) |spd| std.debug.print(" {s:>8}", .{spd.name});
    std.debug.print("\n", .{});

    for (app.scenarios) |sc| {
        const comp = measureCompositor(sc.initial, sc.events);
        const avg_dirty: u64 = if (comp.frames > 0) comp.total_dirty / comp.frames else 0;

        std.debug.print("  {s:<25}", .{sc.name});
        for (speeds) |spd| {
            if (avg_dirty == 0) {
                std.debug.print("      inf", .{});
            } else {
                const bits = avg_dirty * 8;
                const time_us = bits / spd.mhz;
                const fps: u64 = if (time_us > 0) 1_000_000 / time_us else 99999;
                std.debug.print(" {d:>5}fps", .{fps});
            }
        }
        std.debug.print("\n", .{});
    }

    // Monolithic baseline
    std.debug.print("  {s:<25}", .{"monolithic (baseline)"});
    for (speeds) |spd| {
        const bits: u64 = @as(u64, TOTAL_BYTES) * 8;
        const time_us = bits / spd.mhz;
        const fps: u64 = if (time_us > 0) 1_000_000 / time_us else 0;
        std.debug.print(" {d:>5}fps", .{fps});
    }
    std.debug.print("\n", .{});
}
