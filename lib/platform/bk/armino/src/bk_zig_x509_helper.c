/**
 * bk_zig_x509_helper.c — X.509 certificate verification via mbedTLS
 *
 * Wraps mbedTLS x509_crt_parse_der / x509_crt_verify for Zig FFI.
 * All cert data passed as DER byte arrays.
 */

#include <string.h>
#include <components/log.h>

#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include <mbedtls/x509_crt.h>
#include <mbedtls/ssl.h>
#include <mbedtls/error.h>

#define TAG "zig_x509"

/**
 * Verify a certificate chain.
 *
 * @param certs_der     Array of DER-encoded certificate pointers (leaf first)
 * @param certs_len     Array of certificate lengths
 * @param cert_count    Number of certificates in chain
 * @param ca_der        Trusted CA cert (DER), NULL to skip CA verification
 * @param ca_der_len    Length of CA cert
 * @return 0 on success, negative mbedTLS error, positive = verify flags
 */
int bk_zig_x509_verify_chain(
    const unsigned char **certs_der,
    const unsigned int *certs_len,
    unsigned int cert_count,
    const unsigned char *ca_der,
    unsigned int ca_der_len)
{
    if (cert_count == 0) return -1;

    mbedtls_x509_crt chain;
    mbedtls_x509_crt ca;
    mbedtls_x509_crt_init(&chain);
    mbedtls_x509_crt_init(&ca);

    int ret;

    /* Parse all certs in the chain */
    for (unsigned int i = 0; i < cert_count; i++) {
        ret = mbedtls_x509_crt_parse_der(&chain, certs_der[i], certs_len[i]);
        if (ret != 0) {
            char err_buf[128];
            mbedtls_strerror(ret, err_buf, sizeof(err_buf));
            BK_LOGE(TAG, "parse cert[%d] (%d bytes) failed: %s (0x%x)\r\n",
                     i, certs_len[i], err_buf, -ret);
            goto cleanup;
        }
    }

    /* If CA provided, parse and verify */
    if (ca_der != NULL && ca_der_len > 0) {
        ret = mbedtls_x509_crt_parse_der(&ca, ca_der, ca_der_len);
        if (ret != 0) {
            BK_LOGE(TAG, "parse CA failed: 0x%x\r\n", -ret);
            goto cleanup;
        }

        uint32_t flags = 0;
        ret = mbedtls_x509_crt_verify(&chain, &ca, NULL, NULL, &flags, NULL, NULL);
        if (ret != 0) {
            BK_LOGW(TAG, "verify failed: ret=0x%x flags=0x%x\r\n", -ret, flags);
            ret = (int)flags; /* Return flags as positive value */
        }
    }
    /* If no CA, chain parses OK → success (caller uses skip_verify) */

cleanup:
    mbedtls_x509_crt_free(&chain);
    mbedtls_x509_crt_free(&ca);
    return ret;
}

/**
 * Parse a single DER certificate and return its issuer CN + subject CN.
 * Used for debugging / logging.
 *
 * @param der           DER-encoded certificate
 * @param der_len       Length
 * @param subject_buf   Output buffer for subject string
 * @param subject_size  Buffer size
 * @param issuer_buf    Output buffer for issuer string
 * @param issuer_size   Buffer size
 * @return 0 on success
 */
int bk_zig_x509_cert_info(
    const unsigned char *der, unsigned int der_len,
    char *subject_buf, unsigned int subject_size,
    char *issuer_buf, unsigned int issuer_size)
{
    mbedtls_x509_crt crt;
    mbedtls_x509_crt_init(&crt);

    int ret = mbedtls_x509_crt_parse_der(&crt, der, der_len);
    if (ret != 0) {
        mbedtls_x509_crt_free(&crt);
        return ret;
    }

    if (subject_buf && subject_size > 0) {
        mbedtls_x509_dn_gets(subject_buf, subject_size, &crt.subject);
    }
    if (issuer_buf && issuer_size > 0) {
        mbedtls_x509_dn_gets(issuer_buf, issuer_size, &crt.issuer);
    }

    mbedtls_x509_crt_free(&crt);
    return 0;
}
