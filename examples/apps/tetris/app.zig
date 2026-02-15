//! Tetris — Platform Glue
//!
//! Connects the pure UI logic (ui.zig) with the hardware platform:
//! - Init: Board, Display, Store, Framebuffer
//! - Step: poll buttons → dispatch events → render → SPI flush
//!
//! All game logic and rendering lives in ui.zig.

const ui = @import("ui.zig");
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
    Board.log.info("Tetris starting", .{});

    board.init() catch {
        Board.log.err("Board init failed", .{});
        return;
    };

    // Display
    sim_spi = websim.SimSpi.init(&sim_dc);
    disp = Display.init(&sim_spi, &sim_dc);

    // Game
    store = ui.Store.init(.{}, ui.reduce);
    framebuf = ui.FB.init(ui.BLACK);

    // Initial static elements (grid, borders)
    ui.drawStatic(&framebuf);

    ready = true;
    Board.log.info("Tetris ready. LEFT/RIGHT=move OK=rotate VOL-=drop BACK=restart", .{});
}

// ============================================================================
// Step (called each frame by WASM host)
// ============================================================================

pub fn step() void {
    if (!ready) return;

    // Poll buttons → dispatch game events
    board.buttons.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| {
                if (btn.action == .click) {
                    const game_event: ?ui.GameEvent = switch (btn.id) {
                        .left => .move_left,
                        .right => .move_right,
                        .confirm => .rotate,
                        .vol_down => .soft_drop,
                        .vol_up => .hard_drop,
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

    // Render if state changed
    if (store.isDirty()) {
        ui.render(&framebuf, store.getState(), store.getPrev());
        flushDirty();
        store.commitFrame();
    }
}

// ============================================================================
// Display flush — Framebuffer → SPI LCD
// ============================================================================

fn flushDirty() void {
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
