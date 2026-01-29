//! Socket Implementation for ESP32
//!
//! Implements trait.socket using idf.socket (LWIP).
//!
//! Usage:
//!   const impl = @import("impl");
//!   const trait = @import("trait");
//!   const Socket = trait.socket.from(impl.Socket);

const std = @import("std");
const idf = @import("idf");

// Re-export idf.socket.Socket as the implementation
// It already implements the trait.socket interface
pub const Socket = idf.Socket;

// Re-export types for convenience
pub const Ipv4Address = idf.socket.Ipv4Address;
pub const Address = idf.socket.Address;
pub const SocketError = idf.socket.SocketError;
pub const Protocol = idf.socket.Protocol;
pub const Options = idf.socket.Options;

// Re-export functions
pub const tcp = idf.socket.tcp;
pub const udp = idf.socket.udp;
pub const create = idf.socket.create;
