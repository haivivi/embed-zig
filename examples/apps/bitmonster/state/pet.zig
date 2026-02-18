//! Pet — attributes, aptitude, species, decay

pub const Species = enum(u8) { flame, tide, thorn, iron, muddy };

pub const Aptitude = struct {
    health: u8 = 100, // 80-120
    spirit: u8 = 100,
    luck: u8 = 100,

    pub fn roll(seed: u32) Aptitude {
        var rng = seed;
        return .{
            .health = 80 + @as(u8, @intCast(xorshift(&rng) % 41)),
            .spirit = 80 + @as(u8, @intCast(xorshift(&rng) % 41)),
            .luck = 80 + @as(u8, @intCast(xorshift(&rng) % 41)),
        };
    }
};

pub const Pet = struct {
    alive: bool = true,
    species: Species = .flame,
    name: [8]u8 = .{0} ** 8,
    name_len: u8 = 0,
    level: u16 = 1,
    exp: u64 = 0,
    aptitude: Aptitude = .{},

    health: u8 = 100,
    spirit: u8 = 100,
    luck: u8 = 50,

    last_bath_time: u32 = 0,
    last_toilet_time: u32 = 0,
    last_clean_time: u32 = 0,

    death_count: u8 = 0,
    merit: u32 = 0,

    pub fn expToNextLevel(self: *const Pet) u64 {
        const lvl: u64 = self.level;
        return lvl * lvl * 100;
    }

    pub fn addExp(self: *Pet, amount: u64) void {
        self.exp += amount;
        while (self.exp >= self.expToNextLevel()) {
            self.exp -= self.expToNextLevel();
            self.level += 1;
        }
    }

    pub fn applyDecay(self: *Pet, elapsed_hours: u32, config: DecayConfig) void {
        self.health = saturatingSub(self.health, elapsed_hours * config.health_per_hour);
        self.spirit = saturatingSub(self.spirit, elapsed_hours * config.spirit_per_hour);
        self.luck = saturatingSub(self.luck, elapsed_hours * config.luck_per_hour);

        if (self.health == 0) self.alive = false;
    }

    pub fn useItem(self: *Pet, base_restore: u8, attr: Attr) void {
        const apt: u8 = switch (attr) {
            .health => self.aptitude.health,
            .spirit => self.aptitude.spirit,
            .luck => self.aptitude.luck,
        };
        const actual = @as(u16, base_restore) * apt / 100;
        const restore: u8 = @intCast(@min(actual, 255));
        switch (attr) {
            .health => self.health = @min(100, self.health + restore),
            .spirit => self.spirit = @min(100, self.spirit + restore),
            .luck => self.luck = @min(100, self.luck + restore),
        }
    }

    pub fn setName(self: *Pet, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 8));
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const Pet) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn revivalCost(self: *const Pet) u64 {
        const base: u64 = 100;
        var cost = base;
        var i: u8 = 0;
        while (i < self.death_count) : (i += 1) cost *= 2;
        return cost;
    }
};

pub const Attr = enum { health, spirit, luck };

pub const DecayConfig = struct {
    health_per_hour: u8 = 4,
    spirit_per_hour: u8 = 3,
    luck_per_hour: u8 = 1,
};

pub const default_decay = DecayConfig{};

fn saturatingSub(a: u8, b: u32) u8 {
    if (b >= a) return 0;
    return a - @as(u8, @intCast(b));
}

fn xorshift(state: *u32) u32 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.* = x;
    return x;
}
