//! X25519 Key Exchange using mbedTLS
//!
//! Zig wrapper for mbedTLS Curve25519 operations.
//! Uses C helper to work around mbedTLS 3.x opaque structures.
//!
//! The C helper functions are declared as extern and linked at build time.
//! See: lib/esp/src/idf/mbed_tls/x25519_helper.c

// Extern declarations for C helper functions
extern fn x25519_scalarmult(sk: *const [32]u8, pk: *const [32]u8, out: *[32]u8) c_int;
extern fn x25519_keypair(seed: *const [32]u8, sk_out: *[32]u8, pk_out: *[32]u8) c_int;
extern fn x25519_base_scalarmult(sk: *const [32]u8, pk_out: *[32]u8) c_int;

pub const Error = error{
    ScalarmultFailed,
    KeypairGenerationFailed,
};

/// X25519 secret key length
pub const secret_length = 32;

/// X25519 public key length
pub const public_length = 32;

/// X25519 shared secret length
pub const shared_length = 32;

/// X25519 seed length for deterministic key generation
pub const seed_length = 32;

/// X25519 key pair
pub const KeyPair = struct {
    secret_key: [secret_length]u8,
    public_key: [public_length]u8,

    /// Generate a keypair deterministically from a 32-byte seed
    pub fn generateDeterministic(seed: [seed_length]u8) Error!KeyPair {
        var kp: KeyPair = undefined;
        const ret = x25519_keypair(&seed, &kp.secret_key, &kp.public_key);
        if (ret != 0) {
            return Error.KeypairGenerationFailed;
        }
        return kp;
    }
};

/// Perform X25519 scalar multiplication (Diffie-Hellman key exchange)
///
/// Computes: shared_secret = secret_key * public_key
///
/// This is the core operation for X25519 key exchange:
/// - Alice: shared = scalarmult(alice_sk, bob_pk)
/// - Bob:   shared = scalarmult(bob_sk, alice_pk)
/// - Both get the same shared secret
pub fn scalarmult(secret_key: [secret_length]u8, public_key: [public_length]u8) Error![32]u8 {
    var shared: [32]u8 = undefined;
    const ret = x25519_scalarmult(&secret_key, &public_key, &shared);
    if (ret != 0) {
        return Error.ScalarmultFailed;
    }
    return shared;
}

/// Compute public key from secret key (base point multiplication)
pub fn baseScalarmult(secret_key: [secret_length]u8) Error![32]u8 {
    var pk: [32]u8 = undefined;
    const ret = x25519_base_scalarmult(&secret_key, &pk);
    if (ret != 0) {
        return Error.ScalarmultFailed;
    }
    return pk;
}
