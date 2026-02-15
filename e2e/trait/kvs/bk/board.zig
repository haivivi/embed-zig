//! BK board for e2e trait/kvs
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const Nvs = bk.impl.KvsDriver;
