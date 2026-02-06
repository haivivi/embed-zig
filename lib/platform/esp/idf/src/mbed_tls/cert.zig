//! ESP CA Bundle Certificate Helper
//!
//! Wraps ESP-IDF's esp_crt_bundle API for certificate verification.

// C helper declaration
extern fn verify_with_esp_bundle(cert_der: [*]const u8, cert_len: usize) c_int;

/// Verify a certificate using ESP-IDF's built-in CA bundle
/// (~130 common root CAs)
pub fn verifyWithEspBundle(cert_der: []const u8) !void {
    const ret = verify_with_esp_bundle(cert_der.ptr, cert_der.len);
    if (ret != 0) {
        return error.VerificationFailed;
    }
}
