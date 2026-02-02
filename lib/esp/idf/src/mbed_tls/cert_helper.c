/**
 * @file cert_helper.c
 * @brief ESP CA Bundle certificate verification helper implementation
 *
 * Uses ESP-IDF's esp_crt_bundle component to verify certificates against
 * the built-in CA certificate bundle (~130 common root CAs).
 *
 * The ESP bundle uses a compressed format storing only CN and public key,
 * allowing efficient verification without storing full certificates.
 */

#include "cert_helper.h"

#include <esp_crt_bundle.h>
#include <mbedtls/x509_crt.h>

/* esp_crt_verify_callback is declared in esp_crt_bundle.c but not in header */
extern int esp_crt_verify_callback(void *buf, mbedtls_x509_crt *crt, int depth, uint32_t *flags);

/**
 * Verify a certificate using ESP-IDF's built-in CA bundle.
 *
 * This function:
 * 1. Parses the DER-encoded certificate
 * 2. Initializes the ESP CA bundle (if not already done)
 * 3. Calls the ESP bundle verification callback
 *
 * @param cert_der  DER-encoded certificate
 * @param cert_len  Length of certificate data
 * @return 0 on success, mbedTLS error code on failure
 */
int verify_with_esp_bundle(
    const uint8_t* cert_der,
    size_t cert_len
) {
    mbedtls_x509_crt crt;
    mbedtls_x509_crt_init(&crt);

    /* Parse the DER-encoded certificate */
    int ret = mbedtls_x509_crt_parse_der(&crt, cert_der, cert_len);
    if (ret != 0) {
        mbedtls_x509_crt_free(&crt);
        return ret;
    }

    /* Initialize the ESP bundle (loads embedded CA data) */
    esp_crt_bundle_attach(NULL);

    /* Set flags to indicate untrusted - callback will clear if trusted */
    uint32_t flags = MBEDTLS_X509_BADCERT_NOT_TRUSTED;

    /* Call the ESP bundle verification callback */
    ret = esp_crt_verify_callback(NULL, &crt, 0, &flags);

    mbedtls_x509_crt_free(&crt);

    /* flags == 0 means certificate is trusted */
    return (flags == 0) ? 0 : -1;
}
