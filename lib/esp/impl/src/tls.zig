//! TLS Implementation for ESP32
//!
//! Implements trait.tls using idf.tls (mbedTLS).
//!
//! Usage:
//!   const impl = @import("impl");
//!   const trait = @import("trait");
//!   const TlsStream = trait.tls.from(impl.TlsStream);

const idf = @import("idf");

// Re-export idf.tls.TlsStream as the implementation
pub const TlsStream = idf.TlsStream;

// Re-export types
pub const TlsError = idf.tls.TlsError;
pub const Options = idf.tls.Options;

// Re-export functions
pub const create = idf.tls.create;
