# ADC Button Example

Demonstrates the HAL Board framework with ADC-based button input, event system, and debouncing.

## Features

- HAL Board abstraction with unified event system
- ADC button reading with voltage range mapping
- Debouncing and long-press detection
- Click and double-click events
- Thread-safe event queue (MPSC)

## Supported Boards

| Board | ADC Channel | Buttons | Config |
|-------|-------------|---------|--------|
| ESP32-S3-Korvo-2 V3 | ADC1_CH4 (GPIO5) | 6 | `idf.boards.korvo2_v3` |

## Button Mapping (Korvo-2 V3)

| Button | Raw ADC | Voltage Range |
|--------|---------|---------------|
| VOL+ | ~410 | 250-600 |
| VOL- | ~922 | 750-1100 |
| SET | ~1275 | 1110-1500 |
| PLAY | ~1928 | 1510-2100 |
| MUTE | ~2312 | 2110-2550 |
| REC | ~2852 | 2650-3100 |

## Build & Flash

```bash
cd ~/esp/esp-adf && source ./export.sh
cd examples/esp/adc_button/zig

idf.py build && idf.py -p /dev/cu.usbserial-120 flash
```

## Memory Usage

### ESP32-S3-Korvo-2 V3

**Binary Size:** ~230 KB, 78% flash free

| Stage | Internal RAM | Stack |
|-------|--------------|-------|
| Boot | 372KB/425KB (88%) | ~2500/8192 |
| After HAL Init | 371KB/425KB | ~2800/8192 |
| Running | 371KB/425KB | ~2800/8192 |

**Key Metrics:**
- Internal RAM: 88% free
- Stack usage: ~34% (2800 / 8192 bytes)
- Event queue: 32 events capacity
- HAL Board overhead: ~300 bytes

## Event Types

```zig
pub const Event = union(enum) {
    button: ButtonEvent,
    timer: TimerEvent,
    system: SystemEvent,
};

pub const ButtonEvent = struct {
    id: ButtonId,
    action: Action,  // press, release, click, long_press, double_click
    timestamp: u64,
};
```

## Architecture

```
┌─────────────────────────────────────────┐
│ main.zig (Application)                  │
│   - Handle events                       │
│   - Application logic                   │
├─────────────────────────────────────────┤
│ korvo2_v3.zig (Board Implementation)    │
│   - hal.Board(Config)                   │
│   - Hardware-specific setup             │
├─────────────────────────────────────────┤
│ board.zig (Application Config)          │
│   - ButtonId enum                       │
│   - Event queue size                    │
│   - Long press threshold                │
├─────────────────────────────────────────┤
│ lib/esp/boards/korvo2_v3.zig           │
│   - ADC channel, voltage ranges         │
│   - GPIO definitions                    │
└─────────────────────────────────────────┘
```

## Test Results

All 6 buttons verified working:
```
Button: VOL+ (press)
Button: VOL+ (release)
Button: VOL+ (click)
Button: VOL- (click)
Button: SET (click)
Button: PLAY (click)
Button: MUTE (click)
Button: REC (click)
Button: REC (long_press)
```
