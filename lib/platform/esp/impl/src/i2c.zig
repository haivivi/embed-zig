//! I2C Implementation for ESP32
//!
//! Implements trait.i2c using idf.i2c (ESP-IDF I2C master driver).
//!
//! Usage:
//!   const impl = @import("impl");
//!   const trait = @import("trait");
//!   const I2c = trait.i2c.from(impl.I2c);

const idf = @import("idf");

// Re-export idf.i2c.I2c as the implementation
pub const I2c = idf.I2c;

// Re-export types
pub const Config = idf.i2c.Config;
pub const Error = idf.i2c.Error;
