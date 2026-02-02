//! NFC Protocol Constants
//!
//! ISO14443A/B command codes and protocol constants.
//! Shared by all NFC reader drivers.

/// ISO14443A (Type A) Protocol Commands
pub const TypeA = struct {
    // Request commands (7 bits)
    pub const CMD_REQA: u8 = 0x26; // Request Type A
    pub const CMD_WUPA: u8 = 0x52; // Wake-Up Type A

    // Anti-collision/Select commands (cascade levels)
    pub const CMD_ANTICOLL_CL1: u8 = 0x93; // Cascade Level 1
    pub const CMD_ANTICOLL_CL2: u8 = 0x95; // Cascade Level 2
    pub const CMD_ANTICOLL_CL3: u8 = 0x97; // Cascade Level 3

    pub const CMD_ANTICOLL = [_]u8{ CMD_ANTICOLL_CL1, CMD_ANTICOLL_CL2, CMD_ANTICOLL_CL3 };
    pub const CMD_SELECT = [_]u8{ CMD_ANTICOLL_CL1, CMD_ANTICOLL_CL2, CMD_ANTICOLL_CL3 };

    // Anti-collision NVB (Number of Valid Bits)
    pub const NVB_ANTICOLL: u8 = 0x20; // 2 bytes sent
    pub const NVB_SELECT: u8 = 0x70; // 7 bytes sent (full UID + BCC)

    // Halt command
    pub const CMD_HALT: u8 = 0x50;

    // RATS (Request for Answer To Select) for ISO14443-4
    pub const CMD_RATS: u8 = 0xE0;

    // PPS (Protocol and Parameter Selection)
    pub const CMD_PPS: u8 = 0xD0;

    // Cascade tag (indicates more UID bytes follow)
    pub const CASCADE_TAG: u8 = 0x88;

    /// Get anticollision command for cascade level (0, 1, 2)
    pub fn getAnticollCmd(level: u2) u8 {
        return CMD_ANTICOLL[level];
    }
};

/// ISO14443B (Type B) Protocol Commands
pub const TypeB = struct {
    // REQB/WUPB (Request/Wakeup Type B)
    pub const CMD_REQB: u8 = 0x05; // APf byte for REQB
    pub const CMD_ATTRIB: u8 = 0x1D; // ATTRIB command

    // REQB parameters
    pub const PARAM_REQB: u8 = 0x00; // REQB (not WUPB)
    pub const PARAM_WUPB: u8 = 0x08; // WUPB

    // AFI (Application Family Identifier)
    pub const AFI_ALL: u8 = 0x00; // All families

    // HLTB (Halt Type B)
    pub const CMD_HLTB: u8 = 0x50;
};

/// NTAG/Mifare Ultralight Commands
pub const Ntag = struct {
    pub const CMD_READ: u8 = 0x30; // Read 16 bytes (4 pages)
    pub const CMD_FAST_READ: u8 = 0x3A; // Fast read
    pub const CMD_WRITE: u8 = 0xA2; // Write 4 bytes (1 page)
    pub const CMD_COMP_WRITE: u8 = 0xA0; // Compatibility write
    pub const CMD_READ_CNT: u8 = 0x39; // Read counter
    pub const CMD_INCR_CNT: u8 = 0xA5; // Increment counter
    pub const CMD_PWD_AUTH: u8 = 0x1B; // Password authentication
    pub const CMD_READ_SIG: u8 = 0x3C; // Read signature
    pub const CMD_GET_VERSION: u8 = 0x60; // Get version info

    // ACK/NAK responses
    pub const ACK: u8 = 0x0A; // 4 bits
    pub const NAK_INVALID_ARG: u8 = 0x00;
    pub const NAK_CRC_ERROR: u8 = 0x01;
    pub const NAK_AUTH_CNT: u8 = 0x04;
    pub const NAK_EEPROM_ERROR: u8 = 0x05;

    // Page sizes
    pub const PAGE_SIZE: u8 = 4;
    pub const READ_SIZE: u8 = 16; // 4 pages per read
};

/// Mifare Classic Commands
pub const MifareClassic = struct {
    pub const CMD_AUTH_KEY_A: u8 = 0x60;
    pub const CMD_AUTH_KEY_B: u8 = 0x61;
    pub const CMD_READ: u8 = 0x30;
    pub const CMD_WRITE: u8 = 0xA0;
    pub const CMD_DECREMENT: u8 = 0xC0;
    pub const CMD_INCREMENT: u8 = 0xC1;
    pub const CMD_RESTORE: u8 = 0xC2;
    pub const CMD_TRANSFER: u8 = 0xB0;

    // Block sizes
    pub const BLOCK_SIZE: u8 = 16;

    // Default keys
    pub const KEY_DEFAULT_A = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    pub const KEY_DEFAULT_B = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    pub const KEY_MAD = [_]u8{ 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 };
    pub const KEY_NDEF = [_]u8{ 0xD3, 0xF7, 0xD3, 0xF7, 0xD3, 0xF7 };
};

/// ISO14443-4 Protocol (T=CL)
pub const Iso14443_4 = struct {
    // PCB (Protocol Control Byte) types
    pub const PCB_I_BLOCK: u8 = 0x02; // Information block
    pub const PCB_R_BLOCK: u8 = 0xA2; // Receive-ready block
    pub const PCB_S_BLOCK: u8 = 0xC2; // Supervisory block

    // S-block types
    pub const S_DESELECT: u8 = 0xC2;
    pub const S_WTX: u8 = 0xF2; // Waiting time extension

    // Frame structure
    pub const MAX_INF_LEN: u16 = 256; // Maximum information field length
};

/// FeliCa Commands (NFC-F, Type 3)
pub const FeliCa = struct {
    pub const CMD_POLLING: u8 = 0x00;
    pub const CMD_READ_WO_ENC: u8 = 0x06; // Read Without Encryption
    pub const CMD_WRITE_WO_ENC: u8 = 0x08; // Write Without Encryption
    pub const CMD_REQUEST_SERVICE: u8 = 0x02;
    pub const CMD_REQUEST_RESPONSE: u8 = 0x04;

    // System codes
    pub const SC_NDEF: u16 = 0x12FC; // NDEF system code
    pub const SC_WILDCARD: u16 = 0xFFFF; // Any system
};

/// NFC Error codes
pub const NfcError = error{
    Timeout,
    CollisionDetected,
    CrcError,
    ParityError,
    ProtocolError,
    BufferOverflow,
    AuthError,
    InvalidResponse,
    NoCard,
    CardLost,
    Unsupported,
};
