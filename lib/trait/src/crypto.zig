//! Crypto Primitives Interface Definition
//!
//! Provides compile-time validation for cryptographic primitives.
//! Protocol-agnostic - can be used by TLS, Noise, Signal, etc.
//!
//! All validation uses signature checking via @as(*const fn(...), &fn)
//! to ensure type safety at compile time.
//!
//! Usage:
//! ```zig
//! const Crypto = trait.crypto.from(MyCrypto, .{
//!     .sha256 = true,
//!     .aes_128_gcm = true,
//!     .x25519 = true,
//!     .rng = true,
//! });
//! ```

const std = @import("std");
const rng_trait = @import("rng.zig");

/// Crypto primitives configuration
///
/// Required primitives default to `true` — these are the baseline that every
/// platform must implement (hash, AEAD, key exchange, KDF, MAC, RNG).
/// Optional primitives default to `false` — enable as needed.
///
/// To validate only a subset (e.g., TLS client needs fewer), set unwanted
/// required fields to `false` explicitly.
pub const Config = struct {
    // ===== Required (platform baseline) =====

    // Hash functions
    sha256: bool = true,
    sha384: bool = true,

    // AEAD (Authenticated Encryption with Associated Data)
    aes_128_gcm: bool = true,
    aes_256_gcm: bool = true,
    chacha20_poly1305: bool = true,

    // Key Exchange
    x25519: bool = true,

    // KDF (Key Derivation Functions)
    hkdf_sha256: bool = true,
    hkdf_sha384: bool = true,

    // MAC (Message Authentication Code)
    hmac_sha256: bool = true,
    hmac_sha384: bool = true,

    // Random Number Generator
    rng: bool = true,

    // ===== Optional (platform-specific) =====

    // Additional hash functions
    sha512: bool = false,
    sha1: bool = false, // Legacy, for TLS 1.2
    blake2s: bool = false,
    blake2b: bool = false,

    // Additional key exchange / ECC
    p256: bool = false,
    p384: bool = false,

    // Additional KDF / MAC
    hkdf_sha512: bool = false,
    hmac_sha512: bool = false,

    // Digital Signatures
    ed25519: bool = false,
    ecdsa_p256: bool = false,
    ecdsa_p384: bool = false,
    rsa: bool = false, // Verify only

    // X.509 Certificate
    x509: bool = false,

    // Certificate Store (for TLS certificate verification)
    cert_store: bool = false,
};

/// Validate crypto implementation and return the type
/// All validation happens at comptime - zero runtime overhead
pub fn from(comptime Impl: type, comptime config: Config) type {
    comptime {
        // Hash functions
        if (config.sha256) validateHash(Impl, "Sha256", 32);
        if (config.sha384) validateHash(Impl, "Sha384", 48);
        if (config.sha512) validateHash(Impl, "Sha512", 64);
        if (config.sha1) validateHash(Impl, "Sha1", 20);
        if (config.blake2s) validateHash(Impl, "Blake2s256", 32);
        if (config.blake2b) validateHash(Impl, "Blake2b512", 64);

        // AEAD
        if (config.aes_128_gcm) validateAead(Impl, "Aes128Gcm", 16, 12, 16);
        if (config.aes_256_gcm) validateAead(Impl, "Aes256Gcm", 32, 12, 16);
        if (config.chacha20_poly1305) validateAead(Impl, "ChaCha20Poly1305", 32, 12, 16);

        // Key Exchange
        if (config.x25519) validateX25519(Impl);
        if (config.p256) validateP256(Impl);
        if (config.p384) validateP384(Impl);

        // KDF
        if (config.hkdf_sha256) validateHkdf(Impl, "HkdfSha256", 32);
        if (config.hkdf_sha384) validateHkdf(Impl, "HkdfSha384", 48);
        if (config.hkdf_sha512) validateHkdf(Impl, "HkdfSha512", 64);

        // MAC
        if (config.hmac_sha256) validateHmac(Impl, "HmacSha256", 32);
        if (config.hmac_sha384) validateHmac(Impl, "HmacSha384", 48);
        if (config.hmac_sha512) validateHmac(Impl, "HmacSha512", 64);

        // Digital Signatures
        if (config.ed25519) validateEd25519(Impl);
        if (config.ecdsa_p256) validateEcdsa(Impl, "EcdsaP256Sha256");
        if (config.ecdsa_p384) validateEcdsa(Impl, "EcdsaP384Sha384");

        // X.509
        if (config.x509) validateX509(Impl);

        // Certificate Store
        if (config.cert_store) validateCertStore(Impl);

        // RNG
        if (config.rng) validateRng(Impl);
    }
    return Impl;
}

/// Check if implementation has a specific primitive
pub fn has(comptime Impl: type, comptime name: []const u8) bool {
    return @hasDecl(Impl, name);
}

// ============================================================================
// Validation Functions - All use signature validation via @as()
// ============================================================================

fn validateHash(comptime Impl: type, comptime name: []const u8, comptime digest_len: usize) void {
    if (!@hasDecl(Impl, name)) {
        @compileError("Crypto implementation missing: " ++ name);
    }
    const T = @field(Impl, name);

    // Check digest_length constant
    if (!@hasDecl(T, "digest_length")) {
        @compileError(name ++ " missing digest_length");
    }
    if (T.digest_length != digest_len) {
        @compileError(name ++ " has wrong digest_length");
    }

    // Validate that essential declarations exist
    // Note: We don't validate exact function signatures because:
    // - init() signature varies between Zig versions (some take Options param)
    // - We just need the declarations to exist
    if (!@hasDecl(T, "init")) {
        @compileError(name ++ " missing init function");
    }
    if (!@hasDecl(T, "update")) {
        @compileError(name ++ " missing update function");
    }
    if (!@hasDecl(T, "final") and !@hasDecl(T, "finalResult")) {
        @compileError(name ++ " missing final/finalResult function");
    }
    if (!@hasDecl(T, "hash")) {
        @compileError(name ++ " missing hash function");
    }
}

fn validateAead(
    comptime Impl: type,
    comptime name: []const u8,
    comptime key_len: usize,
    comptime nonce_len: usize,
    comptime tag_len: usize,
) void {
    if (!@hasDecl(Impl, name)) {
        @compileError("Crypto implementation missing: " ++ name);
    }
    const T = @field(Impl, name);

    // Check required constants
    if (!@hasDecl(T, "key_length") or T.key_length != key_len) {
        @compileError(name ++ " missing or wrong key_length");
    }
    if (!@hasDecl(T, "nonce_length") or T.nonce_length != nonce_len) {
        @compileError(name ++ " missing or wrong nonce_length");
    }
    if (!@hasDecl(T, "tag_length") or T.tag_length != tag_len) {
        @compileError(name ++ " missing or wrong tag_length");
    }

    // Validate encryptStatic signature
    _ = @as(
        *const fn ([]u8, *[tag_len]u8, []const u8, []const u8, [nonce_len]u8, [key_len]u8) void,
        &T.encryptStatic,
    );

    // Validate decryptStatic signature (returns error union)
    _ = @as(
        *const fn ([]u8, []const u8, [tag_len]u8, []const u8, [nonce_len]u8, [key_len]u8) error{AuthenticationFailed}!void,
        &T.decryptStatic,
    );
}

fn validateX25519(comptime Impl: type) void {
    if (!@hasDecl(Impl, "X25519")) {
        @compileError("Crypto implementation missing: X25519");
    }
    const T = Impl.X25519;

    // Check length constants
    if (!@hasDecl(T, "secret_length") or T.secret_length != 32) {
        @compileError("X25519 missing or wrong secret_length");
    }
    if (!@hasDecl(T, "public_length") or T.public_length != 32) {
        @compileError("X25519 missing or wrong public_length");
    }

    // Check KeyPair type
    if (!@hasDecl(T, "KeyPair")) {
        @compileError("X25519 missing KeyPair type");
    }
    const KP = T.KeyPair;

    // Validate KeyPair.generateDeterministic signature
    _ = @as(*const fn ([32]u8) anyerror!KP, &KP.generateDeterministic);

    // Validate scalarmult signature
    _ = @as(*const fn ([32]u8, [32]u8) anyerror![32]u8, &T.scalarmult);
}

fn validateP256(comptime Impl: type) void {
    if (!@hasDecl(Impl, "P256")) {
        @compileError("Crypto implementation missing: P256");
    }
    const T = Impl.P256;

    // Check KeyPair type exists
    if (!@hasDecl(T, "KeyPair")) {
        @compileError("P256 missing KeyPair type");
    }

    // Check scalar length (P-256 = 32 bytes)
    if (@hasDecl(T, "scalar_length")) {
        if (T.scalar_length != 32) {
            @compileError("P256 has wrong scalar_length");
        }
    }
}

fn validateP384(comptime Impl: type) void {
    if (!@hasDecl(Impl, "P384")) {
        @compileError("Crypto implementation missing: P384");
    }
    const T = Impl.P384;

    // Check KeyPair type exists
    if (!@hasDecl(T, "KeyPair")) {
        @compileError("P384 missing KeyPair type");
    }

    // Check scalar length (P-384 = 48 bytes)
    if (@hasDecl(T, "scalar_length")) {
        if (T.scalar_length != 48) {
            @compileError("P384 has wrong scalar_length");
        }
    }
}

fn validateHkdf(comptime Impl: type, comptime name: []const u8, comptime prk_len: usize) void {
    if (!@hasDecl(Impl, name)) {
        @compileError("Crypto implementation missing: " ++ name);
    }
    const T = @field(Impl, name);

    // Check prk_length
    if (!@hasDecl(T, "prk_length") or T.prk_length != prk_len) {
        @compileError(name ++ " missing or wrong prk_length");
    }

    // Validate extract signature: extract(?[]const u8, []const u8) [prk_len]u8
    // Salt is optional (can be null)
    _ = @as(*const fn (?[]const u8, []const u8) [prk_len]u8, &T.extract);

    // expand has comptime len parameter, can't fully validate signature
    if (!@hasDecl(T, "expand")) {
        @compileError(name ++ " missing expand function");
    }
}

fn validateHmac(comptime Impl: type, comptime name: []const u8, comptime mac_len: usize) void {
    if (!@hasDecl(Impl, name)) {
        @compileError("Crypto implementation missing: " ++ name);
    }
    const T = @field(Impl, name);

    // Check mac_length
    if (!@hasDecl(T, "mac_length") or T.mac_length != mac_len) {
        @compileError(name ++ " missing or wrong mac_length");
    }

    // Validate create signature: create(*[mac_len]u8, []const u8, []const u8) void
    _ = @as(*const fn (*[mac_len]u8, []const u8, []const u8) void, &T.create);

    // Validate init signature: init([]const u8) T
    _ = @as(*const fn ([]const u8) T, &T.init);
}

fn validateEd25519(comptime Impl: type) void {
    if (!@hasDecl(Impl, "Ed25519")) {
        @compileError("Crypto implementation missing: Ed25519");
    }
    const T = Impl.Ed25519;

    // Check Signature type
    if (!@hasDecl(T, "Signature")) {
        @compileError("Ed25519 missing Signature type");
    }

    // Check PublicKey type
    if (!@hasDecl(T, "PublicKey")) {
        @compileError("Ed25519 missing PublicKey type");
    }
}

fn validateEcdsa(comptime Impl: type, comptime name: []const u8) void {
    if (!@hasDecl(Impl, name)) {
        @compileError("Crypto implementation missing: " ++ name);
    }
    const T = @field(Impl, name);

    // Check Signature type
    if (!@hasDecl(T, "Signature")) {
        @compileError(name ++ " missing Signature type");
    }

    // Check PublicKey type
    if (!@hasDecl(T, "PublicKey")) {
        @compileError(name ++ " missing PublicKey type");
    }
}

fn validateX509(comptime Impl: type) void {
    if (!@hasDecl(Impl, "x509")) {
        @compileError("Crypto implementation missing: x509");
    }
    // x509 is a complex module, just check it exists
}

fn validateCertStore(comptime Impl: type) void {
    // CertStore can be at top level or under x509
    const has_direct = @hasDecl(Impl, "CertStore");
    const has_under_x509 = @hasDecl(Impl, "x509") and @hasDecl(Impl.x509, "CaStore");

    if (!has_direct and !has_under_x509) {
        @compileError("Crypto implementation missing: CertStore (or x509.CaStore)");
    }
}

fn validateRng(comptime Impl: type) void {
    if (!@hasDecl(Impl, "Rng")) {
        @compileError("Crypto implementation missing: Rng");
    }
    // Use rng trait for recursive validation
    _ = rng_trait.from(Impl.Rng);
}

// ============================================================================
// Tests
// ============================================================================

test "crypto trait validation - mock implementation" {
    const MockCrypto = struct {
        pub const Sha256 = struct {
            pub const digest_length = 32;
            pub const block_length = 64;

            pub fn hash(_: []const u8, _: *[32]u8, _: anytype) void {}
            pub fn init() @This() {
                return .{};
            }
            pub fn update(_: *@This(), _: []const u8) void {}
            pub fn final(_: *@This()) [32]u8 {
                return [_]u8{0} ** 32;
            }
        };

        pub const Aes128Gcm = struct {
            pub const key_length = 16;
            pub const nonce_length = 12;
            pub const tag_length = 16;

            pub fn encryptStatic(_: []u8, _: *[16]u8, _: []const u8, _: []const u8, _: [12]u8, _: [16]u8) void {}
            pub fn decryptStatic(_: []u8, _: []const u8, _: [16]u8, _: []const u8, _: [12]u8, _: [16]u8) error{AuthenticationFailed}!void {}
        };

        pub const X25519 = struct {
            pub const secret_length = 32;
            pub const public_length = 32;
            pub const shared_length = 32;

            pub const KeyPair = struct {
                secret_key: [32]u8,
                public_key: [32]u8,

                pub fn generateDeterministic(_: [32]u8) !@This() {
                    return @This(){ .secret_key = undefined, .public_key = undefined };
                }
            };

            pub fn scalarmult(_: [32]u8, _: [32]u8) ![32]u8 {
                return [_]u8{0} ** 32;
            }
        };

        pub const HkdfSha256 = struct {
            pub const prk_length = 32;

            pub fn extract(_: ?[]const u8, _: []const u8) [32]u8 {
                return [_]u8{0} ** 32;
            }
            pub fn expand(_: *const [32]u8, _: []const u8, comptime _: usize) [32]u8 {
                return [_]u8{0} ** 32;
            }
        };

        pub const HmacSha256 = struct {
            pub const mac_length = 32;
            pub const block_length = 64;

            pub fn create(_: *[32]u8, _: []const u8, _: []const u8) void {}
            pub fn init(_: []const u8) @This() {
                return .{};
            }
        };

        pub const Rng = struct {
            pub fn fill(_: []u8) void {}
        };
    };

    // This should compile without errors.
    // Explicitly disable required primitives not present in this mock.
    const Validated = from(MockCrypto, .{
        .sha256 = true,
        .sha384 = false,
        .aes_128_gcm = true,
        .aes_256_gcm = false,
        .chacha20_poly1305 = false,
        .x25519 = true,
        .hkdf_sha256 = true,
        .hkdf_sha384 = false,
        .hmac_sha256 = true,
        .hmac_sha384 = false,
        .rng = true,
    });

    // Verify we can access the types
    try std.testing.expect(Validated.Sha256.digest_length == 32);
    try std.testing.expect(Validated.Aes128Gcm.key_length == 16);
    try std.testing.expect(Validated.X25519.secret_length == 32);
}

test "has() helper function" {
    const Mock = struct {
        pub const Sha256 = struct {};
    };

    try std.testing.expect(has(Mock, "Sha256"));
    try std.testing.expect(!has(Mock, "Sha384"));
}

test "rng validation via crypto trait" {
    const MockCryptoWithRng = struct {
        pub const Rng = struct {
            pub fn fill(_: []u8) void {}
        };
    };

    // Should compile - Rng is validated via rng_trait.from()
    // Disable all other required primitives since this mock only has Rng.
    _ = from(MockCryptoWithRng, .{
        .sha256 = false,
        .sha384 = false,
        .aes_128_gcm = false,
        .aes_256_gcm = false,
        .chacha20_poly1305 = false,
        .x25519 = false,
        .hkdf_sha256 = false,
        .hkdf_sha384 = false,
        .hmac_sha256 = false,
        .hmac_sha384 = false,
        .rng = true,
    });
}
