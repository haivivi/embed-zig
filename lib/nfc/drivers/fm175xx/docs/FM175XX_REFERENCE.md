# FM175XX NFC Reader IC Reference

## Overview

FM175XX is a highly integrated 13.56MHz contactless reader IC manufactured by Shanghai Fudan Microelectronics.
It supports ISO/IEC 14443A/B protocols and is compatible with MFRC522/MFRC523/PN512.

## Features

- 13.56 MHz carrier frequency
- ISO/IEC 14443A/B compliant
- Mifare Classic, Mifare Ultralight, NTAG support
- FIFO buffer: 64 bytes
- Multiple host interfaces: SPI, I2C, UART
- Low Power Card Detection (LPCD)
- Programmable timer
- Hardware CRC calculation

## Communication Interface

Both I2C and SPI share the same register-based interface:

```
// Read register
readByte(addr: u8) -> u8
read(addr: u8, buf: []u8) -> void

// Write register  
writeByte(addr: u8, data: u8) -> void
write(addr: u8, data: []const u8) -> void
```

### I2C Mode

- Default address: 0x28 (7-bit) or 0x50 (8-bit with R/W bit)
- FIFO register address: 0x09

### SPI Mode

- Address format: `(addr << 1) | 0x80` for read, `(addr << 1) & 0x7E` for write
- MSB first, CPOL=0, CPHA=0

## Register Map

### Page 0 - Command and Status (0x00 - 0x0F)

| Addr | Name | Description |
|------|------|-------------|
| 0x00 | PAGE0 | Page select register |
| 0x01 | COMMAND | Command and power control |
| 0x02 | COMMIEN | Interrupt enable |
| 0x03 | DIVIEN | Interrupt enable (RF, CRC) |
| 0x04 | COMMIRQ | Interrupt request flags |
| 0x05 | DIVIRQ | Interrupt request flags (RF, CRC) |
| 0x06 | ERROR | Error flags |
| 0x07 | STATUS1 | Status register 1 |
| 0x08 | STATUS2 | Status register 2 (Modem, Crypto) |
| 0x09 | FIFODATA | FIFO data register (64 bytes) |
| 0x0A | FIFOLEVEL | Number of bytes in FIFO |
| 0x0B | WATERLEVEL | FIFO water level threshold |
| 0x0C | CONTROL | Control bits (timer, initiator) |
| 0x0D | BITFRAMING | Bit framing for TX/RX |
| 0x0E | COLL | Collision detection position |
| 0x0F | RFU / EXT_REG_ENTRANCE | Reserved / Extended register access |

### Page 1 - Communication (0x10 - 0x1F)

| Addr | Name | Description |
|------|------|-------------|
| 0x10 | PAGE1 | Page select register |
| 0x11 | MODE | General mode settings |
| 0x12 | TXMODE | TX framing and speed |
| 0x13 | RXMODE | RX framing and speed |
| 0x14 | TXCONTROL | TX antenna driver control |
| 0x15 | TXAUTO | TX automatic RF control |
| 0x16 | TXSEL | TX driver and modulation select |
| 0x17 | RXSEL | RX analog settings |
| 0x18 | RXTRESHOLD | RX threshold levels |
| 0x19 | DEMOD | Demodulator settings |
| 0x1A | FELICANFC | FeliCa/NFC settings |
| 0x1B | FELICANFC2 | FeliCa/NFC settings 2 |
| 0x1C | MIFARE | MIFARE specific settings |
| 0x1D | MANUALRCV | Manual receiver control |
| 0x1E | RFU | Reserved |
| 0x1F | SERIALSPEED | Serial interface speed |

### Page 2 - Configuration (0x20 - 0x2F)

| Addr | Name | Description |
|------|------|-------------|
| 0x20 | PAGE2 | Page select register |
| 0x21 | CRCRESULT1 | CRC result MSB |
| 0x22 | CRCRESULT2 | CRC result LSB |
| 0x23 | GSNLOADMOD | Load modulation conductance |
| 0x24 | MODWIDTH | Modulation width |
| 0x25 | TXBITPHASE | TX bit phase |
| 0x26 | RFCFG | RF level detector and gain |
| 0x27 | GSN | Conductance during modulation |
| 0x28 | CWGSP | P-MOS conductance |
| 0x29 | MODGSP | Modulation index P-MOS |
| 0x2A | TMODE | Timer mode and prescaler high |
| 0x2B | TPRESCALER | Timer prescaler low |
| 0x2C | TRELOADHI | Timer reload high |
| 0x2D | TRELOADLO | Timer reload low |
| 0x2E | TCOUNTERVALHI | Timer counter high (read only) |
| 0x2F | TCOUNTERVALLO | Timer counter low (read only) |

### Page 3 - Test (0x30 - 0x3F)

| Addr | Name | Description |
|------|------|-------------|
| 0x30 | PAGE3 | Page select register |
| 0x31 | TESTSEL1 | Test signal select 1 |
| 0x32 | TESTSEL2 | Test signal select 2 |
| 0x33 | TESTPINEN | Test pin enable |
| 0x34 | TESTPINVALUE | Test pin value |
| 0x35 | TESTBUS | Test bus status |
| 0x36 | AUTOTEST | Self-test control |
| 0x37 | VERSION | Chip version (0x88 for FM17520) |
| 0x38-0x3F | ANALOG_TEST | Analog test registers |

## Commands

| Code | Name | Description |
|------|------|-------------|
| 0x00 | IDLE | No action, cancels current command |
| 0x01 | CONFIGURE | Configure analog settings |
| 0x02 | GEN_RAND_ID | Generate random ID |
| 0x03 | CALC_CRC | Calculate CRC |
| 0x04 | TRANSMIT | Transmit data from FIFO |
| 0x07 | NO_CMD_CHANGE | No command change |
| 0x08 | RECEIVE | Receive data to FIFO |
| 0x0C | TRANSCEIVE | Transmit and receive |
| 0x0D | AUTOCOLL | Auto collision detection |
| 0x0E | AUTHENT | MIFARE authentication |
| 0x0F | SOFT_RESET | Soft reset (wait 1ms after) |

## Key Register Bit Definitions

### COMMAND Register (0x01)

| Bit | Name | Description |
|-----|------|-------------|
| 7:6 | - | Reserved |
| 5 | RCVOFF | Receiver off (1=off, 0=on) |
| 4 | POWERDOWN | Power down mode |
| 3:0 | COMMAND | Command code |

### ERROR Register (0x06)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | - | Reserved |
| 6 | WRERR/TEMPERR | Write error / Temperature error |
| 5 | RFERR | RF buffer overflow |
| 4 | BUFFEROVFL | FIFO buffer overflow |
| 3 | COLLERR | Collision detected |
| 2 | CRCERR | CRC error |
| 1 | PARITYERR | Parity error |
| 0 | PROTERR | Protocol error |

### COMMIRQ Register (0x04)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | SET | Set/Clear control |
| 6 | TXI | Transmit interrupt |
| 5 | RXI | Receive interrupt |
| 4 | IDLEI | Idle interrupt |
| 3 | HIALERTI | High alert (FIFO almost full) |
| 2 | LOALERTI | Low alert (FIFO almost empty) |
| 1 | ERRI | Error interrupt |
| 0 | TIMERI | Timer interrupt |

### TXCONTROL Register (0x14)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | INVTX2ON | Invert TX2 when on |
| 6 | INVTX1ON | Invert TX1 when on |
| 5 | INVTX2OFF | Invert TX2 when off |
| 4 | INVTX1OFF | Invert TX1 when off |
| 3 | TX2CW | TX2 continuous wave |
| 2 | CHECKRF | Check external RF |
| 1 | TX2RFEN | TX2 RF enable |
| 0 | TX1RFEN | TX1 RF enable |

### TXMODE / RXMODE Register (0x12 / 0x13)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | CRCEN | Enable CRC |
| 6:4 | SPEED | 000=106k, 001=212k, 010=424k, 011=848k |
| 3 | INVMOD/RXNOERR | Inverse mod / No error on <4 bits |
| 2 | TXMIX/RXMULTIPLE | TX mix / Multiple receive |
| 1:0 | FRAMING | 00=Mifare, 01=NFC, 10=FeliCa |

### BITFRAMING Register (0x0D)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | STARTSEND | Start transmission |
| 6:4 | RXALIGN | Bit position for first received bit |
| 3 | - | Reserved |
| 2:0 | TXLASTBITS | Number of bits in last byte to send |

### TMODE Register (0x2A)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | TAUTO | Auto timer mode |
| 6:5 | TGATED | Gated timer mode |
| 4 | TAUTORESTART | Auto restart timer |
| 3:0 | TPRESCALER_HI | Prescaler high 4 bits |

## Timer Configuration

Timer formula:
```
timeout_us = (prescaler * 2 + 1) * reload / 13.56
```

To calculate prescaler and reload for a given timeout:
```c
prescaler = 0;
while (prescaler < 0xFFF) {
    reload = ((timeout_us * 13560) - 1) / (prescaler * 2 + 1);
    if (reload < 0xFFFF) break;
    prescaler++;
}
```

## ISO14443A Protocol

### Type A Card Activation Sequence

1. **REQA/WUPA** (0x26/0x52) - Request/Wakeup, 7 bits
   - Response: ATQA (2 bytes)
   - ATQA[0] bits 7:6 indicate UID size: 00=single, 01=double, 10=triple

2. **ANTICOLLISION** (0x93/0x95/0x97 + 0x20) - Get UID
   - Response: UID (4 bytes) + BCC (1 byte)
   - BCC = UID[0] ^ UID[1] ^ UID[2] ^ UID[3]

3. **SELECT** (0x93/0x95/0x97 + 0x70 + UID + BCC) - Select card
   - Response: SAK (1 byte)
   - CRC enabled for this command

### Type A Card Structure

```c
struct TypeACard {
    uint8_t atqa[2];          // Answer To Request A
    uint8_t cascade_level;    // 1, 2, or 3
    uint8_t uid[12];          // Up to 10 bytes + 2 BCC
    uint8_t bcc[3];           // Block Check Character
    uint8_t sak[3];           // Select Acknowledge
};
```

### NTAG/Mifare Ultralight Commands

| Command | Code | Description |
|---------|------|-------------|
| READ | 0x30 + addr | Read 16 bytes from address |
| WRITE | 0xA2 + addr + 4 bytes | Write 4 bytes to address |
| COMPAT_WRITE | 0xA0 + addr | Compatibility write |
| READ_CNT | 0x39 + cnt_addr | Read counter |
| INCR_CNT | 0xA5 + cnt_addr + 4 bytes | Increment counter |
| PWD_AUTH | 0x1B + 4 bytes | Password authentication |
| READ_SIG | 0x3C + 0x00 | Read signature |
| GET_VERSION | 0x60 | Get version info |

## ISO14443B Protocol

### Type B Card Activation Sequence

1. **REQB/WUPB** (0x05 + AFI + PARAM)
   - Response: ATQB (12 bytes)
   - Contains PUPI (4 bytes), Application Data (4 bytes), Protocol Info (3 bytes)

2. **ATTRIB** (0x1D + PUPI + params)
   - Response: Answer to ATTRIB

### Type B Card Structure

```c
struct TypeBCard {
    uint8_t atqb[12];             // Answer To Request B
    uint8_t pupi[4];              // Pseudo-Unique PICC Identifier
    uint8_t application_data[4]; // Application specific
    uint8_t protocol_inf[3];     // Protocol information
    uint8_t attrib[10];          // ATTRIB response
    uint8_t len_attrib;          // ATTRIB response length
};
```

## LPCD (Low Power Card Detection)

FM175XX supports low power card detection through extended registers accessed via 0x0F:

### Extended Register Access

```c
// Write extended register
SetReg(0x0F, 0x40 | ext_addr);  // Write address cycle
SetReg(0x0F, 0xC0 | ext_data);  // Write data cycle

// Read extended register
SetReg(0x0F, 0x80 | ext_addr);  // Read address cycle
GetReg(0x0F, &ext_data);        // Read data cycle
```

### LPCD Registers

| Addr | Name | Description |
|------|------|-------------|
| 0x01 | LPCD_CTRL1 | LPCD control 1 |
| 0x02 | LPCD_CTRL2 | LPCD control 2 |
| 0x03 | LPCD_CTRL3 | LPCD control 3 |
| 0x04 | LPCD_CTRL4 | LPCD control 4 |
| 0x05 | LPCD_BIAS_CURRENT | Bias current |
| 0x06 | LPCD_ADC_REFERENCE | ADC reference |
| 0x07-0x09 | LPCD_TxCFG | Timer config |
| 0x0A | LPCD_VMIDBD_CFG | VMID config |
| 0x0B | LPCD_AUTO_WUP_CFG | Auto wakeup config |
| 0x0C-0x0D | LPCD_ADC_RESULT | ADC result |
| 0x0E-0x11 | LPCD_THRESHOLD | Threshold min/max |
| 0x12 | LPCD_IRQ | LPCD interrupt flags |

## Initialization Sequence

### Type A Reader Initialization

```c
SetReg(TXMODE, 0x00);                    // 106kbps, Mifare framing
SetReg(RXMODE, 0x00);                    // 106kbps, Mifare framing
SetReg(MODWIDTH, 0x26);                  // Modulation width for 106k
SetReg(GSN, 0xF8);                       // Conductance settings
SetReg(CWGSP, 0x3F);                     // P-MOS conductance
SetReg(CONTROL, 0x10);                   // Initiator mode
SetReg(RFCFG, 0x40);                     // RX gain = 4 (33dB)
SetReg(RXTRESHOLD, 0x84);                // Collision=4, MinLevel=8
ModifyReg(TXAUTO, 0x40, SET);            // Force 100% ASK
```

### Type B Reader Initialization

```c
ModifyReg(STATUS2, 0x08, RESET);         // Clear crypto flag
SetReg(TXMODE, 0x83);                    // 106k, CRC, Type B framing
SetReg(RXMODE, 0x83);                    // 106k, CRC, Type B framing
SetReg(TXAUTO, 0x00);                    // No auto RF
SetReg(MODWIDTH, 0x26);                  // Modulation width
SetReg(RXTRESHOLD, 0x55);                // Thresholds for Type B
SetReg(GSN, 0xF8);
SetReg(CWGSP, 0x3F);
SetReg(MODGSP, 0x20);
SetReg(CONTROL, 0x10);                   // Initiator mode
SetReg(RFCFG, 0x48);                     // RX gain
```

## RF Field Control

```c
// mode: 0=off, 1=TX1 only, 2=TX2 only, 3=both
void SetRf(uint8_t mode) {
    switch (mode) {
        case 0: ModifyReg(TXCONTROL, 0x03, RESET); break;
        case 1: SetReg(TXCONTROL, 0x01); break;
        case 2: SetReg(TXCONTROL, 0x02); break;
        case 3: ModifyReg(TXCONTROL, 0x03, SET); break;
    }
    delay_ms(10);  // Wait for RF field to stabilize
}
```

## Error Codes

| Code | Name | Description |
|------|------|-------------|
| 0x00 | SUCCESS | Operation successful |
| 0xF1 | RESET_ERR | Reset failed |
| 0xF2 | PARAM_ERR | Invalid parameter |
| 0xF3 | TIMER_ERR | Timeout |
| 0xF4 | COMM_ERR | Communication error |
| 0xF5 | COLL_ERR | Collision detected |
| 0xF6 | FIFO_ERR | FIFO overflow |
| 0xF7 | CRC_ERR | CRC mismatch |
| 0xF8 | PARITY_ERR | Parity error |
| 0xF9 | PROTOCOL_ERR | Protocol error |
| 0xE1 | AUTH_ERR | Authentication failed |

## Recommended Settings

### TX Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| MODWIDTH | 0x26 | 106kbps modulation |
| MODWIDTH | 0x13 | 212kbps modulation |
| MODWIDTH | 0x09 | 424kbps modulation |
| MODWIDTH | 0x04 | 848kbps modulation |

### RX Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| RXGAIN | 4 (0x40) | 33dB gain (default) |
| GSNON | 15 | CW conductance |
| MODGSNON | 8 | Modulation conductance |
| GSP | 31 | P-MOS conductance |
| MODGSP | 31 | Modulation P-MOS |
| COLLLEVEL | 4 | Collision threshold |
| MINLEVEL | 8 | Minimum signal level |
| RXWAIT | 4 | RX wait time |

## Chip Identification

Read VERSION register (0x37):
- 0x88: FM17520
- 0x90: FM17522
- 0x91: PN512
- 0x92: MFRC522
