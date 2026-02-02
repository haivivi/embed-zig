//! FM175XX Register Definitions
//!
//! Complete register map for FM175XX NFC reader IC.
//! Compatible with MFRC522/MFRC523/PN512.

/// FM175XX Registers
pub const Reg = enum(u8) {
    // ========== Page 0: Command and Status ==========
    page0 = 0x00,
    command = 0x01, // Command and power control
    comm_ien = 0x02, // Interrupt enable
    div_ien = 0x03, // Interrupt enable (RF, CRC)
    comm_irq = 0x04, // Interrupt request flags
    div_irq = 0x05, // Interrupt request flags (RF, CRC)
    @"error" = 0x06, // Error flags
    status1 = 0x07, // Status register 1
    status2 = 0x08, // Status register 2 (Modem, Crypto)
    fifo_data = 0x09, // FIFO data register (64 bytes)
    fifo_level = 0x0A, // Number of bytes in FIFO
    water_level = 0x0B, // FIFO water level threshold
    control = 0x0C, // Control bits (timer, initiator)
    bit_framing = 0x0D, // Bit framing for TX/RX
    coll = 0x0E, // Collision detection position
    rfu_0f = 0x0F, // Extended register entrance

    // ========== Page 1: Communication ==========
    page1 = 0x10,
    mode = 0x11, // General mode settings
    tx_mode = 0x12, // TX framing and speed
    rx_mode = 0x13, // RX framing and speed
    tx_control = 0x14, // TX antenna driver control
    tx_auto = 0x15, // TX automatic RF control
    tx_sel = 0x16, // TX driver and modulation select
    rx_sel = 0x17, // RX analog settings
    rx_threshold = 0x18, // RX threshold levels
    demod = 0x19, // Demodulator settings
    felica_nfc = 0x1A, // FeliCa/NFC settings
    felica_nfc2 = 0x1B, // FeliCa/NFC settings 2
    mifare = 0x1C, // MIFARE specific settings
    manual_rcv = 0x1D, // Manual receiver control
    rfu_1e = 0x1E, // Reserved
    serial_speed = 0x1F, // Serial interface speed

    // ========== Page 2: Configuration ==========
    page2 = 0x20,
    crc_result_hi = 0x21, // CRC result MSB
    crc_result_lo = 0x22, // CRC result LSB
    gsn_load_mod = 0x23, // Load modulation conductance
    mod_width = 0x24, // Modulation width
    tx_bit_phase = 0x25, // TX bit phase
    rf_cfg = 0x26, // RF level detector and gain
    gsn = 0x27, // Conductance during modulation
    cw_gsp = 0x28, // P-MOS conductance
    mod_gsp = 0x29, // Modulation index P-MOS
    t_mode = 0x2A, // Timer mode and prescaler high
    t_prescaler = 0x2B, // Timer prescaler low
    t_reload_hi = 0x2C, // Timer reload high
    t_reload_lo = 0x2D, // Timer reload low
    t_counter_hi = 0x2E, // Timer counter high (read only)
    t_counter_lo = 0x2F, // Timer counter low (read only)

    // ========== Page 3: Test ==========
    page3 = 0x30,
    test_sel1 = 0x31, // Test signal select 1
    test_sel2 = 0x32, // Test signal select 2
    test_pin_en = 0x33, // Test pin enable
    test_pin_value = 0x34, // Test pin value
    test_bus = 0x35, // Test bus status
    auto_test = 0x36, // Self-test control
    version = 0x37, // Chip version
    analog_test = 0x38, // Analog test
    test_dac1 = 0x39, // Test DAC 1
    test_dac2 = 0x3A, // Test DAC 2
    test_adc = 0x3B, // Test ADC
    analogue_test1 = 0x3C, // Analog test 1
    analogue_test0 = 0x3D, // Analog test 0
    analogue_tpd_a = 0x3E, // Analog TPD A
    analogue_tpd_b = 0x3F, // Analog TPD B
};

/// FM175XX Commands
pub const Cmd = enum(u8) {
    idle = 0x00, // No action, cancels current command
    configure = 0x01, // Configure analog settings
    gen_rand_id = 0x02, // Generate random ID
    calc_crc = 0x03, // Calculate CRC
    transmit = 0x04, // Transmit data from FIFO
    no_cmd_change = 0x07, // No command change
    receive = 0x08, // Receive data to FIFO
    transceive = 0x0C, // Transmit and receive
    auto_coll = 0x0D, // Auto collision detection
    authent = 0x0E, // MIFARE authentication
    soft_reset = 0x0F, // Soft reset
};

// ========== Bit Definitions ==========

/// COMMAND Register (0x01) bits
pub const CmdBits = struct {
    pub const RCVOFF: u8 = 0x20; // Receiver off
    pub const POWERDOWN: u8 = 0x10; // Power down mode
    pub const CMD_MASK: u8 = 0x0F; // Command bits mask
};

/// COMMIEN/COMMIRQ Register (0x02/0x04) bits
pub const CommBits = struct {
    pub const IRQ_INV: u8 = 0x80; // Invert IRQ pin
    pub const TX_IRQ: u8 = 0x40; // Transmit interrupt
    pub const RX_IRQ: u8 = 0x20; // Receive interrupt
    pub const IDLE_IRQ: u8 = 0x10; // Idle interrupt
    pub const HI_ALERT_IRQ: u8 = 0x08; // High alert (FIFO almost full)
    pub const LO_ALERT_IRQ: u8 = 0x04; // Low alert (FIFO almost empty)
    pub const ERR_IRQ: u8 = 0x02; // Error interrupt
    pub const TIMER_IRQ: u8 = 0x01; // Timer interrupt
};

/// DIVIEN/DIVIRQ Register (0x03/0x05) bits
pub const DivBits = struct {
    pub const IRQ_PUSHPULL: u8 = 0x80; // IRQ pin push-pull mode
    pub const SIGIN_ACT_IRQ: u8 = 0x10; // SiginAct interrupt
    pub const MODE_IRQ: u8 = 0x08; // Mode interrupt
    pub const CRC_IRQ: u8 = 0x04; // CRC interrupt
    pub const RF_ON_IRQ: u8 = 0x02; // RF on interrupt
    pub const RF_OFF_IRQ: u8 = 0x01; // RF off interrupt
};

/// ERROR Register (0x06) bits
pub const ErrBits = struct {
    pub const WR_ERR: u8 = 0x40; // Write error / Temperature error
    pub const TEMP_ERR: u8 = 0x40; // Temperature error (alias)
    pub const RF_ERR: u8 = 0x20; // RF buffer overflow
    pub const BUFFER_OVFL: u8 = 0x10; // FIFO buffer overflow
    pub const COLL_ERR: u8 = 0x08; // Collision detected
    pub const CRC_ERR: u8 = 0x04; // CRC error
    pub const PARITY_ERR: u8 = 0x02; // Parity error
    pub const PROT_ERR: u8 = 0x01; // Protocol error
};

/// STATUS1 Register (0x07) bits
pub const Status1Bits = struct {
    pub const CRC_OK: u8 = 0x40; // CRC OK
    pub const CRC_READY: u8 = 0x20; // CRC ready
    pub const IRQ: u8 = 0x10; // IRQ is active
    pub const T_RUNNING: u8 = 0x08; // Timer is running
    pub const RF_ON: u8 = 0x04; // RF is on
    pub const HI_ALERT: u8 = 0x02; // High alert
    pub const LO_ALERT: u8 = 0x01; // Low alert
};

/// STATUS2 Register (0x08) bits
pub const Status2Bits = struct {
    pub const TEMP_SENS_OFF: u8 = 0x80; // Temperature sensor off
    pub const I2C_FORCE_HS: u8 = 0x40; // Force I2C high speed
    pub const MF_SELECTED: u8 = 0x10; // MIFARE selected
    pub const CRYPTO1_ON: u8 = 0x08; // Crypto1 is on
};

/// FIFOLEVEL Register (0x0A) bits
pub const FifoLevelBits = struct {
    pub const FLUSH_FIFO: u8 = 0x80; // Flush FIFO buffer
    pub const LEVEL_MASK: u8 = 0x7F; // FIFO level mask
};

/// CONTROL Register (0x0C) bits
pub const ControlBits = struct {
    pub const T_STOP_NOW: u8 = 0x80; // Stop timer
    pub const T_START_NOW: u8 = 0x40; // Start timer
    pub const WR_NFCID_TO_FIFO: u8 = 0x20; // Copy NFCID to FIFO
    pub const INITIATOR: u8 = 0x10; // Initiator mode
    pub const RX_LAST_BITS: u8 = 0x07; // RX last bits mask
};

/// BITFRAMING Register (0x0D) bits
pub const BitFramingBits = struct {
    pub const START_SEND: u8 = 0x80; // Start transmission
    pub const RX_ALIGN_MASK: u8 = 0x70; // RX align mask
    pub const TX_LAST_BITS: u8 = 0x07; // TX last bits mask
};

/// COLL Register (0x0E) bits
pub const CollBits = struct {
    pub const VALUES_AFTER_COLL: u8 = 0x80; // Keep data after collision
    pub const COLL_POS_NOT_VALID: u8 = 0x20; // Collision position not valid
    pub const COLL_POS_MASK: u8 = 0x1F; // Collision position mask
};

/// MODE Register (0x11) bits
pub const ModeBits = struct {
    pub const MSB_FIRST: u8 = 0x80; // CRC MSB first
    pub const DETECT_SYNC: u8 = 0x40; // Auto sync detection
    pub const TX_WAIT_RF: u8 = 0x20; // TX waits for RF
    pub const RX_WAIT_RF: u8 = 0x10; // RX waits for RF
    pub const POL_SIGIN: u8 = 0x08; // Invert SiginAct polarity
    pub const MODE_DET_OFF: u8 = 0x04; // Mode detector off
    pub const CRC_PRESET_MASK: u8 = 0x03; // CRC preset mask
};

/// TXMODE/RXMODE Register (0x12/0x13) bits
pub const TxRxModeBits = struct {
    pub const CRC_EN: u8 = 0x80; // Enable CRC
    pub const SPEED_MASK: u8 = 0x70; // Speed mask
    pub const INV_MOD: u8 = 0x08; // Inverse modulation (TX)
    pub const RX_NO_ERR: u8 = 0x08; // No error on <4 bits (RX)
    pub const TX_MIX: u8 = 0x04; // TX mix (TX)
    pub const RX_MULTIPLE: u8 = 0x04; // Multiple receive (RX)
    pub const FRAMING_MASK: u8 = 0x03; // Framing mask

    // Speed values
    pub const SPEED_106K: u8 = 0x00;
    pub const SPEED_212K: u8 = 0x10;
    pub const SPEED_424K: u8 = 0x20;
    pub const SPEED_848K: u8 = 0x30;
    pub const SPEED_1_6M: u8 = 0x40;
    pub const SPEED_3_2M: u8 = 0x50;

    // Framing values
    pub const FRAMING_MIFARE: u8 = 0x00;
    pub const FRAMING_NFC: u8 = 0x01;
    pub const FRAMING_FELICA: u8 = 0x02;
};

/// TXCONTROL Register (0x14) bits
pub const TxControlBits = struct {
    pub const INV_TX2_ON: u8 = 0x80; // Invert TX2 when on
    pub const INV_TX1_ON: u8 = 0x40; // Invert TX1 when on
    pub const INV_TX2_OFF: u8 = 0x20; // Invert TX2 when off
    pub const INV_TX1_OFF: u8 = 0x10; // Invert TX1 when off
    pub const TX2_CW: u8 = 0x08; // TX2 continuous wave
    pub const CHECK_RF: u8 = 0x04; // Check external RF
    pub const TX2_RF_EN: u8 = 0x02; // TX2 RF enable
    pub const TX1_RF_EN: u8 = 0x01; // TX1 RF enable
};

/// TXAUTO Register (0x15) bits
pub const TxAutoBits = struct {
    pub const AUTO_RF_OFF: u8 = 0x80; // Auto RF off after TX
    pub const FORCE_100ASK: u8 = 0x40; // Force 100% ASK
    pub const AUTO_WAKEUP: u8 = 0x20; // Auto wakeup
    pub const CA_ON: u8 = 0x08; // Collision avoidance
    pub const INITIAL_RF_ON: u8 = 0x04; // Initial RF on
    pub const TX2_RF_AUTO_EN: u8 = 0x02; // TX2 auto enable
    pub const TX1_RF_AUTO_EN: u8 = 0x01; // TX1 auto enable
};

/// TMODE Register (0x2A) bits
pub const TModeBits = struct {
    pub const T_AUTO: u8 = 0x80; // Auto timer mode
    pub const T_GATED_MASK: u8 = 0x60; // Gated timer mode mask
    pub const T_AUTO_RESTART: u8 = 0x10; // Auto restart timer
    pub const T_PRESCALER_HI: u8 = 0x0F; // Prescaler high bits mask
};

/// RFCFG Register (0x26) bits
pub const RfCfgBits = struct {
    pub const RF_LEVEL_AMP: u8 = 0x80; // RF level amplifier
    pub const RX_GAIN_MASK: u8 = 0x70; // RX gain mask
    pub const RF_LEVEL_MASK: u8 = 0x0F; // RF level mask
};

// ========== Extended Registers (via 0x0F) ==========

/// Extended register access bits
pub const ExtRegBits = struct {
    pub const WR_ADDR: u8 = 0x40; // Write address cycle
    pub const RD_ADDR: u8 = 0x80; // Read address cycle
    pub const WR_DATA: u8 = 0xC0; // Write data cycle
    pub const RD_DATA: u8 = 0x00; // Read data cycle
};

/// LPCD (Low Power Card Detection) registers
pub const LpcdReg = enum(u8) {
    ctrl1 = 0x01,
    ctrl2 = 0x02,
    ctrl3 = 0x03,
    ctrl4 = 0x04,
    bias_current = 0x05,
    adc_reference = 0x06,
    t1_cfg = 0x07,
    t2_cfg = 0x08,
    t3_cfg = 0x09,
    vmidbd_cfg = 0x0A,
    auto_wup_cfg = 0x0B,
    adc_result_lo = 0x0C,
    adc_result_hi = 0x0D,
    threshold_min_lo = 0x0E,
    threshold_min_hi = 0x0F,
    threshold_max_lo = 0x10,
    threshold_max_hi = 0x11,
    irq = 0x12,
};

/// LPCD CTRL1 Register bits
pub const LpcdCtrl1Bits = struct {
    pub const EN: u8 = 0x01; // Enable LPCD
    pub const RSTN: u8 = 0x02; // LPCD reset
    pub const CALIBRA_EN: u8 = 0x04; // Calibration mode
    pub const SENSE_1: u8 = 0x08; // Compare times 1 or 3
    pub const IE: u8 = 0x10; // Interrupt enable
    pub const BIT_CTRL_SET: u8 = 0x20; // Bit control set
    pub const BIT_CTRL_CLR: u8 = 0x00; // Bit control clear
};

/// LPCD IRQ Register bits
pub const LpcdIrqBits = struct {
    pub const CARD_IN: u8 = 0x01; // Card in IRQ
    pub const LPCD23: u8 = 0x02; // LPCD 23 end IRQ
    pub const CALIB: u8 = 0x04; // Calibration end IRQ
    pub const LP10K_TESTOK: u8 = 0x08; // LP OSC 10K OK IRQ
    pub const AUTO_WUP: u8 = 0x10; // Auto wakeup IRQ
};

// ========== Chip Identification ==========

/// Known chip version values
pub const ChipVersion = enum(u8) {
    fm17520 = 0x88,
    fm17522 = 0x90,
    pn512 = 0x91,
    mfrc522 = 0x92,
    _,
};

// ========== Default Configuration Values ==========

/// Default settings for Type A operation
pub const DefaultTypeA = struct {
    pub const MOD_WIDTH: u8 = 0x26; // 106kbps modulation width
    pub const GSN: u8 = 0xF8; // Conductance: CW=15, MOD=8
    pub const CW_GSP: u8 = 0x3F; // P-MOS conductance
    pub const RX_GAIN: u8 = 0x40; // RX gain = 4 (33dB)
    pub const RX_THRESHOLD: u8 = 0x84; // CollLevel=4, MinLevel=8
};

/// Default settings for Type B operation
pub const DefaultTypeB = struct {
    pub const TX_MODE: u8 = 0x83; // 106k, CRC, Type B framing
    pub const RX_MODE: u8 = 0x83; // 106k, CRC, Type B framing
    pub const MOD_WIDTH: u8 = 0x26;
    pub const RX_THRESHOLD: u8 = 0x55;
    pub const GSN: u8 = 0xF8;
    pub const CW_GSP: u8 = 0x3F;
    pub const MOD_GSP: u8 = 0x20;
    pub const RF_CFG: u8 = 0x48;
};
