/**
 * @file p384_helper.h
 * @brief P-384 (secp384r1) key exchange helper for Zig integration
 *
 * This C helper wraps mbedTLS P-384 operations because:
 * - mbedTLS 3.x uses opaque structures
 * - Zig's @cImport can't handle these opaque types
 */

#ifndef P384_HELPER_H
#define P384_HELPER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Generate P-384 keypair from seed
 *
 * @param seed     Random seed (48 bytes)
 * @param sk_out   Output secret key (48 bytes, big-endian)
 * @param pk_out   Output public key (97 bytes, uncompressed SEC1: 04 || x || y)
 * @return 0 on success, non-zero on error
 */
int p384_keypair(
    const uint8_t seed[48],
    uint8_t sk_out[48],
    uint8_t pk_out[97]
);

/**
 * @brief Perform P-384 ECDH (compute shared secret)
 *
 * @param sk       Our secret key (48 bytes, big-endian)
 * @param pk       Peer's public key (97 bytes, uncompressed SEC1)
 * @param out      Output shared secret (48 bytes, x-coordinate)
 * @return 0 on success, non-zero on error
 */
int p384_ecdh(
    const uint8_t sk[48],
    const uint8_t pk[97],
    uint8_t out[48]
);

/**
 * @brief Compute P-384 public key from secret key
 *
 * @param sk       Secret key (48 bytes, big-endian)
 * @param pk_out   Output public key (97 bytes, uncompressed SEC1)
 * @return 0 on success, non-zero on error
 */
int p384_compute_public(
    const uint8_t sk[48],
    uint8_t pk_out[97]
);

#ifdef __cplusplus
}
#endif

#endif /* P384_HELPER_H */
