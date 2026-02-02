//! NFC Library
//!
//! Platform-independent NFC (Near Field Communication) library.
//!
//! ## Modules
//!
//! - `card`: Card type definitions (TypeACard, TypeBCard)
//! - `protocol`: ISO14443 command constants
//! - `ndef`: NDEF message parsing and encoding
//!
//! ## Drivers
//!
//! - `fm175xx`: FM175XX NFC reader IC driver
//!
//! ## Usage
//!
//! ```zig
//! const nfc = @import("nfc");
//!
//! // Parse NDEF message
//! const msg = try nfc.ndef.Message.parse(data);
//! if (msg.getFirst()) |record| {
//!     if (record.isUri()) {
//!         const uri = record.getUri(&buf);
//!     }
//! }
//!
//! // Use FM175XX driver
//! const Fm175xx = nfc.drivers.fm175xx.Fm175xx;
//! var reader = Fm175xx(Transport, Time).init(&transport);
//! const card = try reader.activateTypeA();
//! ```

// Common types
pub const card = @import("card.zig");
pub const protocol = @import("protocol.zig");
pub const ndef = @import("ndef.zig");

// Re-export common types for convenience
pub const TypeACard = card.TypeACard;
pub const TypeBCard = card.TypeBCard;
pub const CardType = card.CardType;
pub const CardInfo = card.CardInfo;

// Protocol constants
pub const TypeA = protocol.TypeA;
pub const TypeB = protocol.TypeB;
pub const Ntag = protocol.Ntag;
pub const MifareClassic = protocol.MifareClassic;
pub const NfcError = protocol.NfcError;

// NDEF
pub const NdefRecord = ndef.Record;
pub const NdefMessage = ndef.Message;
pub const Rtd = ndef.Rtd;
pub const UriPrefix = ndef.UriPrefix;

// Run all tests
test {
    _ = card;
    _ = protocol;
    _ = ndef;
}
