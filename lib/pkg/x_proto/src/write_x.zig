//! write_x — WRITE_X protocol state machine (Client → Server)
//!
//! Server-side state machine for the WRITE_X chunked transfer protocol.
//! Receives large data blocks from the client via GATT writes, with
//! loss detection and retransmission requests.
//!
//! ## Transport Interface
//!
//! Same as read_x — the `Transport` type must provide `send` and `recv`.
//!
//! ## Protocol Flow
//!
//! 1. Receive chunks from client (each has 3-byte header + data)
//! 2. Track received chunks with bitmask
//! 3. If all received → send ACK (0xFFFF) → return data
//! 4. If timeout → send loss list → continue receiving
//! 5. If max retries exceeded → error

const chunk = @import("chunk.zig");

pub fn WriteX(comptime Transport: type) type {
    return struct {
        const Self = @This();

        transport: *Transport,
        recv_buf: []u8,
        mtu: u16,
        timeout_ms: u32,
        max_retries: u8,

        pub const Options = struct {
            mtu: u16 = 247,
            /// Timeout waiting for next chunk (ms). On timeout, sends loss list.
            timeout_ms: u32 = 3_000,
            /// Max consecutive timeouts before giving up.
            max_retries: u8 = 5,
        };

        /// Result of a successful WRITE_X transfer.
        pub const Result = struct {
            /// Slice of the caller-provided recv_buf containing the received data.
            data: []const u8,
        };

        pub fn init(transport: *Transport, recv_buf: []u8, options: Options) Self {
            return .{
                .transport = transport,
                .recv_buf = recv_buf,
                .mtu = options.mtu,
                .timeout_ms = options.timeout_ms,
                .max_retries = options.max_retries,
            };
        }

        /// Run the WRITE_X protocol to completion.
        ///
        /// Blocks until all chunks are received or an error/timeout occurs.
        /// Returns a Result whose `.data` is a slice of the caller-provided recv_buf.
        pub fn run(self: *Self) !Result {
            const dcs = chunk.dataChunkSize(self.mtu);
            const max_chunk_msg = @as(usize, self.mtu) - chunk.att_overhead;

            var rcvmask: [chunk.max_mask_bytes]u8 = undefined;
            var total: u16 = 0;
            var last_chunk_len: usize = 0;
            var initialized = false;
            var timeout_count: u8 = 0;

            var msg_buf: [chunk.max_mtu]u8 = undefined;

            while (true) {
                const msg_n = try self.transport.recv(&msg_buf, self.timeout_ms);

                if (msg_n) |msg_len| {
                    // -- Received a chunk --
                    timeout_count = 0;

                    if (msg_len < chunk.header_size) return error.InvalidPacket;
                    if (msg_len > max_chunk_msg) return error.ChunkTooLarge;

                    const hdr = chunk.Header.decode(msg_buf[0..chunk.header_size]);
                    try hdr.validate();

                    if (!initialized) {
                        // First chunk: learn total and initialize tracking
                        total = hdr.total;
                        const mask_len = chunk.Bitmask.requiredBytes(total);
                        chunk.Bitmask.initClear(rcvmask[0..mask_len], total);

                        const needed: usize = @as(usize, total) * dcs;
                        if (needed > self.recv_buf.len) return error.BufferTooSmall;

                        initialized = true;
                    } else {
                        if (hdr.total != total) return error.TotalMismatch;
                    }

                    // Copy payload into recv_buf at the correct offset
                    const payload_len = msg_len - chunk.header_size;
                    const idx: usize = @as(usize, hdr.seq) - 1;
                    const write_at: usize = idx * dcs;
                    @memcpy(
                        self.recv_buf[write_at .. write_at + payload_len],
                        msg_buf[chunk.header_size .. chunk.header_size + payload_len],
                    );

                    // Track last chunk length for final data size calculation
                    if (hdr.seq == total) {
                        last_chunk_len = payload_len;
                    }

                    // Update bitmask
                    const mask_len = chunk.Bitmask.requiredBytes(total);
                    chunk.Bitmask.set(rcvmask[0..mask_len], hdr.seq);

                    // Check completeness
                    if (chunk.Bitmask.isComplete(rcvmask[0..mask_len], total)) {
                        // All chunks received — send ACK
                        try self.transport.send(&chunk.ack_signal);
                        const data_len = (@as(usize, total) - 1) * dcs + last_chunk_len;
                        return .{ .data = self.recv_buf[0..data_len] };
                    }
                } else {
                    // -- Timeout --
                    timeout_count += 1;
                    if (timeout_count > self.max_retries) return error.Timeout;

                    // If not initialized yet, just wait more (no loss list to send)
                    if (!initialized) continue;

                    // Build and send loss list
                    const mask_len = chunk.Bitmask.requiredBytes(total);
                    var loss_seqs: [260]u16 = undefined;
                    const max_seqs: usize = max_chunk_msg / 2;
                    const loss_count = chunk.Bitmask.collectMissing(
                        rcvmask[0..mask_len],
                        total,
                        loss_seqs[0..@min(loss_seqs.len, max_seqs)],
                    );

                    if (loss_count == 0) continue; // shouldn't happen, but don't crash

                    var send_buf: [chunk.max_mtu]u8 = undefined;
                    const encoded = chunk.encodeLossList(loss_seqs[0..loss_count], &send_buf);
                    try self.transport.send(encoded);
                }
            }
        }
    };
}
