//! macOS Platform Module
//!
//! Top-level module for macOS platform support.

pub const impl = @import("impl");
pub const darwin = @import("darwin");

/// Re-export commonly used types
pub const Socket = impl.Socket;
pub const Crypto = impl.Crypto;
