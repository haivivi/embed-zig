//! TLS 1.3 Key Derivation Functions
//!
//! Implements HKDF-Expand-Label as defined in RFC 8446 Section 7.1.
//! This is TLS 1.3 specific and should not be in the generic crypto layer.

const std = @import("std");

/// HKDF-Expand-Label function for TLS 1.3
///
/// Derives keying material according to RFC 8446:
/// ```
/// HKDF-Expand-Label(Secret, Label, Context, Length) =
///     HKDF-Expand(Secret, HkdfLabel, Length)
///
/// struct {
///    uint16 length = Length;
///    opaque label<7..255> = "tls13 " + Label;
///    opaque context<0..255> = Context;
/// } HkdfLabel;
/// ```
pub fn hkdfExpandLabel(
    comptime Hkdf: type,
    secret: [Hkdf.prk_length]u8,
    comptime label: []const u8,
    context: []const u8,
    comptime len: usize,
) [len]u8 {
    // Build HkdfLabel structure
    const full_label = "tls13 " ++ label;

    var hkdf_label: [2 + 1 + full_label.len + 1 + 255]u8 = undefined;
    var pos: usize = 0;

    // Length (2 bytes, big-endian)
    std.mem.writeInt(u16, hkdf_label[pos..][0..2], len, .big);
    pos += 2;

    // Label length + "tls13 " + label
    hkdf_label[pos] = full_label.len;
    pos += 1;
    @memcpy(hkdf_label[pos..][0..full_label.len], full_label);
    pos += full_label.len;

    // Context length + context
    hkdf_label[pos] = @intCast(context.len);
    pos += 1;
    if (context.len > 0) {
        @memcpy(hkdf_label[pos..][0..context.len], context);
        pos += context.len;
    }

    // HKDF-Expand with constructed info
    return Hkdf.expand(&secret, hkdf_label[0..pos], len);
}

// ============================================================================
// Tests
// ============================================================================

test "hkdfExpandLabel basic" {
    const HkdfSha256 = std.crypto.kdf.hkdf.Hkdf(std.crypto.hash.sha2.Sha256);
    
    // Wrapper to match our expected HKDF interface
    const Hkdf = struct {
        pub const prk_length = 32;
        
        pub fn expand(prk: *const [32]u8, info: []const u8, comptime len: usize) [len]u8 {
            var out: [len]u8 = undefined;
            HkdfSha256.expand(&out, info, prk.*);
            return out;
        }
    };
    
    const secret: [32]u8 = [_]u8{0x01} ** 32;
    const result = hkdfExpandLabel(Hkdf, secret, "key", "", 16);
    
    try std.testing.expect(result.len == 16);
}

test "hkdfExpandLabel with context" {
    const HkdfSha256 = std.crypto.kdf.hkdf.Hkdf(std.crypto.hash.sha2.Sha256);
    
    const Hkdf = struct {
        pub const prk_length = 32;
        
        pub fn expand(prk: *const [32]u8, info: []const u8, comptime len: usize) [len]u8 {
            var out: [len]u8 = undefined;
            HkdfSha256.expand(&out, info, prk.*);
            return out;
        }
    };
    
    const secret: [32]u8 = [_]u8{0x02} ** 32;
    const context: [32]u8 = [_]u8{0x03} ** 32; // transcript hash
    const result = hkdfExpandLabel(Hkdf, secret, "s hs traffic", &context, 32);
    
    try std.testing.expect(result.len == 32);
}

test "hkdfExpandLabel different lengths" {
    const HkdfSha256 = std.crypto.kdf.hkdf.Hkdf(std.crypto.hash.sha2.Sha256);
    
    const Hkdf = struct {
        pub const prk_length = 32;
        
        pub fn expand(prk: *const [32]u8, info: []const u8, comptime len: usize) [len]u8 {
            var out: [len]u8 = undefined;
            HkdfSha256.expand(&out, info, prk.*);
            return out;
        }
    };
    
    const secret: [32]u8 = [_]u8{0x04} ** 32;
    
    // IV = 12 bytes
    const iv = hkdfExpandLabel(Hkdf, secret, "iv", "", 12);
    try std.testing.expect(iv.len == 12);
    
    // AES-128 key = 16 bytes
    const key16 = hkdfExpandLabel(Hkdf, secret, "key", "", 16);
    try std.testing.expect(key16.len == 16);
    
    // AES-256 key = 32 bytes
    const key32 = hkdfExpandLabel(Hkdf, secret, "key", "", 32);
    try std.testing.expect(key32.len == 32);
}
