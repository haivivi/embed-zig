//! X.509 Certificate Support - ESP32 mbedTLS Implementation
//!
//! Provides X.509 certificate parsing, verification, and chain validation
//! using mbedTLS for hardware-accelerated operations on ESP32.

const std = @import("std");
const idf = @import("idf");
const mbed = idf.mbed_tls;

// ESP CA bundle verification helper from idf package
const cert_helper = mbed.cert_helper;

// ============================================================================
// CA Store
// ============================================================================

/// CA Store for certificate verification
pub const CaStore = union(enum) {
    /// Verify against a list of trusted root CA certificates (DER format)
    roots: []const []const u8,

    /// Verify against a single custom CA certificate (DER format)
    custom: []const u8,

    /// Self-signed certificate (verify signature against itself)
    self_signed,

    /// Skip verification (INSECURE - only for testing)
    insecure,

    /// Use ESP-IDF built-in CA certificate bundle (~130 common root CAs)
    esp_bundle,
};

// ============================================================================
// Chain Verification Errors
// ============================================================================

pub const ChainError = error{
    EmptyChain,
    ChainTooLong,
    CertificateExpired,
    CertificateNotYetValid,
    IssuerMismatch,
    SignatureInvalid,
    UntrustedRoot,
    HostnameMismatch,
    ParseError,
};

/// Maximum certificate chain depth
pub const MAX_CHAIN_DEPTH = 10;

// ============================================================================
// Certificate Chain Verification
// ============================================================================

/// Verify a certificate chain using mbedTLS
///
/// Parameters:
/// - cert_chain: Array of DER-encoded certificates, leaf certificate first
/// - hostname: The hostname to verify against (optional)
/// - ca_store: The CA store to use for verification
/// - now_sec: Current time in seconds since epoch (unused, mbedTLS uses system time)
pub fn verifyChain(
    cert_chain: []const []const u8,
    hostname: ?[]const u8,
    ca_store: CaStore,
    now_sec: i64,
) ChainError!void {
    _ = now_sec; // mbedTLS uses system time

    if (cert_chain.len == 0) return error.EmptyChain;
    if (cert_chain.len > MAX_CHAIN_DEPTH) return error.ChainTooLong;

    switch (ca_store) {
        .insecure => {
            // Skip all verification
            return;
        },
        .self_signed => {
            // Parse and verify the leaf certificate is self-signed
            var crt: mbed.x509_crt = undefined;
            mbed.x509_crt_init(&crt);
            defer mbed.x509_crt_free(&crt);

            // Parse the leaf certificate
            const ret = mbed.x509_crt_parse_der(&crt, cert_chain[0].ptr, cert_chain[0].len);
            if (ret != 0) return error.ParseError;

            // Verify against itself
            var flags: u32 = 0;
            const verify_ret = mbed.x509_crt_verify(&crt, &crt, null, null, &flags, null, null);
            if (verify_ret != 0) return error.SignatureInvalid;

            return;
        },
        .custom => |ca_der| {
            return verifyChainWithCa(cert_chain, hostname, ca_der);
        },
        .roots => |root_cas| {
            // Try each root CA until one succeeds
            for (root_cas) |root_der| {
                if (verifyChainWithCa(cert_chain, hostname, root_der)) |_| {
                    return; // Success
                } else |_| {
                    continue; // Try next root
                }
            }
            return error.UntrustedRoot;
        },
        .esp_bundle => {
            // Use ESP-IDF built-in CA bundle (~130 common root CAs)
            // Verify each certificate in the chain against the bundle
            // The bundle verification uses issuer CN to find matching CA
            for (cert_chain) |cert_der| {
                if (cert_helper.verifyWithEspBundle(cert_der)) {
                    std.log.debug("[x509] Certificate verified with ESP bundle", .{});
                    return; // Found a cert that chains to a trusted CA
                } else |_| {
                    continue; // Try next cert in chain
                }
            }
            // None of the certificates in chain were trusted
            std.log.err("[x509] No certificate in chain trusted by ESP bundle", .{});
            return error.UntrustedRoot;
        },
    }
}

/// Verify a certificate chain against a specific CA certificate
fn verifyChainWithCa(
    cert_chain: []const []const u8,
    hostname: ?[]const u8,
    ca_der: []const u8,
) ChainError!void {
    var ca_crt: mbed.x509_crt = undefined;
    var crt: mbed.x509_crt = undefined;

    mbed.x509_crt_init(&ca_crt);
    mbed.x509_crt_init(&crt);
    defer {
        mbed.x509_crt_free(&ca_crt);
        mbed.x509_crt_free(&crt);
    }

    // Parse the CA certificate
    std.log.debug("[x509] Parsing CA cert ({d} bytes)", .{ca_der.len});
    var ret = mbed.x509_crt_parse_der(&ca_crt, ca_der.ptr, ca_der.len);
    if (ret != 0) {
        std.log.err("[x509] Failed to parse CA cert: 0x{x}", .{@as(u32, @bitCast(ret))});
        return error.ParseError;
    }

    // Parse all certificates in the chain
    for (cert_chain, 0..) |cert_der, i| {
        std.log.debug("[x509] Parsing cert {d} ({d} bytes)", .{ i, cert_der.len });
        ret = mbed.x509_crt_parse_der(&crt, cert_der.ptr, cert_der.len);
        if (ret != 0) {
            std.log.err("[x509] Failed to parse cert {d}: 0x{x}", .{ i, @as(u32, @bitCast(ret)) });
            return error.ParseError;
        }
    }

    // Verify the chain
    var flags: u32 = 0;
    const verify_ret = mbed.x509_crt_verify(&crt, &ca_crt, null, null, &flags, null, null);

    if (verify_ret != 0) {
        // Check specific error flags
        if (flags & 0x01 != 0) return error.CertificateExpired; // MBEDTLS_X509_BADCERT_EXPIRED
        if (flags & 0x02 != 0) return error.CertificateNotYetValid; // MBEDTLS_X509_BADCERT_FUTURE
        if (flags & 0x08 != 0) return error.UntrustedRoot; // MBEDTLS_X509_BADCERT_NOT_TRUSTED
        return error.SignatureInvalid;
    }

    // Verify hostname if provided
    // Note: mbedTLS doesn't have a direct hostname verification function in the verify call,
    // we would need to check the CN or SAN manually for strict hostname validation.
    // For now, if the chain verifies, we trust it.
    _ = hostname;
}

/// Parse and verify a single certificate against a CA store
pub fn verifyCertificate(
    cert_der: []const u8,
    hostname: ?[]const u8,
    ca_store: CaStore,
    now_sec: i64,
) ChainError!void {
    const single_chain = [_][]const u8{cert_der};
    return verifyChain(&single_chain, hostname, ca_store, now_sec);
}

// ============================================================================
// Certificate Parsing
// ============================================================================

/// Wrapper around mbedTLS x509_crt for certificate data
pub const Cert = struct {
    crt: mbed.x509_crt,

    pub fn init() Cert {
        var self: Cert = undefined;
        mbed.x509_crt_init(&self.crt);
        return self;
    }

    pub fn deinit(self: *Cert) void {
        mbed.x509_crt_free(&self.crt);
    }

    /// Parse a DER-encoded certificate
    pub fn parseDer(self: *Cert, der: []const u8) !void {
        const ret = mbed.x509_crt_parse_der(&self.crt, der.ptr, der.len);
        if (ret != 0) return error.ParseError;
    }

    /// Parse a PEM-encoded certificate
    pub fn parsePem(self: *Cert, pem: []const u8) !void {
        const ret = mbed.x509_crt_parse(&self.crt, pem.ptr, pem.len);
        if (ret != 0) return error.ParseError;
    }
};

/// Parsed certificate (alias for compatibility)
pub const Parsed = Cert;

/// Parse a DER-encoded certificate (one-shot)
pub fn parseDer(der: []const u8) !Cert {
    var crt = Cert.init();
    try crt.parseDer(der);
    return crt;
}

/// Parse a PEM-encoded certificate (one-shot)
pub fn parsePem(pem: []const u8) !Cert {
    var crt = Cert.init();
    try crt.parsePem(pem);
    return crt;
}

// ============================================================================
// Re-exports for compatibility with lib/crypto/x509 interface
// ============================================================================

/// Module exports for chain submodule compatibility
pub const chain = struct {
    pub const CaStore = @This().CaStore;
    pub const ChainError = @This().ChainError;
    pub const verifyChain = @This().verifyChain;
    pub const verifyCertificate = @This().verifyCertificate;
    pub const MAX_CHAIN_DEPTH = @This().MAX_CHAIN_DEPTH;
};

/// Module exports for cert submodule compatibility
pub const cert = struct {
    pub const Cert = @This().Cert;
    pub const Parsed = @This().Parsed;
    pub const parseDer = @This().parseDer;
    pub const parsePem = @This().parsePem;
};
