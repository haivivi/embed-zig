/**
 * @file p256_helper.c
 * @brief P-256 (secp256r1) key exchange helper using mbedTLS
 *
 * Wraps mbedTLS P-256 operations for Zig integration.
 * Uses mbedtls_ecdh_compute_shared with externally-provided keys.
 */

#include "p256_helper.h"

#include <mbedtls/ecdh.h>
#include <mbedtls/ecp.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <string.h>

/**
 * P-256 ECDH: shared = sk * pk (x-coordinate only)
 */
int p256_ecdh(
    const uint8_t sk[32],
    const uint8_t pk[65],
    uint8_t out[32]
) {
    int ret = -1;
    mbedtls_ecp_group grp;
    mbedtls_mpi d;       // Our private key
    mbedtls_mpi z;       // Shared secret
    mbedtls_ecp_point Q; // Peer's public key

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);

    // Load P-256 (secp256r1) group
    ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) goto cleanup;

    // Import private key as MPI (big-endian for P-256)
    ret = mbedtls_mpi_read_binary(&d, sk, 32);
    if (ret != 0) goto cleanup;

    // Import peer's public key as point (uncompressed SEC1 format)
    ret = mbedtls_ecp_point_read_binary(&grp, &Q, pk, 65);
    if (ret != 0) goto cleanup;

    // Compute shared secret: z = d * Q
    ret = mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, NULL, NULL);
    if (ret != 0) goto cleanup;

    // Export shared secret as 32 bytes (big-endian x-coordinate)
    memset(out, 0, 32);
    ret = mbedtls_mpi_write_binary(&z, out, 32);
    if (ret != 0) goto cleanup;

    ret = 0;

cleanup:
    mbedtls_ecp_group_free(&grp);
    mbedtls_mpi_free(&d);
    mbedtls_mpi_free(&z);
    mbedtls_ecp_point_free(&Q);
    return ret;
}

/**
 * Compute P-256 public key from private key: Q = d * G
 */
int p256_compute_public(
    const uint8_t sk[32],
    uint8_t pk_out[65]
) {
    int ret = -1;
    mbedtls_ecp_group grp;
    mbedtls_mpi d;       // Private key
    mbedtls_ecp_point Q; // Public key

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);

    // Load P-256 group
    ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) goto cleanup;

    // Import private key as MPI (big-endian)
    ret = mbedtls_mpi_read_binary(&d, sk, 32);
    if (ret != 0) goto cleanup;

    // Compute public key: Q = d * G
    ret = mbedtls_ecp_mul(&grp, &Q, &d, &grp.G, NULL, NULL);
    if (ret != 0) goto cleanup;

    // Export public key as 65 bytes (uncompressed SEC1)
    size_t olen = 0;
    ret = mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_UNCOMPRESSED,
                                          &olen, pk_out, 65);
    if (ret != 0) goto cleanup;

    ret = 0;

cleanup:
    mbedtls_ecp_group_free(&grp);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_point_free(&Q);
    return ret;
}

/**
 * Generate P-256 keypair deterministically from seed.
 *
 * Uses the seed to initialize DRBG, then generates a proper keypair.
 */
int p256_keypair(
    const uint8_t seed[32],
    uint8_t sk_out[32],
    uint8_t pk_out[65]
) {
    int ret = -1;
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point Q;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_entropy_context entropy;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);
    mbedtls_ctr_drbg_init(&drbg);
    mbedtls_entropy_init(&entropy);

    // Seed the DRBG with provided seed
    ret = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy, seed, 32);
    if (ret != 0) goto cleanup;

    // Load P-256 group
    ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) goto cleanup;

    // Generate keypair
    ret = mbedtls_ecdh_gen_public(&grp, &d, &Q, mbedtls_ctr_drbg_random, &drbg);
    if (ret != 0) goto cleanup;

    // Export private key as 32 bytes (big-endian)
    memset(sk_out, 0, 32);
    ret = mbedtls_mpi_write_binary(&d, sk_out, 32);
    if (ret != 0) goto cleanup;

    // Export public key as 65 bytes (uncompressed SEC1)
    size_t olen = 0;
    ret = mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_UNCOMPRESSED,
                                          &olen, pk_out, 65);
    if (ret != 0) goto cleanup;

    ret = 0;

cleanup:
    mbedtls_ecp_group_free(&grp);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_point_free(&Q);
    mbedtls_ctr_drbg_free(&drbg);
    mbedtls_entropy_free(&entropy);
    return ret;
}
