"""BK7258 Kconfig: enable full mbedTLS crypto."""

def _bk_crypto_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    lines = [
        "# Full mbedTLS crypto (required for TLS/HTTPS)",
        "CONFIG_FULL_MBEDTLS=y",
        "# Task stack in PSRAM (needed for TLS — 128KB stack from 8MB PSRAM)",
        "CONFIG_PSRAM_AS_SYS_MEMORY=y",
        "CONFIG_TASK_STACK_IN_PSRAM=y",
    ]
    ctx.actions.write(output = out, content = "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

bk_crypto = rule(
    implementation = _bk_crypto_impl,
    attrs = {},
    doc = "Enable full mbedTLS (SHA512, HKDF, ECDH, etc.)",
)
