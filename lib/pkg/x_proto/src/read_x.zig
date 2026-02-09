//! read_x — READ_X protocol state machine (Server → Client)
//!
//! Server-side state machine for the READ_X chunked transfer protocol.
//! Sends large data blocks to the client using notify/indicate, with
//! loss detection and retransmission.
//!
//! ## Transport Interface
//!
//! The `Transport` type must provide:
//!
//! ```zig
//! /// Send data to the peer (GATT notify/indicate).
//! fn send(self: *Transport, data: []const u8) !void
//!
//! /// Receive data from the peer with timeout.
//! /// Returns bytes read, or `null` on timeout.
//! fn recv(self: *Transport, buf: []u8, timeout_ms: u32) !?usize
//! ```
//!
//! ## Protocol Flow
//!
//! 1. Wait for start magic (0xFFFF0001) from client
//! 2. Send all data chunks via notify, each with 3-byte header
//! 3. Wait for ACK (0xFFFF) or loss list from client
//! 4. If loss list → retransmit marked chunks → goto 3
//! 5. If ACK → transfer complete

const chunk = @import("chunk.zig");

pub fn ReadX(comptime Transport: type) type {
    return struct {
        const Self = @This();

        transport: *Transport,
        data: []const u8,
        mtu: u16,
        send_redundancy: u8,
        start_timeout_ms: u32,
        ack_timeout_ms: u32,

        pub const Options = struct {
            mtu: u16 = 247,
            /// How many times each chunk is sent (FEC-style redundancy).
            /// BLE notify is unreliable; sending 3x improves first-pass delivery.
            send_redundancy: u8 = 3,
            /// Timeout waiting for start magic from client (ms).
            start_timeout_ms: u32 = 5_000,
            /// Timeout waiting for ACK or loss list after sending all chunks (ms).
            ack_timeout_ms: u32 = 20_000,
        };

        pub fn init(transport: *Transport, data: []const u8, options: Options) Self {
            return .{
                .transport = transport,
                .data = data,
                .mtu = options.mtu,
                .send_redundancy = options.send_redundancy,
                .start_timeout_ms = options.start_timeout_ms,
                .ack_timeout_ms = options.ack_timeout_ms,
            };
        }

        /// Run the READ_X protocol to completion.
        ///
        /// Blocks until the client ACKs all data or an error/timeout occurs.
        pub fn run(self: *Self) !void {
            if (self.data.len == 0) return error.EmptyData;

            const dcs = chunk.dataChunkSize(self.mtu);
            const total_usize = chunk.chunksNeeded(self.data.len, self.mtu);
            if (total_usize > chunk.max_chunks) return error.TooManyChunks;
            const total: u16 = @intCast(total_usize);

            const mask_len = chunk.Bitmask.requiredBytes(total);
            var sndmask: [chunk.max_mask_bytes]u8 = undefined;
            chunk.Bitmask.initAllSet(sndmask[0..mask_len], total);

            var recv_buf: [chunk.max_mtu]u8 = undefined;

            // Phase 1: Wait for start magic from client
            const start_len = (try self.transport.recv(&recv_buf, self.start_timeout_ms)) orelse
                return error.Timeout;
            if (!chunk.isStartMagic(recv_buf[0..start_len])) return error.InvalidStartMagic;

            // Phase 2: Send/retransmit loop
            while (true) {
                try self.sendMarkedChunks(sndmask[0..mask_len], total, dcs);

                // Wait for ACK or loss list
                const resp_len = (try self.transport.recv(&recv_buf, self.ack_timeout_ms)) orelse
                    return error.Timeout;

                if (chunk.isAck(recv_buf[0..resp_len])) return; // Transfer complete!

                // Parse loss list, mark chunks for retransmission
                chunk.Bitmask.initClear(sndmask[0..mask_len], total);
                var loss_seqs: [260]u16 = undefined;
                const loss_count = chunk.decodeLossList(recv_buf[0..resp_len], &loss_seqs);
                if (loss_count == 0) return error.InvalidResponse;

                for (loss_seqs[0..loss_count]) |seq| {
                    if (seq >= 1 and seq <= total) {
                        chunk.Bitmask.set(sndmask[0..mask_len], seq);
                    }
                }
            }
        }

        /// Send all chunks whose bit is set in `sndmask`.
        fn sendMarkedChunks(self: *Self, sndmask: []const u8, total: u16, dcs: usize) !void {
            var chunk_buf: [chunk.max_mtu]u8 = undefined;
            var i: u16 = 0;
            while (i < total) : (i += 1) {
                const seq: u16 = i + 1;
                if (!chunk.Bitmask.isSet(sndmask, seq)) continue;

                // Encode header
                const hdr = (chunk.Header{ .total = total, .seq = seq }).encode();
                @memcpy(chunk_buf[0..chunk.header_size], &hdr);

                // Compute payload range
                const offset: usize = @as(usize, i) * dcs;
                const remaining = self.data.len - offset;
                const payload_len: usize = @min(remaining, dcs);

                // Copy payload
                @memcpy(
                    chunk_buf[chunk.header_size .. chunk.header_size + payload_len],
                    self.data[offset .. offset + payload_len],
                );

                // Send with redundancy
                const total_len = chunk.header_size + payload_len;
                for (0..self.send_redundancy) |_| {
                    try self.transport.send(chunk_buf[0..total_len]);
                }
            }
        }
    };
}
