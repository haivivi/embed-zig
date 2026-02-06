//! ESP32 Hardware Random Number Generator
//!
//! Uses the ESP32's true random number generator (TRNG) for cryptographic purposes.

// ESP-IDF random functions
extern fn esp_fill_random(buf: [*]u8, len: usize) void;

/// Fill buffer with cryptographically secure random bytes from ESP32 hardware RNG
pub fn fill(buf: []u8) void {
    esp_fill_random(buf.ptr, buf.len);
}
