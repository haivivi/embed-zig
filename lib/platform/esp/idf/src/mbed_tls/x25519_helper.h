/**
 * @file x25519_helper.h
 * @brief X25519 key exchange helper for Zig integration
 *
 * This C helper wraps mbedTLS X25519/Curve25519 operations because:
 * - mbedTLS 3.x uses opaque structures (can't access ctx.d, ctx.Q directly)
 * - Zig's @cImport can't handle these opaque types
 *
 * We expose simple byte-array interfaces that Zig can easily call.
 */

#ifndef X25519_HELPER_H
#define X25519_HELPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Perform X25519 scalar multiplication (Diffie-Hellman)
 *
 * Computes: shared_out = sk * pk (on Curve25519)
 *
 * @param sk       Secret key (32 bytes)
 * @param pk       Peer's public key (32 bytes)
 * @param out      Output shared secret (32 bytes)
 * @return 0 on success, non-zero on error
 */
int x25519_scalarmult(
    const uint8_t sk[32],
    const uint8_t pk[32],
    uint8_t out[32]
);

/**
 * @brief Generate X25519 keypair from seed
 *
 * Deterministically generates a keypair from a 32-byte seed.
 *
 * @param seed     Random seed (32 bytes)
 * @param sk_out   Output secret key (32 bytes)
 * @param pk_out   Output public key (32 bytes)
 * @return 0 on success, non-zero on error
 */
int x25519_keypair(
    const uint8_t seed[32],
    uint8_t sk_out[32],
    uint8_t pk_out[32]
);

/**
 * @brief Compute X25519 public key from secret key
 *
 * Computes: pk = sk * G (base point multiplication)
 *
 * @param sk       Secret key (32 bytes)
 * @param pk_out   Output public key (32 bytes)
 * @return 0 on success, non-zero on error
 */
int x25519_base_scalarmult(
    const uint8_t sk[32],
    uint8_t pk_out[32]
);

#ifdef __cplusplus
}
#endif

#endif /* X25519_HELPER_H */
