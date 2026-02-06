/**
 * @file p256_helper.h
 * @brief P-256 (secp256r1) key exchange helper for Zig integration
 *
 * This C helper wraps mbedTLS P-256 operations because:
 * - mbedTLS 3.x uses opaque structures
 * - Zig's @cImport can't handle these opaque types
 *
 * We expose simple byte-array interfaces that Zig can easily call.
 */

#ifndef P256_HELPER_H
#define P256_HELPER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Generate P-256 keypair from seed
 *
 * @param seed     Random seed (32 bytes)
 * @param sk_out   Output secret key (32 bytes, big-endian)
 * @param pk_out   Output public key (65 bytes, uncompressed SEC1: 04 || x || y)
 * @return 0 on success, non-zero on error
 */
int p256_keypair(
    const uint8_t seed[32],
    uint8_t sk_out[32],
    uint8_t pk_out[65]
);

/**
 * @brief Perform P-256 ECDH (compute shared secret)
 *
 * @param sk       Our secret key (32 bytes, big-endian)
 * @param pk       Peer's public key (65 bytes, uncompressed SEC1)
 * @param out      Output shared secret (32 bytes, x-coordinate)
 * @return 0 on success, non-zero on error
 */
int p256_ecdh(
    const uint8_t sk[32],
    const uint8_t pk[65],
    uint8_t out[32]
);

/**
 * @brief Compute P-256 public key from secret key
 *
 * @param sk       Secret key (32 bytes, big-endian)
 * @param pk_out   Output public key (65 bytes, uncompressed SEC1)
 * @return 0 on success, non-zero on error
 */
int p256_compute_public(
    const uint8_t sk[32],
    uint8_t pk_out[65]
);

#ifdef __cplusplus
}
#endif

#endif /* P256_HELPER_H */
