# HTTPS Speed Test

Tests HTTPS download speed over WiFi with self-signed certificates.

## Versions

- **c/** - C implementation using `esp_http_client` with embedded CA
- **zig/** - Zig std implementation using LWIP sockets + mbedTLS
- **server/** - Go HTTPS server with TLS 1.2 for ESP32 compatibility

## Server

```bash
# Build and run server
cd server
go run main.go
# Or with bazel
bazel run //examples/esp/https_speed_test/server
```

Server listens on port 8443 with self-signed certificate.

## Certificates

Certificates are in `server/certs/`:
- `ca.crt` - Root CA certificate (embedded in firmware)
- `server.crt` - Server certificate
- `server.key` - Server private key

To regenerate certificates:
```bash
cd server/certs
# Generate CA
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout ca.key -out ca.crt -subj "/CN=ESP32 Test CA"
# Generate server key and CSR
openssl req -nodes -newkey rsa:2048 \
    -keyout server.key -out server.csr -subj "/CN=ESP32 Test Server"
# Sign server cert with CA (add SAN for IP)
cat > server.ext << EOF
subjectAltName=IP:192.168.4.221
EOF
openssl x509 -req -days 365 -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out server.crt -extfile server.ext
```

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
- `CONFIG_TEST_SERVER_IP` - Test server IP address (must match cert SAN)
