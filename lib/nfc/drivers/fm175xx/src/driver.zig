//! FM175XX NFC Reader Driver
//!
//! Platform-independent driver for FM175XX (compatible with MFRC522/PN512).
//!
//! Usage:
//! ```zig
//! const Fm175xx = @import("fm175xx").Fm175xx;
//!
//! var transport = I2cTransport.init(i2c, 0x28);
//! var nfc = Fm175xx(I2cTransport, Time).init(&transport);
//!
//! try nfc.softReset();
//! try nfc.setRf(.both);
//!
//! if (try nfc.activateTypeA()) |card| {
//!     // Card detected
//! }
//! ```

const std = @import("std");
const trait = @import("trait");
const nfc = @import("nfc");
const regs = @import("regs.zig");
const type_a = @import("type_a.zig");
const type_b = @import("type_b.zig");

pub const Reg = regs.Reg;
pub const Cmd = regs.Cmd;

/// RF antenna mode
pub const RfMode = enum(u2) {
    off = 0, // Both TX1 and TX2 off
    tx1 = 1, // TX1 only
    tx2 = 2, // TX2 only
    both = 3, // Both TX1 and TX2
};

/// Transceive result
pub const TransceiveResult = struct {
    bytes_received: usize,
    bits_received: usize, // Total bits (bytes * 8 + last_bits)
    last_bits: u3, // Valid bits in last byte (0 = all 8 bits valid)
    collision_pos: ?u5, // Collision position if any
    error_flags: u8, // Raw error register value
};

/// FM175XX Driver
pub fn Fm175xx(comptime Transport: type, comptime Time: type) type {
    // Validate Transport interface at comptime
    _ = trait.addr_io.from(Transport);
    _ = trait.time.from(Time);

    return struct {
        const Self = @This();

        transport: *Transport,

        /// Type A protocol operations
        pub const TypeA = type_a.Protocol(Self);
        /// Type B protocol operations
        pub const TypeB = type_b.Protocol(Self);

        // ========== Initialization ==========

        /// Initialize driver with transport
        pub fn init(transport: *Transport) Self {
            return .{ .transport = transport };
        }

        /// Perform soft reset and wait for ready
        pub fn softReset(self: *Self) !void {
            try self.writeReg(.command, @intFromEnum(Cmd.soft_reset));
            Time.sleepMs(2); // FM175XX needs ~1ms after reset

            // Verify reset completed
            const cmd = try self.readReg(.command);
            if (cmd != 0x20) { // Idle command with PowerDown cleared
                return error.ResetFailed;
            }
        }

        /// Read chip version
        pub fn getVersion(self: *Self) !regs.ChipVersion {
            const ver = try self.readReg(.version);
            return @enumFromInt(ver);
        }

        // ========== Register Access ==========

        /// Read a register
        pub fn readReg(self: *Self, reg: Reg) !u8 {
            return self.transport.readByte(@intFromEnum(reg));
        }

        /// Write a register
        pub fn writeReg(self: *Self, reg: Reg, value: u8) !void {
            return self.transport.writeByte(@intFromEnum(reg), value);
        }

        /// Modify register bits (read-modify-write)
        pub fn modifyReg(self: *Self, reg: Reg, mask: u8, set: bool) !void {
            var value = try self.readReg(reg);
            if (set) {
                value |= mask;
            } else {
                value &= ~mask;
            }
            try self.writeReg(reg, value);
        }

        /// Set bits in register
        pub fn setBits(self: *Self, reg: Reg, bits: u8) !void {
            try self.modifyReg(reg, bits, true);
        }

        /// Clear bits in register
        pub fn clearBits(self: *Self, reg: Reg, bits: u8) !void {
            try self.modifyReg(reg, bits, false);
        }

        // ========== FIFO Operations ==========

        /// Clear FIFO buffer
        pub fn clearFifo(self: *Self) !void {
            try self.setBits(.fifo_level, regs.FifoLevelBits.FLUSH_FIFO);
            const level = try self.readReg(.fifo_level);
            if ((level & regs.FifoLevelBits.LEVEL_MASK) != 0) {
                return error.FifoClearFailed;
            }
        }

        /// Get current FIFO level
        pub fn getFifoLevel(self: *Self) !u8 {
            const level = try self.readReg(.fifo_level);
            return level & regs.FifoLevelBits.LEVEL_MASK;
        }

        /// Write data to FIFO
        pub fn writeFifo(self: *Self, data: []const u8) !void {
            try self.transport.write(@intFromEnum(Reg.fifo_data), data);
        }

        /// Read data from FIFO
        pub fn readFifo(self: *Self, buf: []u8) !usize {
            const level = try self.getFifoLevel();
            const to_read = @min(level, buf.len);
            if (to_read > 0) {
                try self.transport.read(@intFromEnum(Reg.fifo_data), buf[0..to_read]);
            }
            return to_read;
        }

        // ========== RF Control ==========

        /// Set RF antenna mode
        pub fn setRf(self: *Self, mode: RfMode) !void {
            const current = try self.readReg(.tx_control);

            // Check if already in desired mode
            if ((current & 0x03) == @intFromEnum(mode)) {
                return;
            }

            switch (mode) {
                .off => try self.clearBits(.tx_control, 0x03),
                .tx1 => {
                    try self.clearBits(.tx_control, 0x02);
                    try self.setBits(.tx_control, 0x01);
                },
                .tx2 => {
                    try self.clearBits(.tx_control, 0x01);
                    try self.setBits(.tx_control, 0x02);
                },
                .both => try self.setBits(.tx_control, 0x03),
            }

            Time.sleepMs(10); // Wait for RF field to stabilize
        }

        // ========== Timer Configuration ==========

        /// Set timeout in microseconds
        /// Timer formula: timeout_us = (prescaler * 2 + 1) * reload / 13.56
        pub fn setTimeout(self: *Self, timeout_us: u32) !void {
            var prescaler: u16 = 0;
            var reload: u32 = 0;

            while (prescaler < 0xFFF) {
                reload = (@as(u64, timeout_us) * 13560 - 1) / (@as(u32, prescaler) * 2 + 1);
                if (reload < 0xFFFF) break;
                prescaler += 1;
            }

            const reload_u16: u16 = @truncate(reload & 0xFFFF);

            // Clear and set prescaler high bits
            try self.modifyReg(.t_mode, 0x0F, false);
            try self.modifyReg(.t_mode, @truncate(prescaler >> 8), true);

            // Set prescaler low byte
            try self.writeReg(.t_prescaler, @truncate(prescaler & 0xFF));

            // Set reload value
            try self.writeReg(.t_reload_hi, @truncate(reload_u16 >> 8));
            try self.writeReg(.t_reload_lo, @truncate(reload_u16 & 0xFF));
        }

        /// Set timeout in milliseconds
        pub fn setTimeoutMs(self: *Self, timeout_ms: u32) !void {
            try self.setTimeout(timeout_ms * 1000);
        }

        // ========== Command Execution ==========

        /// Execute a command and wait for completion
        pub fn executeCommand(self: *Self, cmd: Cmd) !void {
            try self.writeReg(.command, @intFromEnum(cmd));
        }

        /// Prepare for command execution
        fn prepareCommand(self: *Self) !void {
            try self.clearFifo();
            try self.writeReg(.command, @intFromEnum(Cmd.idle));
            try self.writeReg(.water_level, 0x20); // 32 bytes
            try self.writeReg(.comm_irq, 0x7F); // Clear all IRQ flags
        }

        /// Wait for command completion
        fn waitCommand(self: *Self, wait_irq: u8) !u8 {
            while (true) {
                const irq = try self.readReg(.comm_irq);

                // Timer timeout
                if ((irq & regs.CommBits.TIMER_IRQ) != 0) {
                    return error.Timeout;
                }

                // Error occurred
                if ((irq & regs.CommBits.ERR_IRQ) != 0) {
                    const err = try self.readReg(.@"error");
                    if ((err & regs.ErrBits.COLL_ERR) != 0) {
                        return error.Collision;
                    }
                    return error.CommunicationError;
                }

                // Expected IRQ received
                if ((irq & wait_irq) != 0) {
                    return irq;
                }

                Time.sleepMs(1);
            }
        }

        /// Finish command execution
        fn finishCommand(self: *Self) !void {
            try self.clearBits(.bit_framing, regs.BitFramingBits.START_SEND);
            try self.writeReg(.command, @intFromEnum(Cmd.idle));
        }

        // ========== Communication Operations ==========

        /// Transceive data (transmit and receive)
        pub fn transceive(
            self: *Self,
            tx_data: []const u8,
            rx_buf: []u8,
            tx_last_bits: u3,
        ) !TransceiveResult {
            try self.prepareCommand();

            // Enable auto timer
            try self.setBits(.t_mode, regs.TModeBits.T_AUTO);

            // Start transceive command
            try self.writeReg(.command, @intFromEnum(Cmd.transceive));

            // Write TX data to FIFO
            var tx_remaining = tx_data;
            while (tx_remaining.len > 0) {
                const chunk_size = @min(tx_remaining.len, 32);
                try self.writeFifo(tx_remaining[0..chunk_size]);
                tx_remaining = tx_remaining[chunk_size..];

                // Start transmission
                try self.writeReg(.bit_framing, regs.BitFramingBits.START_SEND | tx_last_bits);

                if (tx_remaining.len > 0) {
                    // Wait for LoAlert (FIFO below water level)
                    _ = try self.waitCommand(regs.CommBits.LO_ALERT_IRQ);
                    try self.writeReg(.comm_irq, regs.CommBits.LO_ALERT_IRQ);
                }
            }

            // Wait for RX complete
            const irq = self.waitCommand(regs.CommBits.RX_IRQ) catch |err| {
                try self.finishCommand();
                return err;
            };
            _ = irq;

            // Check for errors
            const err_flags = try self.readReg(.@"error");
            var result = TransceiveResult{
                .bytes_received = 0,
                .bits_received = 0,
                .last_bits = 0,
                .collision_pos = null,
                .error_flags = err_flags,
            };

            if ((err_flags & regs.ErrBits.COLL_ERR) != 0) {
                const coll = try self.readReg(.coll);
                result.collision_pos = @truncate(coll & regs.CollBits.COLL_POS_MASK);
            }

            // Read received data
            const control = try self.readReg(.control);
            result.last_bits = @truncate(control & regs.ControlBits.RX_LAST_BITS);

            const fifo_level = try self.getFifoLevel();
            result.bytes_received = try self.readFifo(rx_buf[0..@min(fifo_level, rx_buf.len)]);

            if (result.last_bits != 0) {
                result.bits_received = (result.bytes_received -| 1) * 8 + result.last_bits;
            } else {
                result.bits_received = result.bytes_received * 8;
            }

            try self.finishCommand();

            return result;
        }

        /// Transmit data only (no receive)
        pub fn transmit(self: *Self, tx_data: []const u8) !void {
            try self.prepareCommand();
            try self.setBits(.t_mode, regs.TModeBits.T_AUTO);
            try self.writeReg(.command, @intFromEnum(Cmd.transmit));

            try self.writeFifo(tx_data);
            try self.setBits(.bit_framing, regs.BitFramingBits.START_SEND);

            _ = try self.waitCommand(regs.CommBits.TX_IRQ);

            try self.finishCommand();
        }

        /// MIFARE authentication
        pub fn authenticate(self: *Self, auth_data: []const u8) !void {
            try self.prepareCommand();
            try self.writeFifo(auth_data);
            try self.setBits(.bit_framing, regs.BitFramingBits.START_SEND);
            try self.setBits(.t_mode, regs.TModeBits.T_AUTO);
            try self.writeReg(.command, @intFromEnum(Cmd.authent));

            _ = try self.waitCommand(regs.CommBits.IDLE_IRQ);

            try self.finishCommand();
        }

        // ========== Initialization Sequences ==========

        /// Initialize for Type A (ISO14443A) operation
        pub fn initTypeA(self: *Self) !void {
            try self.writeReg(.tx_mode, 0x00);
            try self.writeReg(.rx_mode, 0x00);
            try self.writeReg(.mod_width, regs.DefaultTypeA.MOD_WIDTH);
            try self.writeReg(.gsn, regs.DefaultTypeA.GSN);
            try self.writeReg(.cw_gsp, regs.DefaultTypeA.CW_GSP);
            try self.writeReg(.control, regs.ControlBits.INITIATOR);
            try self.writeReg(.rf_cfg, regs.DefaultTypeA.RX_GAIN);
            try self.writeReg(.rx_threshold, regs.DefaultTypeA.RX_THRESHOLD);
            try self.setBits(.tx_auto, regs.TxAutoBits.FORCE_100ASK);
        }

        /// Initialize for Type B (ISO14443B) operation
        pub fn initTypeB(self: *Self) !void {
            try self.clearBits(.status2, regs.Status2Bits.CRYPTO1_ON);
            try self.writeReg(.tx_mode, regs.DefaultTypeB.TX_MODE);
            try self.writeReg(.rx_mode, regs.DefaultTypeB.RX_MODE);
            try self.writeReg(.tx_auto, 0x00);
            try self.writeReg(.mod_width, regs.DefaultTypeB.MOD_WIDTH);
            try self.writeReg(.rx_threshold, regs.DefaultTypeB.RX_THRESHOLD);
            try self.writeReg(.gsn, regs.DefaultTypeB.GSN);
            try self.writeReg(.cw_gsp, regs.DefaultTypeB.CW_GSP);
            try self.writeReg(.mod_gsp, regs.DefaultTypeB.MOD_GSP);
            try self.writeReg(.control, regs.ControlBits.INITIATOR);
            try self.writeReg(.rf_cfg, regs.DefaultTypeB.RF_CFG);
        }

        // ========== High-Level Operations ==========

        /// Poll for cards (Type A and Type B)
        pub fn poll(self: *Self) !?nfc.CardInfo {
            // Try Type A first
            try self.initTypeA();
            var type_a_proto = TypeA{ .driver = self };
            if (type_a_proto.activate()) |card| {
                return nfc.CardInfo{ .type_a = card };
            } else |_| {}

            // Try Type B
            try self.initTypeB();
            var type_b_proto = TypeB{ .driver = self };
            if (type_b_proto.activate()) |card| {
                return nfc.CardInfo{ .type_b = card };
            } else |_| {}

            return null;
        }

        /// Activate Type A card
        pub fn activateTypeA(self: *Self) !?nfc.TypeACard {
            try self.initTypeA();
            var proto = TypeA{ .driver = self };
            return proto.activate() catch |err| {
                if (err == error.Timeout) return null;
                return err;
            };
        }

        /// Activate Type B card
        pub fn activateTypeB(self: *Self) !?nfc.TypeBCard {
            try self.initTypeB();
            var proto = TypeB{ .driver = self };
            return proto.activate() catch |err| {
                if (err == error.Timeout) return null;
                return err;
            };
        }
    };
}

// Re-export register definitions
pub const regs_module = regs;
