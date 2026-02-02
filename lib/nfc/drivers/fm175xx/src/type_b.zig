//! ISO14443B (Type B) Protocol Implementation
//!
//! Implements Type B card activation.

const std = @import("std");
const nfc = @import("nfc");
const regs = @import("regs.zig");

const TypeB = nfc.protocol.TypeB;

/// Type B Protocol Operations
pub fn Protocol(comptime Driver: type) type {
    return struct {
        const Self = @This();

        driver: *Driver,

        // ========== Card Activation ==========

        /// Activate a Type B card (REQB -> ATTRIB)
        pub fn activate(self: *Self) !nfc.TypeBCard {
            var card = nfc.TypeBCard{};

            // Step 1: Request B
            try self.request(&card);

            // Step 2: ATTRIB
            try self.attrib(&card);

            return card;
        }

        /// Send REQB command
        pub fn request(self: *Self, card: *nfc.TypeBCard) !void {
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(1);

            // REQB: APf=0x05, AFI=0x00, PARAM=0x00
            const tx_data = [_]u8{ TypeB.CMD_REQB, TypeB.AFI_ALL, TypeB.PARAM_REQB };
            var rx_buf: [14]u8 = undefined; // 12 ATQB + 2 CRC

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            if (result.bytes_received < 12) {
                return error.InvalidResponse;
            }

            @memcpy(&card.atqb, rx_buf[0..12]);
            card.parseAtqb();
        }

        /// Send WUPB command (wake up)
        pub fn wakeup(self: *Self, card: *nfc.TypeBCard) !void {
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(1);

            // WUPB: APf=0x05, AFI=0x00, PARAM=0x08
            const tx_data = [_]u8{ TypeB.CMD_REQB, TypeB.AFI_ALL, TypeB.PARAM_WUPB };
            var rx_buf: [14]u8 = undefined;

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            if (result.bytes_received < 12) {
                return error.InvalidResponse;
            }

            @memcpy(&card.atqb, rx_buf[0..12]);
            card.parseAtqb();
        }

        /// Send ATTRIB command
        pub fn attrib(self: *Self, card: *nfc.TypeBCard) !void {
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(1);

            // ATTRIB command
            var tx_data: [9]u8 = undefined;
            tx_data[0] = TypeB.CMD_ATTRIB;
            @memcpy(tx_data[1..5], &card.pupi);
            tx_data[5] = 0x00; // Param1: SOF/EOF, TR0/TR1
            tx_data[6] = 0x08; // Param2: Max frame size (256 bytes)
            tx_data[7] = 0x01; // Param3: ISO14443-4 compatible
            tx_data[8] = 0x01; // Param4: CID

            var rx_buf: [12]u8 = undefined;

            const result = try self.driver.transceive(&tx_data, &rx_buf, 0);

            if (result.bytes_received < 1) {
                return error.InvalidResponse;
            }

            card.attrib_len = @intCast(@min(result.bytes_received, card.attrib.len));
            @memcpy(card.attrib[0..card.attrib_len], rx_buf[0..card.attrib_len]);
        }

        /// Send HLTB command (halt)
        pub fn halt(self: *Self, pupi: *const [4]u8) !void {
            try self.enableCrc(true);
            try self.driver.setTimeoutMs(5);

            var tx_data: [5]u8 = undefined;
            tx_data[0] = TypeB.CMD_HLTB;
            @memcpy(tx_data[1..5], pupi);

            var rx_buf: [1]u8 = undefined;
            _ = try self.driver.transceive(&tx_data, &rx_buf, 0);
        }

        // ========== Helper Methods ==========

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
