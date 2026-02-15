//! ESP board for e2e trait/time
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);

pub const time = struct {
    pub fn sleepMs(ms: u32) void { idf.time.sleepMs(ms); }
    pub fn nowMs() u64 { return idf.time.nowMs(); }
};
