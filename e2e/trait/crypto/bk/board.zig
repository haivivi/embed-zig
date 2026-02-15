//! BK board for e2e trait/crypto
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const Crypto = bk.impl.crypto.Suite;
