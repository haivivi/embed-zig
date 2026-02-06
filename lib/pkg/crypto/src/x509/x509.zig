//! X.509 Certificate Support
//!
//! Provides X.509 certificate parsing, verification, and chain validation
//! for TLS implementations.
//!
//! ## Usage
//!
//! ```zig
//! const x509 = @import("crypto").x509;
//!
//! // Parse a DER certificate
//! const result = try x509.cert.parseDer(der_bytes);
//!
//! // Verify hostname
//! try x509.cert.verifyHostname(result.parsed, "example.com");
//!
//! // Verify certificate chain
//! const chain = &[_][]const u8{ leaf_cert, intermediate_cert };
//! try x509.chain.verifyChain(chain, "example.com", ca_store, now_sec);
//! ```

pub const cert = @import("cert.zig");
pub const chain = @import("chain.zig");

// Re-export common types
pub const Cert = cert.Cert;
pub const Parsed = cert.Parsed;
pub const CaStore = chain.CaStore;
pub const ChainError = chain.ChainError;

// Re-export common functions
pub const parseDer = cert.parseDer;
pub const parsePem = cert.parsePem;
pub const verifyChain = chain.verifyChain;
pub const verifyCertificate = chain.verifyCertificate;

test {
    _ = cert;
    _ = chain;
}
