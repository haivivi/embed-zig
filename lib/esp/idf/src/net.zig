//! Network modules

pub const socket = @import("net/socket.zig");
pub const netif = @import("net/netif.zig");
pub const dns = @import("net/dns.zig");

pub const Socket = socket.Socket;
pub const Ipv4Address = socket.Ipv4Address;
pub const parseIpv4 = socket.parseIpv4;
