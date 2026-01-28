//! Platform-independent Device Drivers
//!
//! This module provides device drivers that work across different platforms
//! by depending on abstract interfaces (e.g., I2C, SPI) rather than
//! platform-specific implementations.
//!
//! Usage:
//!   const drivers = @import("drivers");
//!   const Tca9554 = drivers.Tca9554(MyI2cType);
//!   const Es8311 = drivers.Es8311(MyI2cType);
//!   const Es7210 = drivers.Es7210(MyI2cType);

// GPIO Expander
pub const tca9554 = @import("tca9554.zig");
pub const Tca9554 = tca9554.Tca9554;

// Audio Codecs
pub const es8311 = @import("es8311.zig");
pub const Es8311 = es8311.Es8311;

pub const es7210 = @import("es7210.zig");
pub const Es7210 = es7210.Es7210;

test {
    _ = tca9554;
    _ = es8311;
    _ = es7210;
}
