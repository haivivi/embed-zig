//! ISO14443A (Type A) Protocol Implementation
//!
//! Implements Type A card activation and NTAG/Mifare Ultralight operations.

const std = @import("std");
const nfc = @import("nfc");
const regs = @import("regs.zig");

const TypeA = nfc.protocol.TypeA;
const Ntag = nfc.protocol.Ntag;

/// Type A Protocol Operations
pub fn Protocol(comptime Driver: type) type {
    return struct {
        const Self = @This();

        driver: *Driver,

        // ========== Card Activation ==========

        /// Activate a Type A card (full sequence: REQA -> Anticollision -> Select)
        pub fn activate(self: *Self) !nfc.TypeACard {
            var card = nfc.TypeACard{};

            // Step 1: Request (REQA)
            try self.request(&card);

            // Step 2: Determine cascade level from ATQA
            card.cascade_level = switch (card.atqa[0] & 0xC0) {
                0x00 => 1, // Single size UID (4 bytes)
                0x40 => 2, // Double size UID (7 bytes)
                0x80 => 3, // Triple size UID (10 bytes)
                else => return error.InvalidAtqa,
            };

            // Step 3: Anticollision and Select for each cascade level
            var uid_offset: usize = 0;
            for (0..card.cascade_level) |level| {
                const cascade_level: u2 = @intCast(level);

                // Anticollision
                var uid_part: [5]u8 = undefined;
                try self.anticollision(cascade_level, &uid_part);

                // Verify BCC
                const bcc = uid_part[0] ^ uid_part[1] ^ uid_part[2] ^ uid_part[3];
                if (bcc != uid_part[4]) {
                    return error.BccError;
                }

                // Store UID bytes (skip cascade tag 0x88 if present)
                if (uid_part[0] == TypeA.CASCADE_TAG and level < card.cascade_level - 1) {
                    // Cascade tag present, copy only 3 bytes
                    @memcpy(card.uid[uid_offset..][0..3], uid_part[1..4]);
                    uid_offset += 3;
                } else {
                    // No cascade tag, copy all 4 bytes
                    @memcpy(card.uid[uid_offset..][0..4], uid_part[0..4]);
                    uid_offset += 4;
                }

                // Select
                const sak = try self.selectCard(cascade_level, &uid_part);
                card.sak[level] = sak;
            }

            card.uid_len = @intCast(uid_offset);

            return card;
        }

        /// Send REQA command
        pub fn request(self: *Self, card: *nfc.TypeACard) !void {
            try self.prepareShortFrame();
            try self.driver.setTimeoutMs(1);

            const tx_data = [_]u8{TypeA.CMD_REQA};
            var rx_buf: [2]u8 = undefined;

            const result = try self.driver.transceive(&tx_data, &rx_buf, 7); // 7 bits

            if (result.bytes_received != 2) {
                return error.InvalidResponse;
            }

            @memcpy(&card.atqa, &rx_buf);
        }

        /// Send WUPA command (wake up)
        pub fn wakeup(self: *Self, card: *nfc.TypeACard) !void {
            try self.prepareShortFrame();
            try self.driver.setTimeoutMs(1);

            const tx_data = [_]u8{TypeA.CMD_WUPA};
            var rx_buf: [2]u8 = undefined;

            const result = try self.driver.transceive(&tx_data, &rx_buf, 7); // 7 bits

            if (result.bytes_received != 2) {
                return error.InvalidResponse;
            }

            @memcpy(&card.atqa, &rx_buf);
        }

        /// Anticollision for specified cascade level
        pub fn anticollision(self: *Self, level: u2, uid_out: *[5]u8) !void {
            try self.prepareStandardFrame();
            try self.driver.setTimeoutMs(1);

            // Enable collision handling
            try self.driver.setBits(.coll, regs.CollBits.VALUES_AFTER_COLL);

            const cmd = TypeA.CMD_ANTICOLL[level];
            const tx_data = [_]u8{ cmd, TypeA.NVB_ANTICOLL };
            var rx_buf: [5]u8 = undefined;

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            if (result.bytes_received != 5) {
                return error.InvalidResponse;
            }

            @memcpy(uid_out, &rx_buf);
        }

        /// Select card at specified cascade level
        pub fn selectCard(self: *Self, level: u2, uid: *const [5]u8) !u8 {
            try self.prepareStandardFrame();
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(1);

            const cmd = TypeA.CMD_SELECT[level];
            var tx_data: [7]u8 = undefined;
            tx_data[0] = cmd;
            tx_data[1] = TypeA.NVB_SELECT;
            @memcpy(tx_data[2..7], uid);

            var rx_buf: [3]u8 = undefined; // SAK + CRC

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            if (result.bytes_received < 1) {
                return error.InvalidResponse;
            }

            return rx_buf[0]; // SAK
        }

        /// Send HALT command
        pub fn halt(self: *Self) !void {
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(5);

            const tx_data = [_]u8{ TypeA.CMD_HALT, 0x00 };
            try self.driver.transmit(&tx_data);
        }

        // ========== NTAG / Mifare Ultralight Operations ==========

        /// Read 16 bytes (4 pages) from NTAG/Ultralight
        pub fn ntagRead(self: *Self, start_page: u8, buf: *[16]u8) !void {
            try self.prepareStandardFrame();
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(5);

            const tx_data = [_]u8{ Ntag.CMD_READ, start_page };
            var rx_buf: [18]u8 = undefined; // 16 data + 2 CRC

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            if (result.bytes_received < 16) {
                return error.InvalidResponse;
            }

            @memcpy(buf, rx_buf[0..16]);
        }

        /// Write 4 bytes (1 page) to NTAG/Ultralight
        pub fn ntagWrite(self: *Self, page: u8, data: *const [4]u8) !void {
            try self.prepareStandardFrame();
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(5);

            var tx_data: [6]u8 = undefined;
            tx_data[0] = Ntag.CMD_WRITE;
            tx_data[1] = page;
            @memcpy(tx_data[2..6], data);

            var rx_buf: [1]u8 = undefined;

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            // Check for ACK (4 bits, value 0x0A)
            if (result.bits_received != 4 or (rx_buf[0] & 0x0F) != Ntag.ACK) {
                return error.WriteNak;
            }
        }

        /// Read all NTAG data (determines size from CC)
        pub fn ntagReadAll(self: *Self, buf: []u8) !usize {
            if (buf.len < 16) {
                return error.BufferTooSmall;
            }

            // Read first 16 bytes (pages 0-3)
            var first_block: [16]u8 = undefined;
            try self.ntagRead(0, &first_block);
            @memcpy(buf[0..16], &first_block);

            // CC byte at offset 14 contains size info
            // Size = 8 * CC[2] bytes
            const total_size: usize = 16 + @as(usize, first_block[14]) * 8;

            if (buf.len < total_size) {
                return error.BufferTooSmall;
            }

            // Read remaining data in 16-byte chunks
            var offset: usize = 16;
            var page: u8 = 4;
            while (offset < total_size) {
                var block: [16]u8 = undefined;
                try self.ntagRead(page, &block);

                const to_copy = @min(16, total_size - offset);
                @memcpy(buf[offset..][0..to_copy], block[0..to_copy]);

                offset += 16;
                page += 4;
            }

            return total_size;
        }

        /// Get NTAG version info
        pub fn ntagGetVersion(self: *Self) ![8]u8 {
            try self.prepareStandardFrame();
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(5);

            const tx_data = [_]u8{Ntag.CMD_GET_VERSION};
            var rx_buf: [10]u8 = undefined; // 8 data + 2 CRC

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            if (result.bytes_received < 8) {
                return error.InvalidResponse;
            }

            return rx_buf[0..8].*;
        }

        // ========== Helper Methods ==========

        /// Prepare for short frame transmission (7-bit commands)
        fn prepareShortFrame(self: *Self) !void {
            try self.driver.clearBits(.tx_mode, regs.TxRxModeBits.CRC_EN);
            try self.driver.clearBits(.rx_mode, regs.TxRxModeBits.CRC_EN);
            try self.driver.clearBits(.status2, regs.Status2Bits.CRYPTO1_ON);
            try self.driver.writeReg(.bit_framing, 0x07); // 7 bits
        }

        /// Prepare for standard frame transmission
        fn prepareStandardFrame(self: *Self) !void {
            try self.driver.clearBits(.tx_mode, regs.TxRxModeBits.CRC_EN);
            try self.driver.clearBits(.rx_mode, regs.TxRxModeBits.CRC_EN);
            try self.driver.clearBits(.status2, regs.Status2Bits.CRYPTO1_ON);
            try self.driver.writeReg(.bit_framing, 0x00);
            try self.driver.writeReg(.coll, 0x80); // Clear collision bits
        }

        /// Enable/disable hardware CRC
        fn enableCrc(self: *Self, enable: bool) !void {
            if (enable) {
                try self.driver.setBits(.tx_mode, regs.TxRxModeBits.CRC_EN);
                try self.driver.setBits(.rx_mode, regs.TxRxModeBits.CRC_EN);
            } else {
                try self.driver.clearBits(.tx_mode, regs.TxRxModeBits.CRC_EN);
                try self.driver.clearBits(.rx_mode, regs.TxRxModeBits.CRC_EN);
            }
        }
    };
}
