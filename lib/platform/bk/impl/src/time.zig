//! Time Implementation for BK7258

const armino = @import("../../armino/src/armino.zig");

pub const Time = struct {
    pub fn sleepMs(ms: u32) void {
        armino.time.sleepMs(ms);
    }
    pub fn getTimeMs() u64 {
        return armino.time.nowMs();
    }
};

pub const sleepMs = armino.time.sleepMs;
pub const nowMs = armino.time.nowMs;
