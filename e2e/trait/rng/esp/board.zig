//! ESP board for e2e trait/rng
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);

pub const rng = struct {
    pub fn fill(buf: []u8) void { idf.random.fill(buf); }
};
