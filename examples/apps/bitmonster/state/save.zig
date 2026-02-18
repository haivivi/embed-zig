//! Save — save slot management, inventory

const pet_mod = @import("pet.zig");
const Pet = pet_mod.Pet;

pub const MAX_SLOTS = 3;
pub const INVENTORY_SIZE = 12;

pub const ItemSlot = struct {
    item_id: u8 = 0,
    quantity: u8 = 0,

    pub fn isEmpty(self: ItemSlot) bool {
        return self.quantity == 0;
    }
};

pub const SaveSlot = struct {
    active: bool = false,
    pet: Pet = .{},
    inventory: [INVENTORY_SIZE]ItemSlot = [_]ItemSlot{.{}} ** INVENTORY_SIZE,

    pub fn inventoryCount(self: *const SaveSlot) u8 {
        var count: u8 = 0;
        for (self.inventory) |slot| {
            if (!slot.isEmpty()) count += 1;
        }
        return count;
    }

    pub fn addItem(self: *SaveSlot, item_id: u8, qty: u8) bool {
        // Try stacking on existing slot
        for (&self.inventory) |*slot| {
            if (slot.item_id == item_id and slot.quantity > 0) {
                const new_qty = @as(u16, slot.quantity) + qty;
                slot.quantity = @intCast(@min(new_qty, 255));
                return true;
            }
        }
        // Find empty slot
        for (&self.inventory) |*slot| {
            if (slot.isEmpty()) {
                slot.item_id = item_id;
                slot.quantity = qty;
                return true;
            }
        }
        return false; // inventory full
    }

    pub fn removeItem(self: *SaveSlot, item_id: u8, qty: u8) bool {
        for (&self.inventory) |*slot| {
            if (slot.item_id == item_id and slot.quantity >= qty) {
                slot.quantity -= qty;
                return true;
            }
        }
        return false;
    }

    pub fn hasItem(self: *const SaveSlot, item_id: u8) bool {
        for (self.inventory) |slot| {
            if (slot.item_id == item_id and slot.quantity > 0) return true;
        }
        return false;
    }

    pub fn getItemQty(self: *const SaveSlot, item_id: u8) u8 {
        for (self.inventory) |slot| {
            if (slot.item_id == item_id and slot.quantity > 0) return slot.quantity;
        }
        return 0;
    }
};

pub fn newGame(species: pet_mod.Species, name: []const u8, seed: u32) SaveSlot {
    var slot = SaveSlot{ .active = true };
    slot.pet.species = species;
    slot.pet.setName(name);
    slot.pet.aptitude = pet_mod.Aptitude.roll(seed);
    return slot;
}
