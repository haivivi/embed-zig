//! TLS Common Types and Constants
//!
//! Defines protocol constants, types, and structures shared across
//! the TLS implementation.

const std = @import("std");

// ============================================================================
// Protocol Versions
// ============================================================================

pub const ProtocolVersion = enum(u16) {
    tls_1_0 = 0x0301,
    tls_1_1 = 0x0302,
    tls_1_2 = 0x0303,
    tls_1_3 = 0x0304,

    pub fn name(self: ProtocolVersion) []const u8 {
        return switch (self) {
            .tls_1_0 => "TLS 1.0",
            .tls_1_1 => "TLS 1.1",
            .tls_1_2 => "TLS 1.2",
            .tls_1_3 => "TLS 1.3",
        };
    }
};

// ============================================================================
// Record Types
// ============================================================================

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
    _,
};

// ============================================================================
// Handshake Types
// ============================================================================

pub const HandshakeType = enum(u8) {
    client_hello = 1,
    server_hello = 2,
    new_session_ticket = 4,
    end_of_early_data = 5,
    encrypted_extensions = 8,
    certificate = 11,
    server_key_exchange = 12,
    certificate_request = 13,
    server_hello_done = 14,
    certificate_verify = 15,
    client_key_exchange = 16,
    finished = 20,
    key_update = 24,
    message_hash = 254,
    _,
};

// ============================================================================
// Cipher Suites
// ============================================================================

pub const CipherSuite = enum(u16) {
    // TLS 1.3
    TLS_AES_128_GCM_SHA256 = 0x1301,
    TLS_AES_256_GCM_SHA384 = 0x1302,
    TLS_CHACHA20_POLY1305_SHA256 = 0x1303,

    // TLS 1.2 ECDHE
    TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 = 0xC02B,
    TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 = 0xC02C,
    TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 = 0xC02F,
    TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 = 0xC030,
    TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 = 0xCCA8,
    TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 = 0xCCA9,
    _,

    pub fn isTls13(self: CipherSuite) bool {
        return switch (self) {
            .TLS_AES_128_GCM_SHA256,
            .TLS_AES_256_GCM_SHA384,
            .TLS_CHACHA20_POLY1305_SHA256,
            => true,
            else => false,
        };
    }

    pub fn keyLength(self: CipherSuite) u8 {
        return switch (self) {
            .TLS_AES_128_GCM_SHA256,
            .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            => 16,
            .TLS_AES_256_GCM_SHA384,
            .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
            .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
            => 32,
            .TLS_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
            => 32,
            else => 0,
        };
    }

    pub fn ivLength(self: CipherSuite) u8 {
        return switch (self) {
            .TLS_AES_128_GCM_SHA256,
            .TLS_AES_256_GCM_SHA384,
            .TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
            .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
            => 12,
            .TLS_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
            => 12,
            else => 0,
        };
    }

    pub fn tagLength(self: CipherSuite) u8 {
        _ = self;
        return 16; // All supported suites use 16-byte tags
    }
};

// ============================================================================
// Named Groups (Key Exchange)
// ============================================================================

pub const NamedGroup = enum(u16) {
    secp256r1 = 23,
    secp384r1 = 24,
    secp521r1 = 25,
    x25519 = 29,
    x448 = 30,
    // Post-quantum hybrids
    x25519_mlkem768 = 4588,
    _,
};

// ============================================================================
// Signature Schemes
// ============================================================================

pub const SignatureScheme = enum(u16) {
    // RSASSA-PKCS1-v1_5
    rsa_pkcs1_sha256 = 0x0401,
    rsa_pkcs1_sha384 = 0x0501,
    rsa_pkcs1_sha512 = 0x0601,

    // ECDSA
    ecdsa_secp256r1_sha256 = 0x0403,
    ecdsa_secp384r1_sha384 = 0x0503,
    ecdsa_secp521r1_sha512 = 0x0603,

    // RSASSA-PSS
    rsa_pss_rsae_sha256 = 0x0804,
    rsa_pss_rsae_sha384 = 0x0805,
    rsa_pss_rsae_sha512 = 0x0806,
    rsa_pss_pss_sha256 = 0x0809,
    rsa_pss_pss_sha384 = 0x080a,
    rsa_pss_pss_sha512 = 0x080b,

    // EdDSA
    ed25519 = 0x0807,
    ed448 = 0x0808,

    // Legacy
    rsa_pkcs1_sha1 = 0x0201,
    ecdsa_sha1 = 0x0203,
    _,
};

// ============================================================================
// Extensions
// ============================================================================

pub const ExtensionType = enum(u16) {
    server_name = 0,
    max_fragment_length = 1,
    status_request = 5,
    supported_groups = 10,
    ec_point_formats = 11,
    signature_algorithms = 13,
    use_srtp = 14,
    heartbeat = 15,
    application_layer_protocol_negotiation = 16,
    signed_certificate_timestamp = 18,
    client_certificate_type = 19,
    server_certificate_type = 20,
    padding = 21,
    extended_master_secret = 23,
    session_ticket = 35,
    pre_shared_key = 41,
    early_data = 42,
    supported_versions = 43,
    cookie = 44,
    psk_key_exchange_modes = 45,
    certificate_authorities = 47,
    oid_filters = 48,
    post_handshake_auth = 49,
    signature_algorithms_cert = 50,
    key_share = 51,
    renegotiation_info = 65281,
    _,
};

// ============================================================================
// Alerts
// ============================================================================

pub const AlertLevel = enum(u8) {
    warning = 1,
    fatal = 2,
    _,
};

pub const AlertDescription = enum(u8) {
    close_notify = 0,
    unexpected_message = 10,
    bad_record_mac = 20,
    decryption_failed_reserved = 21,
    record_overflow = 22,
    decompression_failure_reserved = 30,
    handshake_failure = 40,
    no_certificate_reserved = 41,
    bad_certificate = 42,
    unsupported_certificate = 43,
    certificate_revoked = 44,
    certificate_expired = 45,
    certificate_unknown = 46,
    illegal_parameter = 47,
    unknown_ca = 48,
    access_denied = 49,
    decode_error = 50,
    decrypt_error = 51,
    export_restriction_reserved = 60,
    protocol_version = 70,
    insufficient_security = 71,
    internal_error = 80,
    inappropriate_fallback = 86,
    user_canceled = 90,
    no_renegotiation_reserved = 100,
    missing_extension = 109,
    unsupported_extension = 110,
    certificate_unobtainable_reserved = 111,
    unrecognized_name = 112,
    bad_certificate_status_response = 113,
    bad_certificate_hash_value_reserved = 114,
    unknown_psk_identity = 115,
    certificate_required = 116,
    no_application_protocol = 120,
    _,
};

pub const Alert = struct {
    level: AlertLevel,
    description: AlertDescription,
};

// ============================================================================
// Size Constants
// ============================================================================

pub const MAX_PLAINTEXT_LEN = 16384; // 2^14
pub const MAX_CIPHERTEXT_LEN = 16384 + 256; // TLS 1.3
pub const MAX_CIPHERTEXT_LEN_TLS12 = 16384 + 2048; // TLS 1.2
pub const RECORD_HEADER_LEN = 5;
pub const MAX_HANDSHAKE_LEN = 65536;

// ============================================================================
// Change Cipher Spec
// ============================================================================

pub const ChangeCipherSpecType = enum(u8) {
    change_cipher_spec = 1,
    _,
};

// ============================================================================
// Compression Methods
// ============================================================================

pub const CompressionMethod = enum(u8) {
    null = 0,
    _,
};

// ============================================================================
// PSK Key Exchange Modes
// ============================================================================

pub const PskKeyExchangeMode = enum(u8) {
    psk_ke = 0,
    psk_dhe_ke = 1,
    _,
};

// ============================================================================
// Tests
// ============================================================================

test "CipherSuite properties" {
    const suite = CipherSuite.TLS_AES_128_GCM_SHA256;
    try std.testing.expect(suite.isTls13());
    try std.testing.expectEqual(@as(u8, 16), suite.keyLength());
    try std.testing.expectEqual(@as(u8, 12), suite.ivLength());
}

test "ProtocolVersion names" {
    try std.testing.expectEqualStrings("TLS 1.3", ProtocolVersion.tls_1_3.name());
    try std.testing.expectEqualStrings("TLS 1.2", ProtocolVersion.tls_1_2.name());
}
