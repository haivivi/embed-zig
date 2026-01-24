//! Network modules

pub const socket = @import("net/socket.zig");
pub const dns = @import("net/dns.zig");

pub const Socket = socket.Socket;
pub const DnsResolver = dns.DnsResolver;
pub const Ipv4Address = socket.Ipv4Address;
pub const parseIpv4 = socket.parseIpv4;
pub const formatIpv4 = dns.formatIpv4;
