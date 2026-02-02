//! FM175XX NFC Reader IC Driver
//!
//! Platform-independent driver for FM175XX series NFC reader ICs.
//! Compatible with MFRC522, MFRC523, PN512.
//!
//! ## Features
//!
//! - ISO14443A (Type A) support: Mifare, NTAG, etc.
//! - ISO14443B (Type B) support
//! - NTAG/Mifare Ultralight read/write
//! - Hardware CRC calculation
//! - Low Power Card Detection (LPCD)
//!
//! ## Usage
//!
//! ```zig
//! const fm175xx = @import("fm175xx");
//!
//! // Create driver with I2C transport
//! var transport = I2cTransport.init(i2c, 0x28);
//! var nfc = fm175xx.Fm175xx(I2cTransport, Time).init(&transport);
//!
//! // Initialize
//! try nfc.softReset();
//! try nfc.setRf(.both);
//!
//! // Poll for cards
//! if (try nfc.activateTypeA()) |card| {
//!     // Type A card found
//!     var type_a = nfc.TypeA{ .driver = &nfc };
//!     var buf: [16]u8 = undefined;
//!     try type_a.ntagRead(4, &buf);
//! }
//! ```

// Main driver
pub const driver = @import("driver.zig");
pub const Fm175xx = driver.Fm175xx;
pub const RfMode = driver.RfMode;
pub const TransceiveResult = driver.TransceiveResult;

// Register definitions
pub const regs = @import("regs.zig");
pub const Reg = regs.Reg;
pub const Cmd = regs.Cmd;

// Protocol implementations
pub const type_a = @import("type_a.zig");
pub const type_b = @import("type_b.zig");

// Run tests
test {
    _ = regs;
}
