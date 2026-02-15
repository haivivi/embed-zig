//! BK board for e2e trait/net_events
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const time = struct {
    pub fn sleepMs(ms: u32) void { bk.impl.Time.sleepMs(ms); }
    pub fn nowMs() u64 { return bk.impl.Time.nowMs(); }
};
pub const WifiDriver = bk.impl.WifiDriver;
pub const NetDriver = bk.impl.NetDriver;
pub const NetEvent = bk.impl.NetEvent;
pub const Mutex = bk.armino.runtime.Mutex;
