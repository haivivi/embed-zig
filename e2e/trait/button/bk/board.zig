//! BK board for e2e hal/button (BK7258 boot button GPIO22)
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const ButtonDriver = bk.boards.bk7258.BootButtonDriver;
