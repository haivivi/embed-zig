# BK7258 Kconfig: Crypto/TLS configuration (AP)
# Controls mbedTLS library features on BK7258.
#
# BK7258 has two mbedTLS implementation paths:
#   1. TRUSTENGINE (hardware) — uses the on-chip "Dubhe" crypto accelerator
#      for AES/GCM/SHA/ECC, with hardware-accelerated bignum operations.
#   2. SW_CRYPTO (software) — pure software mbedTLS (same algorithms,
#      compiled from mbedTLS C source, no hardware acceleration).
#
# These two are mutually exclusive. If neither is set, only minimal
# WPA crypto for WiFi is compiled.
#
# Note: Unlike ESP32 which exposes per-algorithm Kconfig switches (SHA256,
# AES, GCM, ChaCha20, ECC curves individually), BK7258 controls algorithm
# selection via C header files, not Kconfig. The fine-grained algorithm
# set is determined by FULL_MBEDTLS + the xxx_config.h header.

def _kconfig_bool(key, enabled):
    if enabled:
        return "CONFIG_{}=y".format(key)
    return "# CONFIG_{} is not set".format(key)

def _bk_ap_crypto_impl(ctx):
    if ctx.attr.hardware_accel and ctx.attr.software_crypto:
        fail("bk_ap_crypto: hardware_accel and software_crypto are mutually exclusive")

    if ctx.attr.full_mbedtls and not (ctx.attr.hardware_accel or ctx.attr.software_crypto):
        fail("bk_ap_crypto: full_mbedtls=True requires either hardware_accel=True or software_crypto=True")

    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = ["# Crypto/TLS"]

    lines.append(_kconfig_bool("FULL_MBEDTLS", ctx.attr.full_mbedtls))
    lines.append(_kconfig_bool("TRUSTENGINE", ctx.attr.hardware_accel))
    lines.append(_kconfig_bool("SW_CRYPTO", ctx.attr.software_crypto))
    lines.append("CONFIG_MBEDTLS_SSL_IN_CONTENT_LEN={}".format(ctx.attr.ssl_in_content_len))
    lines.append("CONFIG_MBEDTLS_SSL_OUT_CONTENT_LEN={}".format(ctx.attr.ssl_out_content_len))

    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_ap_crypto = rule(
    implementation = _bk_ap_crypto_impl,
    attrs = {
        "full_mbedtls": attr.bool(
            mandatory = True,
            doc = """CONFIG_FULL_MBEDTLS — enable full mbedTLS algorithm set.
            False: only minimal crypto for WiFi WPA (smallest binary).
            True: full TLS support including HTTPS, X.509 certificate
                  verification, all cipher suites. Specific algorithms are
                  controlled by C header (not Kconfig on BK).""",
        ),
        "hardware_accel": attr.bool(
            default = True,
            doc = """CONFIG_TRUSTENGINE — use BK7258's on-chip Dubhe hardware
            crypto accelerator for AES, GCM, SHA, ECC, bignum operations.
            Mutually exclusive with software_crypto.
            Provides significant speedup for TLS handshakes and bulk encryption.
            Requires the bk_trustengine SDK component.""",
        ),
        "software_crypto": attr.bool(
            default = False,
            doc = """CONFIG_SW_CRYPTO — use pure software mbedTLS implementation.
            Compiles ECC, RSA, ECDH, ECDSA, bignum etc. from mbedTLS C source.
            Mutually exclusive with hardware_accel.
            Use this when hardware accelerator is unavailable or for debugging.""",
        ),
        "ssl_in_content_len": attr.int(
            default = 16384,
            doc = """CONFIG_MBEDTLS_SSL_IN_CONTENT_LEN — max incoming TLS record (bytes).
            16384: full TLS 1.2/1.3 spec (required for most HTTPS servers).
            4096: reduced memory, but some servers may reject the connection.""",
        ),
        "ssl_out_content_len": attr.int(
            default = 4096,
            doc = """CONFIG_MBEDTLS_SSL_OUT_CONTENT_LEN — max outgoing TLS record (bytes).
            4096: sufficient for most use cases (client sends small requests).
            16384: only needed if sending large TLS records.""",
        ),
    },
    doc = """Crypto/TLS configuration for AP core.
    Controls mbedTLS library on BK7258. For PSRAM memory allocation,
    use MBEDTLS_USE_PSRAM in psram.bzl instead.""",
)
