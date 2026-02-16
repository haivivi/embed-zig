//! BK board for e2e trait/rng
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const rng = struct {
    pub fn fill(buf: []u8) void { bk.impl.crypto.Suite.Rng.fill(buf); }
};
