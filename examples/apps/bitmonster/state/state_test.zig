//! BitMonster — State Tests

const std = @import("std");
const t = std.testing;

const state_mod = @import("state.zig");
const pet_mod = @import("pet.zig");
const save_mod = @import("save.zig");
const economy = @import("economy.zig");

const AppState = state_mod.AppState;
const Event = state_mod.Event;
const Pet = pet_mod.Pet;
const SaveSlot = save_mod.SaveSlot;
const Species = pet_mod.Species;

fn dispatch(state: *AppState, event: Event) void {
    state_mod.reduce(state, event);
}

// ============================================================================
// Pet tests
// ============================================================================

test "pet: initial state" {
    const p = Pet{};
    try t.expect(p.alive);
    try t.expectEqual(@as(u8, 100), p.health);
    try t.expectEqual(@as(u8, 100), p.spirit);
    try t.expectEqual(@as(u16, 1), p.level);
    try t.expectEqual(@as(u64, 0), p.exp);
}

test "pet: exp to next level" {
    var p = Pet{};
    try t.expectEqual(@as(u64, 100), p.expToNextLevel()); // Lv.1: 1*1*100
    p.level = 5;
    try t.expectEqual(@as(u64, 2500), p.expToNextLevel()); // 5*5*100
    p.level = 10;
    try t.expectEqual(@as(u64, 10000), p.expToNextLevel()); // 10*10*100
}

test "pet: add exp levels up" {
    var p = Pet{};
    p.addExp(100); // exactly 1 level
    try t.expectEqual(@as(u16, 2), p.level);
    try t.expectEqual(@as(u64, 0), p.exp);
}

test "pet: add exp overflow levels up multiple" {
    var p = Pet{};
    p.addExp(500); // Lv1→2 needs 100, Lv2→3 needs 400, total 500
    try t.expectEqual(@as(u16, 3), p.level);
    try t.expectEqual(@as(u64, 0), p.exp);
}

test "pet: add exp partial" {
    var p = Pet{};
    p.addExp(50);
    try t.expectEqual(@as(u16, 1), p.level);
    try t.expectEqual(@as(u64, 50), p.exp);
}

test "pet: decay reduces attributes" {
    var p = Pet{};
    p.applyDecay(10, pet_mod.default_decay);
    try t.expectEqual(@as(u8, 60), p.health); // 100 - 10*4
    try t.expectEqual(@as(u8, 70), p.spirit); // 100 - 10*3
    try t.expectEqual(@as(u8, 40), p.luck); // 50 - 10*1
}

test "pet: decay saturates at zero" {
    var p = Pet{};
    p.health = 10;
    p.applyDecay(100, pet_mod.default_decay);
    try t.expectEqual(@as(u8, 0), p.health);
    try t.expect(!p.alive); // died
}

test "pet: death on zero health" {
    var p = Pet{};
    p.health = 1;
    p.applyDecay(1, pet_mod.default_decay);
    try t.expectEqual(@as(u8, 0), p.health);
    try t.expect(!p.alive);
}

test "pet: use item with aptitude" {
    var p = Pet{};
    p.health = 50;
    p.aptitude.health = 120;
    p.useItem(10, .health); // 10 * 120 / 100 = 12
    try t.expectEqual(@as(u8, 62), p.health);
}

test "pet: use item caps at 100" {
    var p = Pet{};
    p.health = 95;
    p.useItem(20, .health);
    try t.expectEqual(@as(u8, 100), p.health);
}

test "pet: use item low aptitude" {
    var p = Pet{};
    p.health = 50;
    p.aptitude.health = 80;
    p.useItem(10, .health); // 10 * 80 / 100 = 8
    try t.expectEqual(@as(u8, 58), p.health);
}

test "pet: revival cost doubles" {
    var p = Pet{};
    try t.expectEqual(@as(u64, 100), p.revivalCost()); // 0 deaths
    p.death_count = 1;
    try t.expectEqual(@as(u64, 200), p.revivalCost());
    p.death_count = 2;
    try t.expectEqual(@as(u64, 400), p.revivalCost());
    p.death_count = 5;
    try t.expectEqual(@as(u64, 3200), p.revivalCost());
}

test "pet: set and get name" {
    var p = Pet{};
    p.setName("Flame");
    try t.expectEqualStrings("Flame", p.getName());
}

test "pet: name truncates at 8" {
    var p = Pet{};
    p.setName("VeryLongName");
    try t.expectEqual(@as(u8, 8), p.name_len);
    try t.expectEqualStrings("VeryLong", p.getName());
}

test "pet: aptitude roll range" {
    const apt = pet_mod.Aptitude.roll(42);
    try t.expect(apt.health >= 80 and apt.health <= 120);
    try t.expect(apt.spirit >= 80 and apt.spirit <= 120);
    try t.expect(apt.luck >= 80 and apt.luck <= 120);
}

test "pet: aptitude roll varies with seed" {
    const a = pet_mod.Aptitude.roll(1);
    const b = pet_mod.Aptitude.roll(999);
    // Very unlikely to be identical
    try t.expect(a.health != b.health or a.spirit != b.spirit or a.luck != b.luck);
}

// ============================================================================
// Save tests
// ============================================================================

test "save: new game creates active slot" {
    const slot = save_mod.newGame(.flame, "Test", 123);
    try t.expect(slot.active);
    try t.expectEqual(Species.flame, slot.pet.species);
    try t.expectEqualStrings("Test", slot.pet.getName());
    try t.expect(slot.pet.aptitude.health >= 80);
}

test "save: inventory add and query" {
    var slot = SaveSlot{ .active = true };
    try t.expect(slot.addItem(0, 5));
    try t.expect(slot.hasItem(0));
    try t.expectEqual(@as(u8, 5), slot.getItemQty(0));
    try t.expectEqual(@as(u8, 1), slot.inventoryCount());
}

test "save: inventory stacking" {
    var slot = SaveSlot{ .active = true };
    try t.expect(slot.addItem(0, 3));
    try t.expect(slot.addItem(0, 2)); // stacks
    try t.expectEqual(@as(u8, 5), slot.getItemQty(0));
    try t.expectEqual(@as(u8, 1), slot.inventoryCount()); // still 1 slot
}

test "save: inventory stack caps at 255" {
    var slot = SaveSlot{ .active = true };
    try t.expect(slot.addItem(0, 250));
    try t.expect(slot.addItem(0, 100));
    try t.expectEqual(@as(u8, 255), slot.getItemQty(0));
}

test "save: inventory remove" {
    var slot = SaveSlot{ .active = true };
    _ = slot.addItem(0, 5);
    try t.expect(slot.removeItem(0, 3));
    try t.expectEqual(@as(u8, 2), slot.getItemQty(0));
}

test "save: inventory remove insufficient" {
    var slot = SaveSlot{ .active = true };
    _ = slot.addItem(0, 2);
    try t.expect(!slot.removeItem(0, 5)); // not enough
    try t.expectEqual(@as(u8, 2), slot.getItemQty(0)); // unchanged
}

test "save: inventory full" {
    var slot = SaveSlot{ .active = true };
    var i: u8 = 0;
    while (i < save_mod.INVENTORY_SIZE) : (i += 1) {
        try t.expect(slot.addItem(i, 1));
    }
    try t.expect(!slot.addItem(99, 1)); // full
}

test "save: empty slot has no items" {
    const slot = SaveSlot{};
    try t.expect(!slot.hasItem(0));
    try t.expectEqual(@as(u8, 0), slot.inventoryCount());
}

// ============================================================================
// Economy tests
// ============================================================================

test "economy: format currency B" {
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("500 B", economy.formatCurrency(&buf, 500));
    try t.expectEqualStrings("0 B", economy.formatCurrency(&buf, 0));
    try t.expectEqualStrings("1023 B", economy.formatCurrency(&buf, 1023));
}

test "economy: format currency KB" {
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("1 KB", economy.formatCurrency(&buf, 1024));
    try t.expectEqualStrings("2.5 KB", economy.formatCurrency(&buf, 2560));
}

test "economy: format currency MB" {
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("1 MB", economy.formatCurrency(&buf, 1024 * 1024));
}

test "economy: sell price is half" {
    try t.expectEqual(@as(u64, 10), economy.sellPrice(20));
    try t.expectEqual(@as(u64, 250), economy.sellPrice(500));
}

test "economy: item list has correct count" {
    try t.expectEqual(@as(usize, 14), economy.items.len);
}

// ============================================================================
// Reducer tests — save select
// ============================================================================

test "reduce: save select navigate" {
    var s = AppState{};
    try t.expectEqual(@as(u8, 0), s.selected_slot);
    dispatch(&s, .down);
    try t.expectEqual(@as(u8, 1), s.selected_slot);
    dispatch(&s, .down);
    try t.expectEqual(@as(u8, 2), s.selected_slot);
    dispatch(&s, .down); // clamp
    try t.expectEqual(@as(u8, 2), s.selected_slot);
    dispatch(&s, .up);
    try t.expectEqual(@as(u8, 1), s.selected_slot);
}

test "reduce: save select confirm active slot" {
    var s = AppState{};
    s.saves[0] = save_mod.newGame(.flame, "Test", 1);
    dispatch(&s, .confirm);
    try t.expectEqual(state_mod.Page.main_map, s.page);
    try t.expectEqual(@as(u8, 0), s.active_slot);
}

test "reduce: save select confirm empty slot → new game" {
    var s = AppState{};
    dispatch(&s, .confirm); // slot 0 is empty
    try t.expectEqual(state_mod.Page.new_game, s.page);
}

test "reduce: save select confirm second slot" {
    var s = AppState{};
    s.saves[1] = save_mod.newGame(.tide, "Wave", 2);
    dispatch(&s, .down); // select slot 1
    dispatch(&s, .confirm);
    try t.expectEqual(state_mod.Page.main_map, s.page);
    try t.expectEqual(@as(u8, 1), s.active_slot);
}

// ============================================================================
// Reducer tests — new game
// ============================================================================

test "reduce: new game select species" {
    var s = AppState{};
    s.page = .new_game;
    dispatch(&s, .right);
    try t.expectEqual(@as(u8, 1), s.new_game_species);
    dispatch(&s, .right);
    try t.expectEqual(@as(u8, 2), s.new_game_species);
    dispatch(&s, .left);
    try t.expectEqual(@as(u8, 1), s.new_game_species);
}

test "reduce: new game confirm creates save" {
    var s = AppState{};
    s.page = .new_game;
    s.selected_slot = 0;
    dispatch(&s, .right); // species 1 = tide
    dispatch(&s, .confirm);
    try t.expectEqual(state_mod.Page.main_map, s.page);
    try t.expect(s.saves[0].active);
    try t.expectEqual(Species.tide, s.saves[0].pet.species);
}

test "reduce: new game back returns to save select" {
    var s = AppState{};
    s.page = .new_game;
    dispatch(&s, .back);
    try t.expectEqual(state_mod.Page.save_select, s.page);
}

// ============================================================================
// Reducer tests — main map
// ============================================================================

test "reduce: main map grid navigation" {
    var s = AppState{};
    s.page = .main_map;
    s.grid_cursor = 4; // center

    dispatch(&s, .up);
    try t.expectEqual(@as(u8, 1), s.grid_cursor); // center → top-center
    dispatch(&s, .left);
    try t.expectEqual(@as(u8, 0), s.grid_cursor); // top-center → top-left
    dispatch(&s, .left); // clamp at left edge
    try t.expectEqual(@as(u8, 0), s.grid_cursor);
    dispatch(&s, .up); // clamp at top edge
    try t.expectEqual(@as(u8, 0), s.grid_cursor);
}

test "reduce: main map grid edges" {
    var s = AppState{};
    s.page = .main_map;
    s.grid_cursor = 8; // bottom-right

    dispatch(&s, .down); // clamp
    try t.expectEqual(@as(u8, 8), s.grid_cursor);
    dispatch(&s, .right); // clamp
    try t.expectEqual(@as(u8, 8), s.grid_cursor);
}

test "reduce: main map confirm enters place" {
    var s = AppState{};
    s.page = .main_map;
    s.grid_cursor = 0; // home

    dispatch(&s, .confirm);
    try t.expectEqual(state_mod.Page.place, s.page);
    try t.expectEqual(state_mod.Place.home, s.current_place);
}

test "reduce: main map confirm each place" {
    const expected = [_]state_mod.Place{ .home, .diner, .school, .clinic, .pet, .gym, .arcade, .lucky, .shop };
    var i: u8 = 0;
    while (i < 9) : (i += 1) {
        var s = AppState{};
        s.page = .main_map;
        s.grid_cursor = i;
        dispatch(&s, .confirm);
        try t.expectEqual(expected[i], s.current_place);
    }
}

test "reduce: main map back returns to save select" {
    var s = AppState{};
    s.page = .main_map;
    dispatch(&s, .back);
    try t.expectEqual(state_mod.Page.save_select, s.page);
}

// ============================================================================
// Reducer tests — place
// ============================================================================

test "reduce: place back returns to main map" {
    var s = AppState{};
    s.page = .place;
    dispatch(&s, .back);
    try t.expectEqual(state_mod.Page.main_map, s.page);
}

// ============================================================================
// Full flow
// ============================================================================

test "full flow: new game → map → place → back → map → back → select" {
    var s = AppState{};

    // Create new game
    dispatch(&s, .confirm); // empty slot → new game
    try t.expectEqual(state_mod.Page.new_game, s.page);
    dispatch(&s, .confirm); // confirm species 0 (flame)
    try t.expectEqual(state_mod.Page.main_map, s.page);
    try t.expect(s.saves[0].active);

    // Navigate to school
    dispatch(&s, .up); // 4→1
    dispatch(&s, .right); // 1→2
    dispatch(&s, .confirm);
    try t.expectEqual(state_mod.Page.place, s.page);
    try t.expectEqual(state_mod.Place.school, s.current_place);

    // Back to map
    dispatch(&s, .back);
    try t.expectEqual(state_mod.Page.main_map, s.page);

    // Back to save select
    dispatch(&s, .back);
    try t.expectEqual(state_mod.Page.save_select, s.page);

    // Re-enter (save is now active)
    dispatch(&s, .confirm);
    try t.expectEqual(state_mod.Page.main_map, s.page);
}
