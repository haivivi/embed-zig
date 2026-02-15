//! BK board for e2e trait/spawner
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const time = struct {
    pub fn sleepMs(ms: u32) void { bk.impl.Time.sleepMs(ms); }
    pub fn nowMs() u64 { return bk.impl.Time.nowMs(); }
};
pub const runtime = bk.armino.runtime;
