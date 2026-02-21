//! Games — App State (Menu + Game Selection)

const tetris = @import("tetris.zig");
const racer = @import("racer.zig");

pub const Game = enum(u8) { tetris, racer };
pub const Page = enum(u8) { menu, playing };

pub const AppState = struct {
    page: Page = .menu,
    selected: u8 = 0, // 0=tetris, 1=racer
    current_game: Game = .tetris,
    tetris: tetris.GameState = .{},
    racer: racer.GameState = .{},
};

pub const AppEvent = union(enum) {
    left,
    right,
    confirm,
    back,
    // Game events (forwarded to active game)
    game_tetris: tetris.GameEvent,
    game_racer: racer.GameEvent,
    tick,
};

pub fn reduce(state: *AppState, event: AppEvent) void {
    switch (state.page) {
        .menu => switch (event) {
            .left => if (state.selected > 0) { state.selected -= 1; },
            .right => if (state.selected < 1) { state.selected += 1; },
            .confirm => {
                state.current_game = @enumFromInt(state.selected);
                state.page = .playing;
                // Reset game
                switch (state.current_game) {
                    .tetris => state.tetris = .{},
                    .racer => state.racer = .{},
                }
            },
            else => {},
        },
        .playing => switch (event) {
            .back => state.page = .menu,
            .game_tetris => |e| tetris.reduce(&state.tetris, e),
            .game_racer => |e| racer.reduce(&state.racer, e),
            .tick => switch (state.current_game) {
                .tetris => tetris.reduce(&state.tetris, .tick),
                .racer => racer.reduce(&state.racer, .tick),
            },
            .left => switch (state.current_game) {
                .tetris => tetris.reduce(&state.tetris, .move_left),
                .racer => racer.reduce(&state.racer, .move_left),
            },
            .right => switch (state.current_game) {
                .tetris => tetris.reduce(&state.tetris, .move_right),
                .racer => racer.reduce(&state.racer, .move_right),
            },
            .confirm => switch (state.current_game) {
                .tetris => tetris.reduce(&state.tetris, .rotate),
                .racer => {},
            },
        },
    }
}
