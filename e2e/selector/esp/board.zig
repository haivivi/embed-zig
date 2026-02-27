//! ESP board for e2e selector

const std = @import("std");
const idf = @import("idf");
const impl = @import("impl");

pub const log = std.log.scoped(.e2e_selector);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }

    pub fn nowMs() u64 {
        return idf.time.nowMs();
    }
};

pub const channel = impl.channel;
pub const selector = impl.selector;
