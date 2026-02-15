//! ESP board for e2e trait/crypto
//! Uses ESP mbedTLS-based crypto suite (hardware accelerated).
const std = @import("std");
const esp = @import("esp");

pub const log = std.log.scoped(.e2e);
pub const Crypto = esp.impl.crypto.Suite;
