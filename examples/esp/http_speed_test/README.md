# HTTP Speed Test

Tests HTTP download speed over WiFi.

## Versions

- **c/** - C implementation using `esp_http_client`
- **zig/** - Zig std implementation using LWIP sockets
- **server/** - Go HTTP server for local testing

## Server

```bash
# Build and run server
cd server
go run main.go
# Or with bazel
bazel run //examples/esp/http_speed_test/server
```

Server endpoints:
- `GET /test/10m` - Download 10MB
- `GET /test/50m` - Download 50MB
- `GET /test/<bytes>` - Download specified bytes

## Build & Flash

### C Version

```bash
cd c
idf.py set-target esp32s3
idf.py menuconfig  # Set WiFi and server IP
idf.py build flash monitor
```

### Zig Version

```bash
cd zig
idf.py set-target esp32s3
idf.py menuconfig  # Set WiFi and server IP
idf.py build flash monitor
```

## Configuration

Edit `sdkconfig.defaults` or use `idf.py menuconfig`:
- `CONFIG_WIFI_SSID` - WiFi network name
- `CONFIG_WIFI_PASSWORD` - WiFi password
- `CONFIG_TEST_SERVER_IP` - Test server IP address
- `CONFIG_TEST_SERVER_PORT` - Test server port (default: 8080)
