# Root CA Certificates

This directory contains root CA certificates for TLS verification.

## Usage

Root CA certificates can be loaded from Flash or PSRAM depending on your
embedded system's memory constraints.

### Bazel Configuration

```python
# In your BUILD.bazel
filegroup(
    name = "root_cas",
    srcs = ["//lib/crypto/certs:mozilla_roots.der"],
)

# Link to specific memory section
zig_binary(
    name = "my_app",
    ...
    data = [":root_cas"],
    # For Flash storage (read-only, saves RAM):
    # linkopts = ["--section=.rodata.certs=flash"],
    # For PSRAM storage (faster access):
    # linkopts = ["--section=.rodata.certs=psram"],
)
```

### Zig Usage

```zig
const crypto = @import("crypto");

// Load CA bundle from embedded data
const ca_bundle = @embedFile("certs/mozilla_roots.der");

// Create CA store
const ca_store = crypto.x509.CaStore{
    .roots = parseRootBundle(ca_bundle),
};

// Verify certificate chain
try crypto.x509.verifyChain(cert_chain, "example.com", ca_store, now_sec);
```

## Certificate Formats

- **DER**: Binary format, used directly
- **PEM**: Base64-encoded, needs decoding first

## Generating Root CA Bundle

To generate a minimal root CA bundle from Mozilla's CA bundle:

```bash
# Download Mozilla CA bundle
curl -o cacert.pem https://curl.se/ca/cacert.pem

# Convert to DER format (requires openssl)
# This creates individual DER files that can be concatenated
./scripts/generate_ca_bundle.sh cacert.pem output.der
```

## Memory Considerations

| Storage | Pros | Cons |
|---------|------|------|
| Flash | Saves RAM, persists | Slower access |
| PSRAM | Fast access | Uses external RAM |
| Internal RAM | Fastest | Limited space |

For ESP32 with PSRAM, consider loading CA bundle to PSRAM at boot time.
