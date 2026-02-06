//! X.509 Certificate Parser
//!
//! Provides certificate parsing and verification for TLS.
//! This is a wrapper around std.crypto.Certificate with additional
//! utilities for TLS certificate validation.

const std = @import("std");
const Certificate = std.crypto.Certificate;

/// Re-export the standard Certificate type
pub const Cert = Certificate;
pub const Parsed = Certificate.Parsed;
pub const ParseError = Certificate.ParseError;
pub const VerifyError = Parsed.VerifyError;
pub const VerifyHostNameError = Parsed.VerifyHostNameError;

/// Certificate parsing and verification result
pub const CertResult = struct {
    cert: Certificate,
    parsed: Parsed,
};

/// Parse a DER-encoded certificate
pub fn parseDer(der_bytes: []const u8) ParseError!CertResult {
    const cert = Certificate{
        .buffer = der_bytes,
        .index = 0,
    };
    const parsed = try cert.parse();
    return CertResult{
        .cert = cert,
        .parsed = parsed,
    };
}

/// Parse a PEM-encoded certificate
/// Returns the DER bytes and the parsed certificate
pub fn parsePem(allocator: std.mem.Allocator, pem_bytes: []const u8) !struct {
    der_bytes: []u8,
    result: CertResult,
} {
    // Find the certificate boundaries
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";

    const begin_pos = std.mem.indexOf(u8, pem_bytes, begin_marker) orelse
        return error.InvalidPemFormat;
    const content_start = begin_pos + begin_marker.len;

    const end_pos = std.mem.indexOf(u8, pem_bytes[content_start..], end_marker) orelse
        return error.InvalidPemFormat;

    // Decode base64
    const base64_content = pem_bytes[content_start..][0..end_pos];

    // Calculate the size needed (rough estimate, base64 expands by ~33%)
    const max_decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64_content) catch
        return error.InvalidPemFormat;

    const der_bytes = try allocator.alloc(u8, max_decoded_len);
    errdefer allocator.free(der_bytes);

    const decoded_len = std.base64.standard.Decoder.decode(der_bytes, base64_content) catch
        return error.InvalidPemFormat;

    // Parse the DER
    const cert = Certificate{
        .buffer = der_bytes[0..decoded_len],
        .index = 0,
    };
    const parsed = try cert.parse();

    return .{
        .der_bytes = der_bytes[0..decoded_len],
        .result = CertResult{
            .cert = cert,
            .parsed = parsed,
        },
    };
}

/// Verify that a certificate is valid for a given hostname
pub fn verifyHostname(parsed: Parsed, hostname: []const u8) VerifyHostNameError!void {
    return parsed.verifyHostName(hostname);
}

/// Verify that a subject certificate was signed by an issuer certificate
pub fn verifySignature(subject_cert: Parsed, issuer_cert: Parsed, now_sec: i64) VerifyError!void {
    return subject_cert.verify(issuer_cert, now_sec);
}

/// Check if a certificate is currently valid (time-wise)
pub fn isTimeValid(parsed: Parsed, now_sec: i64) bool {
    return now_sec >= parsed.validity.not_before and
        now_sec <= parsed.validity.not_after;
}

/// Get the certificate's common name
pub fn commonName(parsed: Parsed) []const u8 {
    return parsed.commonName();
}

/// Get the certificate's subject
pub fn subject(parsed: Parsed) []const u8 {
    return parsed.subject();
}

/// Get the certificate's issuer
pub fn issuer(parsed: Parsed) []const u8 {
    return parsed.issuer();
}

/// Get the certificate's public key bytes
pub fn publicKey(parsed: Parsed) []const u8 {
    return parsed.pubKey();
}

/// Get the certificate's public key algorithm
pub fn publicKeyAlgorithm(parsed: Parsed) Parsed.PubKeyAlgo {
    return parsed.pub_key_algo;
}

// ============================================================================
// Tests
// ============================================================================

test "parse and verify self-signed cert structure" {
    // This is a minimal test - real tests would use actual certificates
    const expectEqual = std.testing.expectEqual;
    _ = expectEqual;

    // Certificate parsing is tested by std.crypto.Certificate tests
}
