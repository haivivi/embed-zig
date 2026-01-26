//! Platform-independent Device Drivers
//!
//! This module provides device drivers that work across different platforms
//! by depending on abstract interfaces (e.g., I2C, SPI) rather than
//! platform-specific implementations.
//!
//! Usage:
//!   const drivers = @import("drivers");
//!   const Tca9554 = drivers.Tca9554(MyI2cType);

pub const tca9554 = @import("tca9554.zig");
pub const Tca9554 = tca9554.Tca9554;

test {
    _ = tca9554;
}
