//! BitMonster — Root State + Reducer

pub const pet_mod = @import("pet.zig");
pub const save_mod = @import("save.zig");
pub const economy = @import("economy.zig");

pub const Pet = pet_mod.Pet;
pub const Species = pet_mod.Species;
pub const SaveSlot = save_mod.SaveSlot;

pub const SCREEN_W: u16 = 320;
pub const SCREEN_H: u16 = 320;

pub const Place = enum(u8) { home, diner, school, clinic, pet, gym, arcade, lucky, shop };

pub const Page = enum(u8) {
    save_select,
    new_game, // choosing species
    main_map,
    place,
    game_snake,
    game_blackjack,
    game_tetris,
};

pub const AppState = struct {
    page: Page = .save_select,
    current_place: Place = .home,
    tick: u32 = 0,

    selected_slot: u8 = 0,
    active_slot: u8 = 0,
    saves: [3]SaveSlot = [_]SaveSlot{.{}} ** 3,

    // Navigation
    grid_cursor: u8 = 4,
    scroll_index: u8 = 0,
    sub_index: u8 = 0,

    // New game flow
    new_game_species: u8 = 0,

    // Shared (device-level)
    wallet: u64 = 500,
    language: u8 = 0, // 0=en, 1=zh
    pokedex_bits: [1]u32 = .{0},

    pub fn activeSave(self: *AppState) *SaveSlot {
        return &self.saves[self.active_slot];
    }

    pub fn activePet(self: *AppState) *Pet {
        return &self.saves[self.active_slot].pet;
    }

    pub fn activeSaveConst(self: *const AppState) *const SaveSlot {
        return &self.saves[self.active_slot];
    }
};

pub const Event = union(enum) {
    tick,
    up,
    down,
    left,
    right,
    confirm,
    back,
    power_hold,
    power_release,
};

pub fn reduce(state: *AppState, event: Event) void {
    state.tick += 1;

    switch (state.page) {
        .save_select => reduceSaveSelect(state, event),
        .new_game => reduceNewGame(state, event),
        .main_map => reduceMainMap(state, event),
        .place => reducePlace(state, event),
        else => {},
    }
}

fn reduceSaveSelect(state: *AppState, event: Event) void {
    switch (event) {
        .up => if (state.selected_slot > 0) { state.selected_slot -= 1; },
        .down => if (state.selected_slot < 2) { state.selected_slot += 1; },
        .confirm => {
            if (state.saves[state.selected_slot].active) {
                state.active_slot = state.selected_slot;
                state.page = .main_map;
                state.grid_cursor = 4;
            } else {
                state.page = .new_game;
                state.new_game_species = 0;
            }
        },
        else => {},
    }
}

fn reduceNewGame(state: *AppState, event: Event) void {
    switch (event) {
        .left => if (state.new_game_species > 0) { state.new_game_species -= 1; },
        .right => if (state.new_game_species < 4) { state.new_game_species += 1; },
        .confirm => {
            const species: Species = @enumFromInt(state.new_game_species);
            const names = [_][]const u8{ "Flame", "Tide", "Thorn", "Iron", "Muddy" };
            state.saves[state.selected_slot] = save_mod.newGame(
                species,
                names[state.new_game_species],
                state.tick,
            );
            state.active_slot = state.selected_slot;
            state.page = .main_map;
            state.grid_cursor = 4;
        },
        .back => state.page = .save_select,
        else => {},
    }
}

fn reduceMainMap(state: *AppState, event: Event) void {
    switch (event) {
        .up => if (state.grid_cursor >= 3) { state.grid_cursor -= 3; },
        .down => if (state.grid_cursor <= 5) { state.grid_cursor += 3; },
        .left => if (state.grid_cursor % 3 > 0) { state.grid_cursor -= 1; },
        .right => if (state.grid_cursor % 3 < 2) { state.grid_cursor += 1; },
        .confirm => {
            state.current_place = @enumFromInt(state.grid_cursor);
            state.page = .place;
            state.sub_index = 0;
            state.scroll_index = 0;
        },
        .back => {
            state.page = .save_select;
        },
        else => {},
    }
}

fn reducePlace(state: *AppState, event: Event) void {
    switch (event) {
        .back => state.page = .main_map,
        else => {},
    }
}
