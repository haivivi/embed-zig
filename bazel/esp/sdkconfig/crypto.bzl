# ESP-IDF Crypto Configuration
# Control mbedTLS usage and features

def _esp_crypto_impl(ctx):
    """Generate crypto sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    
    if ctx.attr.disable_mbedtls:
        # Disable mbedTLS entirely (use pure Zig crypto)
        lines.append("# Disable mbedTLS (using pure Zig crypto)")
        lines.append("CONFIG_MBEDTLS_TLS_ENABLED=n")
        lines.append("CONFIG_ESP_TLS_USING_MBEDTLS=n")
        lines.append("CONFIG_ESP_WIFI_MBEDTLS_CRYPTO=n")
        lines.append("CONFIG_ESP_WIFI_MBEDTLS_TLS_CLIENT=n")
        # WiFi enterprise requires mbedTLS, disable it
        lines.append("CONFIG_ESP_WIFI_ENTERPRISE_SUPPORT=n")
        # Disable certificate bundle
        lines.append("CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=n")
    else:
        # Enable mbedTLS with MINIMAL features for Zig TLS integration
        # Only enable what's strictly needed to reduce binary size
        lines.append("# Enable mbedTLS (minimal config for Zig TLS)")
        
        # SHA hash functions
        lines.append("CONFIG_MBEDTLS_SHA256_C=y")
        lines.append("CONFIG_MBEDTLS_SHA384_C=y")
        lines.append("CONFIG_MBEDTLS_SHA512_C=y")
        
        # Disable SHA hardware acceleration to avoid DMA issues
        lines.append("CONFIG_MBEDTLS_HARDWARE_SHA=n")
        
        # AES for AES-GCM
        lines.append("CONFIG_MBEDTLS_AES_C=y")
        
        # GCM - AES-GCM authenticated encryption (required)
        lines.append("CONFIG_MBEDTLS_GCM_C=y")
        # ESP32-S3 hardware acceleration for AES
        lines.append("CONFIG_MBEDTLS_HARDWARE_AES=y")
        
        # ChaCha20-Poly1305 - keep enabled (Zig compiles all cipher code)
        lines.append("CONFIG_MBEDTLS_CHACHAPOLY_C=y")
        lines.append("CONFIG_MBEDTLS_CHACHA20_C=y")
        lines.append("CONFIG_MBEDTLS_POLY1305_C=y")
        
        # ECP curves (X25519 uses Everest via C helper)
        lines.append("CONFIG_MBEDTLS_ECP_C=y")
        lines.append("CONFIG_MBEDTLS_ECDH_C=y")
        lines.append("CONFIG_MBEDTLS_ECP_DP_SECP256R1_ENABLED=y")
        # Enable P-384 for root CA verification (GlobalSign, DigiCert use P-384)
        lines.append("CONFIG_MBEDTLS_ECP_DP_SECP384R1_ENABLED=y")
        # Disable Curve25519 in mbedTLS (X25519 uses Everest C helper)
        lines.append("CONFIG_MBEDTLS_ECP_DP_CURVE25519_ENABLED=n")
        
        # Certificate Bundle - ESP-IDF built-in CA certificates (~130 root CAs)
        lines.append("CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y")
        lines.append("CONFIG_MBEDTLS_CERTIFICATE_BUNDLE_DEFAULT_FULL=y")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_crypto = rule(
    implementation = _esp_crypto_impl,
    attrs = {
        "disable_mbedtls": attr.bool(
            default = True,
            doc = "Disable mbedTLS entirely (use pure Zig crypto)",
        ),
        # Note: Fine-grained mbedTLS feature control (HKDF, GCM, ChaCha) not yet
        # implemented. When disable_mbedtls=False, all crypto features are enabled.
        # Add feature flags here when minimal mbedTLS builds are needed.
    },
    doc = """Crypto configuration - controls mbedTLS usage and features""",
)

CRYPTO_ATTRS = {
    "crypto": attr.label(
        allow_single_file = True,
        doc = "Crypto config from esp_crypto rule",
    ),
}
