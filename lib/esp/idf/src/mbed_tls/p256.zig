//! P-256 (secp256r1) Key Exchange using mbedTLS
//!
//! Zig wrapper for mbedTLS P-256 operations.
//! Uses C helper to work around mbedTLS 3.x opaque structures.
//!
//! The C helper functions are declared as extern and linked at build time.
//! See: lib/esp/src/idf/mbed_tls/p256_helper.c

// Extern declarations for C helper functions
extern fn p256_keypair(seed: *const [32]u8, sk_out: *[32]u8, pk_out: *[65]u8) c_int;
extern fn p256_ecdh(sk: *const [32]u8, pk: *const [65]u8, out: *[32]u8) c_int;
extern fn p256_compute_public(sk: *const [32]u8, pk_out: *[65]u8) c_int;

pub const Error = error{
    EcdhFailed,
    KeypairGenerationFailed,
    ComputePublicFailed,
};

/// P-256 secret key length (32 bytes)
pub const secret_length = 32;

/// P-256 uncompressed public key length (65 bytes: 04 || x || y)
pub const public_length = 65;

/// P-256 shared secret length (32 bytes, x-coordinate)
pub const shared_length = 32;

/// P-256 seed length for deterministic key generation
pub const seed_length = 32;

/// P-256 key pair
pub const KeyPair = struct {
    secret_key: [secret_length]u8,
    public_key: [public_length]u8,

    /// Generate a keypair deterministically from a 32-byte seed
    pub fn generateDeterministic(seed: [seed_length]u8) Error!KeyPair {
        var kp: KeyPair = undefined;
        const ret = p256_keypair(&seed, &kp.secret_key, &kp.public_key);
        if (ret != 0) {
            return Error.KeypairGenerationFailed;
        }
        return kp;
    }
};

/// Perform P-256 ECDH (Diffie-Hellman key exchange)
///
/// Computes shared secret from our secret key and peer's public key.
/// The shared secret is the x-coordinate of the resulting point.
pub fn ecdh(secret_key: [secret_length]u8, public_key: [public_length]u8) Error![shared_length]u8 {
    var shared: [shared_length]u8 = undefined;
    const ret = p256_ecdh(&secret_key, &public_key, &shared);
    if (ret != 0) {
        return Error.EcdhFailed;
    }
    return shared;
}

/// Compute P-256 public key from secret key
pub fn computePublic(secret_key: [secret_length]u8) Error![public_length]u8 {
    var pk: [public_length]u8 = undefined;
    const ret = p256_compute_public(&secret_key, &pk);
    if (ret != 0) {
        return Error.ComputePublicFailed;
    }
    return pk;
}
