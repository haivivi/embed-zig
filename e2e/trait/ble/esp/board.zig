//! ESP board for e2e trait/ble — VHCI HCI transport
const std = @import("std");
const idf = @import("idf");

pub const log = std.log.scoped(.e2e);
pub const bt = idf.bt;
