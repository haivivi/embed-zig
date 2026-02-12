//! RSA Signature Verification using mbedTLS
//!
//! Zig wrapper for mbedTLS RSA signature verification operations.
//! Uses C helper to work around mbedTLS 3.x opaque structures.
//!
//! The C helper functions are declared as extern and linked at build time.
//! See: lib/platform/esp/idf/src/mbed_tls/rsa_helper.c

// Extern declarations for C helper functions
extern fn rsa_pkcs1v15_verify(
    modulus: [*]const u8,
    modulus_len: usize,
    exponent: [*]const u8,
    exponent_len: usize,
    hash: [*]const u8,
    hash_len: usize,
    signature: [*]const u8,
    hash_id: c_int,
) c_int;

extern fn rsa_pss_verify(
    modulus: [*]const u8,
    modulus_len: usize,
    exponent: [*]const u8,
    exponent_len: usize,
    hash: [*]const u8,
    hash_len: usize,
    signature: [*]const u8,
    hash_id: c_int,
) c_int;

pub const Error = error{
    SignatureVerificationFailed,
    InvalidPublicKey,
    InvalidSignature,
    InvalidHashAlgorithm,
};

/// Hash algorithm ID for RSA verification
pub const HashId = enum(c_int) {
    sha256 = 0,
    sha384 = 1,
    sha512 = 2,
};

/// RSA PKCS#1 v1.5 signature verification
///
/// Verifies a signature using PKCS#1 v1.5 padding scheme.
/// Supports 2048-bit (256 bytes) and 4096-bit (512 bytes) RSA keys.
pub fn pkcs1v15Verify(
    modulus: []const u8,
    exponent: []const u8,
    hash: []const u8,
    signature: []const u8,
    hash_id: HashId,
) Error!void {
    if (signature.len != modulus.len) {
        return Error.InvalidSignature;
    }

    const ret = rsa_pkcs1v15_verify(
        modulus.ptr,
        modulus.len,
        exponent.ptr,
        exponent.len,
        hash.ptr,
        hash.len,
        signature.ptr,
        @intFromEnum(hash_id),
    );

    if (ret != 0) {
        return Error.SignatureVerificationFailed;
    }
}

/// RSA-PSS signature verification
///
/// Verifies a signature using RSA-PSS padding scheme.
/// Supports 2048-bit (256 bytes) and 4096-bit (512 bytes) RSA keys.
/// Auto-detects salt length.
pub fn pssVerify(
    modulus: []const u8,
    exponent: []const u8,
    hash: []const u8,
    signature: []const u8,
    hash_id: HashId,
) Error!void {
    if (signature.len != modulus.len) {
        return Error.InvalidSignature;
    }

    const ret = rsa_pss_verify(
        modulus.ptr,
        modulus.len,
        exponent.ptr,
        exponent.len,
        hash.ptr,
        hash.len,
        signature.ptr,
        @intFromEnum(hash_id),
    );

    if (ret != 0) {
        return Error.SignatureVerificationFailed;
    }
}
