//! WebSim Simulated SPI LCD
//!
//! Virtual ST7789-compatible LCD controller that receives SPI commands
//! and writes pixels to the SharedState framebuffer.
//!
//! Data flow:
//!   SpiLcd.flush() → writeCmd(CASET/RASET/RAMWR) + writeData(pixels)
//!     → SimDcPin.setLow/setHigh (toggle command/data mode)
//!     → SimSpi.write() (interprets LCD commands, writes framebuffer)
//!
//! This satisfies the trait/spi interface so SpiLcd(SimSpi, SimDcPin, ...)
//! works transparently, just like a real SPI bus would on ESP32.

const state_mod = @import("state.zig");

/// Simulated DC (Data/Command) pin.
///
/// In real hardware, this is a GPIO pin that toggles between
/// command mode (low) and data mode (high) for the LCD controller.
pub const SimDcPin = struct {
    is_data: bool = true,

    pub fn setHigh(self: *SimDcPin) void {
        self.is_data = true;
    }

    pub fn setLow(self: *SimDcPin) void {
        self.is_data = false;
    }
};

/// ST7789 command codes (subset used for display flush)
const CMD = struct {
    const CASET = 0x2A; // Column Address Set
    const RASET = 0x2B; // Row Address Set
    const RAMWR = 0x2C; // Memory Write
};

/// SPI error type (matches trait/spi)
const SpiError = error{
    TransferFailed,
    Busy,
    Timeout,
    SpiError,
};

/// Simulated SPI bus with virtual ST7789 LCD controller.
///
/// Receives SPI bytes and interprets them as LCD commands:
/// - When DC is low: byte is a command (CASET, RASET, RAMWR)
/// - When DC is high: bytes are data (column/row addresses or pixels)
///
/// Pixel data written during RAMWR state goes directly into
/// SharedState.display_fb, which JS reads to render on canvas.
pub const SimSpi = struct {
    const Self = @This();

    dc: *SimDcPin,

    /// Current command state machine
    state: State = .idle,

    /// Current write window (set by CASET + RASET)
    x1: u16 = 0,
    y1: u16 = 0,
    x2: u16 = 0,
    y2: u16 = 0,

    /// Byte accumulator for multi-byte command data (CASET/RASET send 4 bytes)
    param_buf: [4]u8 = undefined,
    param_idx: u8 = 0,

    /// Pixel write cursor (tracks position during RAMWR)
    px_x: u16 = 0,
    px_y: u16 = 0,

    const State = enum {
        idle,
        /// Collecting 4 bytes of column address data
        caset_data,
        /// Collecting 4 bytes of row address data
        raset_data,
        /// Receiving pixel data, writing to framebuffer
        ramwr_data,
    };

    pub fn init(dc: *SimDcPin) Self {
        return .{ .dc = dc };
    }

    /// SPI write — satisfies trait/spi interface.
    ///
    /// Interprets bytes based on DC pin state and internal state machine.
    pub fn write(self: *Self, data: []const u8) SpiError!void {
        if (!self.dc.is_data) {
            // DC low → command byte
            self.handleCommand(data);
        } else {
            // DC high → data bytes
            self.handleData(data);
        }
    }

    fn handleCommand(self: *Self, data: []const u8) void {
        if (data.len == 0) return;
        switch (data[0]) {
            CMD.CASET => {
                self.state = .caset_data;
                self.param_idx = 0;
            },
            CMD.RASET => {
                self.state = .raset_data;
                self.param_idx = 0;
            },
            CMD.RAMWR => {
                self.state = .ramwr_data;
                self.px_x = self.x1;
                self.px_y = self.y1;
            },
            else => {
                // Unknown command — ignore
                self.state = .idle;
            },
        }
    }

    fn handleData(self: *Self, data: []const u8) void {
        switch (self.state) {
            .caset_data => self.collectParams(data, .caset),
            .raset_data => self.collectParams(data, .raset),
            .ramwr_data => self.writePixels(data),
            .idle => {},
        }
    }

    const ParamTarget = enum { caset, raset };

    fn collectParams(self: *Self, data: []const u8, target: ParamTarget) void {
        for (data) |byte| {
            if (self.param_idx < 4) {
                self.param_buf[self.param_idx] = byte;
                self.param_idx += 1;
            }
            if (self.param_idx == 4) {
                // Parse big-endian 16-bit values
                const v1 = @as(u16, self.param_buf[0]) << 8 | self.param_buf[1];
                const v2 = @as(u16, self.param_buf[2]) << 8 | self.param_buf[3];
                switch (target) {
                    .caset => {
                        self.x1 = v1;
                        self.x2 = v2;
                    },
                    .raset => {
                        self.y1 = v1;
                        self.y2 = v2;
                    },
                }
                self.state = .idle;
                break;
            }
        }
    }

    fn writePixels(self: *Self, data: []const u8) void {
        const shared = &state_mod.state;
        const W = state_mod.DISPLAY_WIDTH;
        const BPP = state_mod.DISPLAY_BPP;
        const FB_SIZE = state_mod.DISPLAY_FB_SIZE;

        var i: usize = 0;
        while (i + BPP <= data.len) : (i += BPP) {
            if (self.px_y <= self.y2 and self.px_x <= self.x2) {
                const fb_offset = (@as(u32, self.px_y) * W + @as(u32, self.px_x)) * BPP;
                if (fb_offset + BPP <= FB_SIZE) {
                    @memcpy(shared.display_fb[fb_offset..][0..BPP], data[i..][0..BPP]);
                }

                // Advance cursor: left→right, then next row
                self.px_x += 1;
                if (self.px_x > self.x2) {
                    self.px_x = self.x1;
                    self.px_y += 1;
                }
            }
        }

        shared.display_dirty = true;
    }
};
