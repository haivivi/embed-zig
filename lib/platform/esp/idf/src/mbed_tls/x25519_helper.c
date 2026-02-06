/**
 * @file x25519_helper.c
 * @brief X25519 key exchange helper implementation using HACL* Curve25519
 *
 * Uses the HACL* Curve25519 implementation from mbedTLS Everest 3rdparty.
 * This is a verified, constant-time implementation of X25519.
 *
 * Requires Everest include paths to be added to the build:
 *   - mbedtls/3rdparty/everest/include
 *   - mbedtls/3rdparty/everest/include/everest
 *
 * Note: We define KRML_VERIFIED_UINT128 to use software 128-bit integers
 * because ESP32 (Xtensa) doesn't support __int128.
 */

#include "x25519_helper.h"

#include <string.h>
#include <stdint.h>

/* Use software 128-bit integers (ESP32 doesn't have __int128) */
#define KRML_VERIFIED_UINT128

/* HACL* Curve25519 from Everest */
#include <everest/Hacl_Curve25519.h>

/**
 * X25519 base point (u=9 in little-endian Montgomery form)
 * This is the standard generator point for X25519.
 */
static const uint8_t X25519_BASEPOINT[32] = {
    9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

/**
 * Apply X25519 clamping to a 32-byte scalar.
 * 
 * Per RFC 7748:
 * - Clear lowest 3 bits (make divisible by 8)
 * - Clear bit 255 (ensure < 2^255)  
 * - Set bit 254 (ensure fixed position)
 */
static void x25519_clamp(uint8_t k[32])
{
    k[0] &= 0xF8;   /* Clear lowest 3 bits */
    k[31] &= 0x7F;  /* Clear bit 255 */
    k[31] |= 0x40;  /* Set bit 254 */
}

/**
 * X25519 scalar multiplication: out = sk * pk
 *
 * Uses HACL* Curve25519 implementation (verified, constant-time).
 *
 * @param sk     32-byte secret key (scalar)
 * @param pk     32-byte public key (point)
 * @param out    32-byte output (shared secret)
 * @return 0 on success
 */
int x25519_scalarmult(
    const uint8_t sk[32],
    const uint8_t pk[32],
    uint8_t out[32]
) {
    /* Apply clamping to private key */
    uint8_t sk_clamped[32];
    memcpy(sk_clamped, sk, 32);
    x25519_clamp(sk_clamped);
    
    /* Perform scalar multiplication using HACL* */
    /* Note: Hacl_Curve25519_crypto_scalarmult takes non-const pointers */
    Hacl_Curve25519_crypto_scalarmult(out, sk_clamped, (uint8_t*)pk);
    
    return 0;
}

/**
 * X25519 base point multiplication: pk_out = sk * G
 *
 * Computes public key from private key using the X25519 base point.
 *
 * @param sk      32-byte secret key (scalar)
 * @param pk_out  32-byte output public key
 * @return 0 on success
 */
int x25519_base_scalarmult(
    const uint8_t sk[32],
    uint8_t pk_out[32]
) {
    /* Apply clamping to private key */
    uint8_t sk_clamped[32];
    memcpy(sk_clamped, sk, 32);
    x25519_clamp(sk_clamped);
    
    /* Compute public key = sk * base_point using HACL* */
    Hacl_Curve25519_crypto_scalarmult(pk_out, sk_clamped, (uint8_t*)X25519_BASEPOINT);
    
    return 0;
}

/**
 * Generate X25519 keypair from seed.
 *
 * The seed becomes the private key (with clamping applied).
 * The public key is computed as pk = sk * G.
 *
 * @param seed    32-byte random seed
 * @param sk_out  32-byte output private key (clamped)
 * @param pk_out  32-byte output public key
 * @return 0 on success
 */
int x25519_keypair(
    const uint8_t seed[32],
    uint8_t sk_out[32],
    uint8_t pk_out[32]
) {
    /* Private key is seed with clamping */
    memcpy(sk_out, seed, 32);
    x25519_clamp(sk_out);

    /* Public key is base point multiplication */
    return x25519_base_scalarmult(sk_out, pk_out);
}
