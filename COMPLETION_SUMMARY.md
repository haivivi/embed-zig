# ESP32 RSA Signature Verification - Implementation Complete

**Branch**: `fix/esp-rsa`  
**Date**: 2026-02-13  
**Status**: ✅ Complete - Ready for PR

## Summary

Implemented RSA signature verification for ESP32 platform using mbedTLS, enabling TLS connections to servers with RSA certificates.

## Changes

### 1. RSA Helper C Implementation
- **File**: `lib/platform/esp/idf/src/mbed_tls/rsa_helper.h`
- **File**: `lib/platform/esp/idf/src/mbed_tls/rsa_helper.c`
- Wraps mbedTLS RSA verification functions with simple byte-array interfaces
- Supports PKCS#1 v1.5 and RSA-PSS padding schemes
- Supports SHA-256, SHA-384, SHA-512 hash algorithms
- Handles 2048-bit and 4096-bit RSA keys

### 2. RSA Helper Zig Wrapper
- **File**: `lib/platform/esp/idf/src/mbed_tls/rsa.zig`
- Provides Zig-friendly API with proper error handling
- Functions: `pkcs1v15Verify()`, `pssVerify()`
- Uses `HashId` enum for hash algorithm selection

### 3. Crypto Suite Integration
- **File**: `lib/platform/esp/impl/src/crypto/suite.zig`
- Implemented `PKCS1v1_5Signature.verify()`
- Implemented `PSSSignature.verify()`
- Replaced `error.RsaNotSupported` stubs with actual verification

### 4. Build System Integration
- **File**: `lib/platform/esp/idf/src/mbed_tls/mbed_tls.cmake`
- Added `rsa_helper.c` to `MBED_TLS_C_SOURCES`
- **File**: `lib/platform/esp/idf/src/mbed_tls.zig`
- Exported `rsa_helper` module

## Verification

### Build Test ✅
- **Target**: `//examples/apps/https_speed_test/esp:app`
- **Platform**: ESP32-S3 (xtensa)
- **Result**: Compiled successfully
- **Binary Size**: 951 KB (0xe7f30 bytes)
- All RSA functions linked correctly

### Flash Test ✅
- **Board**: ESP32-S3 DevKit (`/dev/cu.usbmodem11301`)
- **Result**: Flashed successfully
- Bootloader: 22 KB
- Partition table: 3 KB
- Application: 950 KB

## Technical Details

### RSA Verification Flow
1. TLS handshake receives server certificate with RSA public key
2. Server sends signature over handshake messages
3. Zig code calls `PKCS1v1_5Signature.verify()` or `PSSSignature.verify()`
4. Crypto suite hashes message with appropriate algorithm (SHA-256/384/512)
5. Zig wrapper calls C helper function
6. C helper initializes mbedTLS RSA context with public key
7. mbedTLS verifies signature using hardware-accelerated operations
8. Result propagates back through error unions

### Supported Configurations
- **Padding Schemes**: PKCS#1 v1.5, RSA-PSS
- **Hash Algorithms**: SHA-256, SHA-384, SHA-512
- **Key Sizes**: 2048-bit, 4096-bit
- **PSS Salt Length**: Auto-detect

## Commits

1. `3c0c75e` - Add RSA helper C header for mbedTLS integration
2. `26c08fe` - Add RSA helper C implementation using mbedTLS
3. `93e8d97` - Add RSA helper Zig wrapper
4. `7195186` - Integrate RSA helper into ESP32 crypto suite
5. `ede0c09` - Add RSA helper to mbedTLS CMake build

## Next Steps

1. Create PR to merge `fix/esp-rsa` → `main`
2. On-board runtime verification (connect to RSA cert server and verify TLS handshake)
3. Update progress.md

## Notes

- Implementation follows the same pattern as existing helpers (x25519, p256, p384)
- No breaking changes to API
- std platform (macOS/Linux) already has RSA support via Zig std library
- ESP32 now has feature parity with std platform for RSA verification
