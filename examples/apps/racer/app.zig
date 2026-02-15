//! Racer — Platform Glue
//!
//! Connects UI logic (ui.zig) + sound (sound.zig) with websim hardware.

const ui = @import("ui.zig");
const sound_mod = @import("sound.zig");
const state_lib = @import("ui_state");
const hal = @import("hal");
const websim = @import("websim");
const display_pkg = @import("display");

const platform = @import("platform.zig");
const Board = platform.Board;
const Display = platform.Display;
const ButtonId = platform.ButtonId;

// ============================================================================
// Globals
// ============================================================================

var store: ui.Store = undefined;
var framebuf: ui.FB = undefined;
var board: Board = undefined;
var sim_dc: websim.SimDcPin = .{};
var sim_spi: websim.SimSpi = undefined;
var disp: Display = undefined;
var ready: bool = false;

// ============================================================================
// Init
// ============================================================================

pub fn init() void {
    Board.log.info("Racer starting", .{});

    board.init() catch {
        Board.log.err("Board init failed", .{});
        return;
    };

    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    store = ui.Store.init(.{}, ui.reduce);
    framebuf = ui.FB.init(ui.BLACK);

    ready = true;
    Board.log.info("Racer ready. LEFT/RIGHT=steer BACK=restart", .{});
}

// ============================================================================
// Step
// ============================================================================

pub fn step() void {
    if (!ready) return;

    // Poll buttons
    board.buttons.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| {
                if (btn.action == .click) {
                    const game_event: ?ui.GameEvent = switch (btn.id) {
                        .left => .move_left,
                        .right => .move_right,
                        .back => .restart,
                        else => null,
                    };
                    if (game_event) |e| store.dispatch(e);
                }
            },
            else => {},
        }
    }

    // Game tick
    store.dispatch(.tick);

    // Sound effects
    const snd = store.getState().sound;
    if (snd != .none) {
        const buf = sound_mod.generate(snd);
        if (buf.len > 0) {
            _ = board.speaker.write(buf.samples[0..buf.len]) catch 0;
        }
    }

    // Render (every frame — racing game redraws everything for scrolling)
    if (store.isDirty()) {
        ui.render(&framebuf, store.getState(), store.getPrev());
        flushDisplay();
        store.commitFrame();
    }
}

// ============================================================================
// Display flush
// ============================================================================

fn flushDisplay() void {
    var tmp: [240 * 240]u16 = undefined;

    for (framebuf.getDirtyRects()) |rect| {
        const pixels = framebuf.getRegion(rect, &tmp);
        if (pixels.len == 0) continue;
        disp.flush(
            .{
                .x1 = rect.x,
                .y1 = rect.y,
                .x2 = rect.x + rect.w - 1,
                .y2 = rect.y + rect.h - 1,
            },
            @ptrCast(pixels.ptr),
        );
    }
    framebuf.clearDirty();
}
