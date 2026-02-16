//! BK board for e2e trait/log
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
