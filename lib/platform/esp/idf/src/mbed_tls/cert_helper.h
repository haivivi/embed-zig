/**
 * @file cert_helper.h
 * @brief ESP CA Bundle certificate verification helper for Zig integration
 *
 * This C helper wraps ESP-IDF's esp_crt_bundle API because:
 * - esp_crt_bundle uses compressed certificate format (CN + public key only)
 * - The verification callback is designed for mbedTLS SSL integration
 * - Zig's @cImport can't handle the internal callback mechanism
 *
 * We expose a simple verification interface that Zig can easily call.
 */

#ifndef CERT_HELPER_H
#define CERT_HELPER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Verify a certificate chain using ESP-IDF built-in CA bundle
 *
 * Uses the esp_crt_bundle (~130 common root CAs) to verify the certificate.
 * The bundle is embedded in the binary and uses a compressed format.
 *
 * @param cert_der    DER-encoded certificate to verify
 * @param cert_len    Length of the certificate in bytes
 * @return 0 on success, non-zero on verification failure
 */
int verify_with_esp_bundle(
    const uint8_t* cert_der,
    size_t cert_len
);

#ifdef __cplusplus
}
#endif

#endif /* CERT_HELPER_H */
