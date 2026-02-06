//! HKDF wrapper for mbedTLS C helper
//!
//! This module wraps the C helper functions that implement HKDF
//! using mbedTLS's HMAC functions. This avoids dependency on the
//! mbedTLS HKDF module which may not be enabled in some ESP-IDF
//! configurations.

// Extern declarations for C helper functions
extern fn hkdf_extract(
    salt: ?[*]const u8,
    salt_len: usize,
    ikm: [*]const u8,
    ikm_len: usize,
    prk: [*]u8,
    hash_len: usize,
) c_int;

extern fn hkdf_expand(
    prk: [*]const u8,
    prk_len: usize,
    info: ?[*]const u8,
    info_len: usize,
    okm: [*]u8,
    okm_len: usize,
) c_int;

pub const Error = error{HkdfError};

/// HKDF-SHA256
pub const Sha256 = struct {
    pub const prk_length = 32;

    /// Extract: salt is optional (null = zero-filled)
    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        var prk: [prk_length]u8 = undefined;
        const salt_ptr = if (salt) |s| s.ptr else null;
        const salt_len = if (salt) |s| s.len else 0;
        _ = hkdf_extract(salt_ptr, salt_len, ikm.ptr, ikm.len, &prk, prk_length);
        return prk;
    }

    /// Expand PRK into output keying material
    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        var okm: [len]u8 = undefined;
        const info_ptr = if (info.len > 0) info.ptr else null;
        _ = hkdf_expand(prk, prk_length, info_ptr, info.len, &okm, len);
        return okm;
    }
};

/// HKDF-SHA384
pub const Sha384 = struct {
    pub const prk_length = 48;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        var prk: [prk_length]u8 = undefined;
        const salt_ptr = if (salt) |s| s.ptr else null;
        const salt_len = if (salt) |s| s.len else 0;
        _ = hkdf_extract(salt_ptr, salt_len, ikm.ptr, ikm.len, &prk, prk_length);
        return prk;
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        var okm: [len]u8 = undefined;
        const info_ptr = if (info.len > 0) info.ptr else null;
        _ = hkdf_expand(prk, prk_length, info_ptr, info.len, &okm, len);
        return okm;
    }
};

/// HKDF-SHA512
pub const Sha512 = struct {
    pub const prk_length = 64;

    pub fn extract(salt: ?[]const u8, ikm: []const u8) [prk_length]u8 {
        var prk: [prk_length]u8 = undefined;
        const salt_ptr = if (salt) |s| s.ptr else null;
        const salt_len = if (salt) |s| s.len else 0;
        _ = hkdf_extract(salt_ptr, salt_len, ikm.ptr, ikm.len, &prk, prk_length);
        return prk;
    }

    pub fn expand(prk: *const [prk_length]u8, info: []const u8, comptime len: usize) [len]u8 {
        var okm: [len]u8 = undefined;
        const info_ptr = if (info.len > 0) info.ptr else null;
        _ = hkdf_expand(prk, prk_length, info_ptr, info.len, &okm, len);
        return okm;
    }
};
