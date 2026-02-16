//! X.509 Certificate Support — BK7258 mbedTLS Implementation
//!
//! Provides X.509 certificate chain verification using mbedTLS via C helper.
//! Mirrors ESP platform's cert.zig interface.

const std = @import("std");

// C helper for x509 operations (wraps mbedTLS x509_crt_*)
extern fn bk_zig_x509_verify_chain(
    certs_der: [*]const [*]const u8,
    certs_len: [*]const c_uint,
    cert_count: c_uint,
    ca_der: ?[*]const u8,
    ca_der_len: c_uint,
) c_int;

extern fn bk_zig_x509_cert_info(
    der: [*]const u8,
    der_len: c_uint,
    subject_buf: ?[*]u8,
    subject_size: c_uint,
    issuer_buf: ?[*]u8,
    issuer_size: c_uint,
) c_int;

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

    /// Skip verification (INSECURE — only for testing)
    insecure,
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

/// Verify a certificate chain using mbedTLS (via C helper)
pub fn verifyChain(
    cert_chain: []const []const u8,
    hostname: ?[]const u8,
    ca_store: CaStore,
    now_sec: i64,
) ChainError!void {
    _ = now_sec; // mbedTLS uses its own time
    _ = hostname; // TODO: hostname verification

    if (cert_chain.len == 0) return error.EmptyChain;
    if (cert_chain.len > MAX_CHAIN_DEPTH) return error.ChainTooLong;

    switch (ca_store) {
        .insecure => return,
        .self_signed => {
            // Verify leaf cert against itself
            var ptrs: [1][*]const u8 = .{cert_chain[0].ptr};
            var lens: [1]c_uint = .{@intCast(cert_chain[0].len)};
            const ret = bk_zig_x509_verify_chain(&ptrs, &lens, 1, cert_chain[0].ptr, @intCast(cert_chain[0].len));
            if (ret != 0) return error.SignatureInvalid;
        },
        .custom => |ca_der| {
            return verifyChainWithCa(cert_chain, ca_der);
        },
        .roots => |root_cas| {
            for (root_cas) |root_der| {
                if (verifyChainWithCa(cert_chain, root_der)) |_| {
                    return; // Success
                } else |_| {
                    continue;
                }
            }
            return error.UntrustedRoot;
        },
    }
}

fn verifyChainWithCa(cert_chain: []const []const u8, ca_der: []const u8) ChainError!void {
    // Build pointer/length arrays for C helper
    var ptrs: [MAX_CHAIN_DEPTH][*]const u8 = undefined;
    var lens: [MAX_CHAIN_DEPTH]c_uint = undefined;

    for (cert_chain, 0..) |cert, i| {
        ptrs[i] = cert.ptr;
        lens[i] = @intCast(cert.len);
    }

    const ret = bk_zig_x509_verify_chain(
        &ptrs,
        &lens,
        @intCast(cert_chain.len),
        ca_der.ptr,
        @intCast(ca_der.len),
    );

    if (ret == 0) return;

    // Positive = mbedTLS verify flags
    if (ret > 0) {
        const flags: u32 = @intCast(ret);
        if (flags & 0x01 != 0) return error.CertificateExpired;
        if (flags & 0x02 != 0) return error.CertificateNotYetValid;
        if (flags & 0x08 != 0) return error.UntrustedRoot;
        return error.SignatureInvalid;
    }

    // Negative = mbedTLS error code
    return error.ParseError;
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
// Re-exports for compatibility with lib/pkg/tls interface
// ============================================================================

pub const chain = struct {
    pub const CaStore_ = CaStore;
    pub const ChainError_ = ChainError;
    pub const verifyChain_ = verifyChain;
    pub const verifyCertificate_ = verifyCertificate;
    pub const MAX_CHAIN_DEPTH_ = MAX_CHAIN_DEPTH;
};
