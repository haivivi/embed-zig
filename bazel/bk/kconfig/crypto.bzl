"""BK7258 Kconfig: enable full mbedTLS crypto."""

def _bk_crypto_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# Full mbedTLS crypto (required for TLS/HTTPS)",
        "CONFIG_FULL_MBEDTLS=y",
        "# Task stack in PSRAM (needed for TLS — 128KB stack from 8MB PSRAM)",
        "CONFIG_PSRAM_AS_SYS_MEMORY=y",
        "CONFIG_TASK_STACK_IN_PSRAM=y",
        "# TLS record buffer sizes (default 4096 is too small for many servers)",
        "# TLS max record payload is 16384 bytes; servers like httpbin.org send large records",
        "CONFIG_MBEDTLS_SSL_IN_CONTENT_LEN=16384",
        "CONFIG_MBEDTLS_SSL_OUT_CONTENT_LEN=4096",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_crypto = rule(
    implementation = _bk_crypto_impl,
    attrs = {},
    doc = "Enable full mbedTLS (SHA512, HKDF, ECDH, etc.) + TLS-ready buffer sizes",
)
