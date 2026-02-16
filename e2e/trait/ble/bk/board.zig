//! BK board for e2e trait/ble — AP→CP IPC HCI transport
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const bt = bk.armino.ble;
