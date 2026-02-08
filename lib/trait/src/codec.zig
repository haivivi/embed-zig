//! Codec Trait — Audio Encoder and Decoder contracts
//!
//! Validates that a type provides audio encoding or decoding capabilities.
//! Implementations may be software (opus, mp3) or hardware-accelerated.
//!
//! ## Encoder Contract
//!
//! ```zig
//! const MyEncoder = struct {
//!     pub fn encode(*MyEncoder, pcm: []const i16, frame_size: u32, out: []u8) ![]const u8;
//!     pub fn frameSize(*const MyEncoder) u32;
//! };
//! ```
//!
//! ## Decoder Contract
//!
//! ```zig
//! const MyDecoder = struct {
//!     pub fn decode(*MyDecoder, data: []const u8, pcm: []i16) ![]const i16;
//!     pub fn frameSize(*const MyDecoder) u32;
//! };
//! ```
//!
//! ## Usage
//!
//! ```zig
//! pub fn encodeLoop(comptime Src: type, comptime Enc: type, comptime Sink: type, ...) void {
//!     comptime { _ = codec.Encoder(Enc); }
//!     // ...
//! }
//! ```

/// Validate that Impl is a valid audio Encoder.
///
/// Required methods:
/// - `encode(*Impl, pcm: []const i16, frame_size: u32, out: []u8) anyerror![]const u8`
/// - `frameSize(*const Impl) u32`
pub fn Encoder(comptime Impl: type) type {
    comptime {
        const encode_fn = &Impl.encode;
        const RetType = @typeInfo(@TypeOf(encode_fn.*)).@"fn".return_type.?;
        const ret_info = @typeInfo(RetType);
        if (ret_info != .error_union) @compileError("Encoder.encode must return ![]const u8");

        _ = @as(*const fn (*const Impl) u32, &Impl.frameSize);
    }
    return Impl;
}

/// Validate that Impl is a valid audio Decoder.
///
/// Required methods:
/// - `decode(*Impl, data: []const u8, pcm: []i16) anyerror![]const i16`
/// - `frameSize(*const Impl) u32`
pub fn Decoder(comptime Impl: type) type {
    comptime {
        const decode_fn = &Impl.decode;
        const RetType = @typeInfo(@TypeOf(decode_fn.*)).@"fn".return_type.?;
        const ret_info = @typeInfo(RetType);
        if (ret_info != .error_union) @compileError("Decoder.decode must return ![]const i16");

        _ = @as(*const fn (*const Impl) u32, &Impl.frameSize);
    }
    return Impl;
}
