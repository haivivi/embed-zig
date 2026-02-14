//! ESP board for e2e trait/net_events
const std = @import("std");
const idf = @import("idf");
const esp = @import("esp");

pub const log = std.log.scoped(.e2e);

pub const time = struct {
    pub fn sleepMs(ms: u32) void { idf.time.sleepMs(ms); }
    pub fn nowMs() u64 { return idf.time.nowMs(); }
};

pub const WifiDriver = esp.impl.wifi.StaDriver;
pub const NetDriver = esp.impl.net.NetDriver;
pub const NetEvent = esp.impl.net.NetEvent;
pub const Mutex = idf.runtime.Mutex;
