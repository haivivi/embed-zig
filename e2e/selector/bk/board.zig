//! BK board for e2e selector

const bk = @import("bk");

pub const log = bk.impl.log.scoped("e2e_selector");

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        bk.impl.Time.sleepMs(ms);
    }

    pub fn nowMs() u64 {
        return bk.impl.Time.nowMs();
    }
};

pub const channel = bk.impl.channel;
pub const selector = bk.impl.selector;
