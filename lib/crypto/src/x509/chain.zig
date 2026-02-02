//! Certificate Chain Verification
//!
//! Provides certificate chain validation for TLS.
//! Verifies that a certificate chain is valid from leaf to root.

const std = @import("std");
const cert_mod = @import("cert.zig");
const Certificate = std.crypto.Certificate;
const Parsed = Certificate.Parsed;

/// Maximum certificate chain depth
pub const MAX_CHAIN_DEPTH = 10;

/// Certificate chain verification errors
pub const ChainError = error{
    /// The certificate chain is empty
    EmptyChain,
    /// The certificate chain is too long
    ChainTooLong,
    /// A certificate in the chain has expired
    CertificateExpired,
    /// A certificate in the chain is not yet valid
    CertificateNotYetValid,
    /// The certificate issuer does not match
    IssuerMismatch,
    /// The certificate signature is invalid
    SignatureInvalid,
    /// The root CA is not trusted
    UntrustedRoot,
    /// The hostname does not match the certificate
    HostnameMismatch,
    /// Certificate parsing failed
    ParseError,
};

/// CA Store for certificate verification
pub const CaStore = union(enum) {
    /// Verify against a list of trusted root CA certificates (DER format)
    /// The slice points to memory that can be in Flash or PSRAM
    roots: []const []const u8,

    /// Verify against a single custom CA certificate
    custom: []const u8,

    /// Self-signed certificate (verify signature against itself)
    self_signed,

    /// Skip verification (INSECURE - only for testing)
    insecure,
};

/// Verify a certificate chain
///
/// Parameters:
/// - chain: Array of DER-encoded certificates, leaf certificate first
/// - hostname: The hostname to verify against (optional)
/// - ca_store: The CA store to use for verification
/// - now_sec: Current time in seconds since epoch
///
/// Returns error if verification fails, void on success
pub fn verifyChain(
    chain: []const []const u8,
    hostname: ?[]const u8,
    ca_store: CaStore,
    now_sec: i64,
) ChainError!void {
    if (chain.len == 0) return error.EmptyChain;
    if (chain.len > MAX_CHAIN_DEPTH) return error.ChainTooLong;

    // Parse the leaf certificate
    const leaf_cert = Certificate{ .buffer = chain[0], .index = 0 };
    const leaf_parsed = leaf_cert.parse() catch return error.ParseError;

    // Verify hostname if provided
    if (hostname) |host| {
        leaf_parsed.verifyHostName(host) catch return error.HostnameMismatch;
    }

    // Check time validity of leaf
    if (!cert_mod.isTimeValid(leaf_parsed, now_sec)) {
        if (now_sec < leaf_parsed.validity.not_before) {
            return error.CertificateNotYetValid;
        } else {
            return error.CertificateExpired;
        }
    }

    switch (ca_store) {
        .insecure => {
            // Skip all verification
            return;
        },
        .self_signed => {
            // Verify leaf is self-signed
            leaf_parsed.verify(leaf_parsed, now_sec) catch return error.SignatureInvalid;
            return;
        },
        .custom => |ca_der| {
            // Verify chain ends at the custom CA
            return verifyChainAgainstCa(chain, ca_der, now_sec);
        },
        .roots => |root_cas| {
            // Try to find a trusted root that validates the chain
            for (root_cas) |root_der| {
                if (verifyChainAgainstCa(chain, root_der, now_sec)) |_| {
                    return; // Success
                } else |_| {
                    continue; // Try next root
                }
            }
            return error.UntrustedRoot;
        },
    }
}

/// Verify a certificate chain against a specific CA
fn verifyChainAgainstCa(
    chain: []const []const u8,
    ca_der: []const u8,
    now_sec: i64,
) ChainError!void {
    // Parse the CA certificate
    const ca_cert = Certificate{ .buffer = ca_der, .index = 0 };
    const ca_parsed = ca_cert.parse() catch return error.ParseError;

    // Walk the chain from leaf to root
    var prev_parsed: Parsed = undefined;

    for (chain, 0..) |cert_der, i| {
        const cert = Certificate{ .buffer = cert_der, .index = 0 };
        const parsed = cert.parse() catch return error.ParseError;

        // Check time validity
        if (!cert_mod.isTimeValid(parsed, now_sec)) {
            if (now_sec < parsed.validity.not_before) {
                return error.CertificateNotYetValid;
            } else {
                return error.CertificateExpired;
            }
        }

        // Verify signature (except for leaf, which we verify against its issuer)
        if (i > 0) {
            // Verify prev_parsed was signed by this certificate
            prev_parsed.verify(parsed, now_sec) catch return error.SignatureInvalid;
        }

        // Check if this certificate was signed by the CA
        if (std.mem.eql(u8, parsed.issuer(), ca_parsed.subject())) {
            // This cert claims to be signed by the CA - verify it
            parsed.verify(ca_parsed, now_sec) catch return error.SignatureInvalid;
            return; // Chain verified successfully
        }

        prev_parsed = parsed;
    }

    // If we get here, we didn't find a path to the CA
    // Try verifying the last certificate against the CA directly
    prev_parsed.verify(ca_parsed, now_sec) catch return error.SignatureInvalid;
}

/// Parse and verify a single certificate against a CA store
pub fn verifyCertificate(
    cert_der: []const u8,
    hostname: ?[]const u8,
    ca_store: CaStore,
    now_sec: i64,
) ChainError!Parsed {
    const chain = [_][]const u8{cert_der};
    try verifyChain(&chain, hostname, ca_store, now_sec);

    const cert = Certificate{ .buffer = cert_der, .index = 0 };
    return cert.parse() catch return error.ParseError;
}

// ============================================================================
// Tests
// ============================================================================

test "ChainError variants" {
    // Ensure all error variants are defined
    const errors = [_]ChainError{
        error.EmptyChain,
        error.ChainTooLong,
        error.CertificateExpired,
        error.CertificateNotYetValid,
        error.IssuerMismatch,
        error.SignatureInvalid,
        error.UntrustedRoot,
        error.HostnameMismatch,
        error.ParseError,
    };
    _ = errors;
}

test "CaStore variants" {
    // Test that CaStore can be constructed
    const insecure = CaStore{ .insecure = {} };
    const self_signed = CaStore{ .self_signed = {} };
    _ = insecure;
    _ = self_signed;
}
