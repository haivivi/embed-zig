# Mic Test Example

Microphone test for Korvo-2 V3 board with ES7210 4-channel ADC.

## Hardware

- **Board**: ESP32-S3-Korvo-2 V3
- **ADC**: ES7210 (4-channel audio ADC via I2S TDM)
- **Sample Rate**: 16kHz
- **Channels**: Mono (voice channel extracted from TDM)

## Build and Flash

```bash
cd examples/esp/mic_test/zig
source ~/esp/esp-adf/esp-idf/export.sh
idf.py -DZIG_BOARD=korvo2_v3 build
idf.py -p <your-serial-port> flash monitor
```

**Serial port examples:**
- macOS: `/dev/cu.usbserial-*` or `/dev/cu.usbmodem*`
- Linux: `/dev/ttyUSB0` or `/dev/ttyACM0`
- Windows: `COM3`, `COM4`, etc.

The device will read from the microphone and log audio levels to console.

## Server (Optional - for Audio Streaming)

A TCP server is provided to receive and play audio from the device.

### Build the Server

```bash
cd examples/esp/mic_test/server
zig build
```

PortAudio is built from source automatically - no system dependencies required.

### Run the Server

```bash
./zig-out/bin/mic_server

# Options:
#   -p, --port <port>   TCP port (default: 9000)
#   -r, --rate <hz>     Sample rate (default: 16000)
#   --tone              Generate test tone (speaker test)
#   -h, --help          Show help
```

### Protocol

The streaming protocol is simple:

```
[4 bytes: packet length (little endian)]
[N bytes: i16 samples (little endian)]
```

Each packet contains 20ms of audio (320 samples at 16kHz = 640 bytes).

## Troubleshooting

### Build errors
- Ensure ESP-IDF v5.4 is sourced
- Check all paths are correct

### No audio from microphone
- Check I2C connection to ES7210
- Verify I2S TDM configuration
