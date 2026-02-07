//! P-384 (secp384r1) Key Exchange using mbedTLS
//!
//! Zig wrapper for mbedTLS P-384 operations.
//! Uses C helper to work around mbedTLS 3.x opaque structures.
//!
//! The C helper functions are declared as extern and linked at build time.
//! See: lib/esp/src/idf/mbed_tls/p384_helper.c

// Extern declarations for C helper functions
extern fn p384_keypair(seed: *const [48]u8, sk_out: *[48]u8, pk_out: *[97]u8) c_int;
extern fn p384_ecdh(sk: *const [48]u8, pk: *const [97]u8, out: *[48]u8) c_int;
extern fn p384_compute_public(sk: *const [48]u8, pk_out: *[97]u8) c_int;

pub const Error = error{
    EcdhFailed,
    KeypairGenerationFailed,
    ComputePublicFailed,
};

/// P-384 secret key length (48 bytes)
pub const secret_length = 48;

/// P-384 uncompressed public key length (97 bytes: 04 || x || y)
pub const public_length = 97;

/// P-384 shared secret length (48 bytes, x-coordinate)
pub const shared_length = 48;

/// P-384 seed length for deterministic key generation
pub const seed_length = 48;

/// P-384 key pair
pub const KeyPair = struct {
    secret_key: [secret_length]u8,
    public_key: [public_length]u8,

    /// Generate a keypair deterministically from a 48-byte seed
    pub fn generateDeterministic(seed: [seed_length]u8) Error!KeyPair {
        var kp: KeyPair = undefined;
        const ret = p384_keypair(&seed, &kp.secret_key, &kp.public_key);
        if (ret != 0) {
            return Error.KeypairGenerationFailed;
        }
        return kp;
    }
};

/// Perform P-384 ECDH (Diffie-Hellman key exchange)
///
/// Computes shared secret from our secret key and peer's public key.
/// The shared secret is the x-coordinate of the resulting point.
pub fn ecdh(secret_key: [secret_length]u8, public_key: [public_length]u8) Error![shared_length]u8 {
    var shared: [shared_length]u8 = undefined;
    const ret = p384_ecdh(&secret_key, &public_key, &shared);
    if (ret != 0) {
        return Error.EcdhFailed;
    }
    return shared;
}

/// Compute P-384 public key from secret key
pub fn computePublic(secret_key: [secret_length]u8) Error![public_length]u8 {
    var pk: [public_length]u8 = undefined;
    const ret = p384_compute_public(&secret_key, &pk);
    if (ret != 0) {
        return Error.ComputePublicFailed;
    }
    return pk;
}
