//! BitMonster — Core State (Redux)
//!
//! All mutable game state. Reducer is the sole modifier.

pub const SCREEN_W: u16 = 320;
pub const SCREEN_H: u16 = 320;

pub const Place = enum(u8) {
    home,
    diner,
    school,
    clinic,
    pet,
    gym,
    arcade,
    lucky,
    shop,
};

pub const Page = enum(u8) {
    save_select,
    main_map,
    place, // inside a place, sub-page determined by current_place
    game_snake,
    game_blackjack,
    game_tetris,
};

pub const PetSpecies = enum(u8) { flame, tide, thorn, iron, muddy };

pub const Aptitude = struct {
    health: u8 = 100, // 80-120
    spirit: u8 = 100,
    luck: u8 = 100,
};

pub const PetState = struct {
    alive: bool = true,
    species: PetSpecies = .flame,
    name: [8]u8 = .{0} ** 8,
    name_len: u8 = 0,
    level: u16 = 1,
    exp: u64 = 0,
    aptitude: Aptitude = .{},

    // Life attributes (0-100)
    health: u8 = 100,
    spirit: u8 = 100,
    luck: u8 = 50,

    // Timers (RTC seconds since last action)
    last_bath_time: u32 = 0,
    last_toilet_time: u32 = 0,
    last_clean_time: u32 = 0,

    death_count: u8 = 0,
    merit: u32 = 0, // 功德 (from 祈福)
};

pub const SaveSlot = struct {
    active: bool = false,
    pet: PetState = .{},
    // Inventory: item_id + quantity, 12 slots
    inventory: [12]ItemSlot = [_]ItemSlot{.{}} ** 12,
};

pub const ItemSlot = struct {
    item_id: u8 = 0,
    quantity: u8 = 0,
};

pub const AppState = struct {
    page: Page = .save_select,
    current_place: Place = .home,
    tick: u32 = 0,

    // Save system
    selected_slot: u8 = 0,
    active_slot: u8 = 0,
    saves: [3]SaveSlot = [3]SaveSlot{
        .{ .active = true, .pet = .{ .species = .flame, .name = .{ 'F', 'l', 'a', 'm', 'e', 0, 0, 0 }, .name_len = 5 } },
        .{},
        .{},
    },

    // Navigation
    grid_cursor: u8 = 4, // 0-8 for 3x3 grid, starts at center (pet)
    scroll_index: u8 = 0, // for horizontal scroll pages
    sub_index: u8 = 0, // for sub-menus within a place

    // Shared (device-level)
    wallet: u64 = 500, // starting money: 500 B
    language: u8 = 0, // 0=en, 1=zh

    // Pokedex (device-level, bitset)
    pokedex_bits: [1]u32 = .{0},
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
                state.grid_cursor = 4; // center (pet)
            }
            // TODO: if slot empty → new game flow
        },
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
            const place: ?Place = switch (state.grid_cursor) {
                0 => .home,
                1 => .diner,
                2 => .school,
                3 => .clinic,
                4 => .pet,
                5 => .gym,
                6 => .arcade,
                7 => .lucky,
                8 => .shop,
                else => null,
            };
            if (place) |p| {
                state.current_place = p;
                state.page = .place;
                state.sub_index = 0;
                state.scroll_index = 0;
            }
        },
        else => {},
    }
}

fn reducePlace(state: *AppState, event: Event) void {
    switch (event) {
        .back => {
            state.page = .main_map;
        },
        else => {},
    }
}
