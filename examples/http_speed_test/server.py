#!/usr/bin/env python3
"""
Simple HTTP server for download speed testing.

Usage:
    python3 server.py [port]
    
Default port: 8080

Endpoints:
    GET /test/<size>    - Download <size> bytes of random data
                          e.g., /test/1048576 for 1MB
    GET /test/1k        - Download 1KB
    GET /test/10k       - Download 10KB  
    GET /test/100k      - Download 100KB
    GET /test/1m        - Download 1MB
    GET /test/10m       - Download 10MB
    GET /info           - Server info
"""

import http.server
import socketserver
import sys
import os
import time
import socket

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

# Pre-generate test data (zeros for speed, random is slow)
TEST_DATA_1K = b'\x00' * 1024
TEST_DATA_10K = b'\x00' * (10 * 1024)
TEST_DATA_100K = b'\x00' * (100 * 1024)
TEST_DATA_1M = b'\x00' * (1024 * 1024)
TEST_DATA_10M = b'\x00' * (10 * 1024 * 1024)

SIZE_MAP = {
    '1k': TEST_DATA_1K,
    '10k': TEST_DATA_10K,
    '100k': TEST_DATA_100K,
    '1m': TEST_DATA_1M,
    '10m': TEST_DATA_10M,
}


class SpeedTestHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{time.strftime('%H:%M:%S')}] {args[0]}")
    
    def do_GET(self):
        if self.path == '/info':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            info = f'{{"server": "ESP32 HTTP Speed Test Server", "endpoints": ["/test/1k", "/test/10k", "/test/100k", "/test/1m", "/test/10m", "/test/<bytes>"]}}'
            self.wfile.write(info.encode())
            return
        
        if self.path.startswith('/test/'):
            size_str = self.path[6:]  # Remove '/test/'
            
            # Check predefined sizes
            if size_str.lower() in SIZE_MAP:
                data = SIZE_MAP[size_str.lower()]
            else:
                # Try to parse as number
                try:
                    size = int(size_str)
                    if size > 100 * 1024 * 1024:  # Max 100MB
                        self.send_error(400, "Size too large (max 100MB)")
                        return
                    data = b'\x00' * size
                except ValueError:
                    self.send_error(400, f"Invalid size: {size_str}")
                    return
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            
            # Send in chunks for large data
            chunk_size = 64 * 1024  # 64KB chunks
            offset = 0
            while offset < len(data):
                chunk = data[offset:offset + chunk_size]
                self.wfile.write(chunk)
                offset += chunk_size
            return
        
        # Default: return 404
        self.send_error(404, "Not Found. Try /test/1m or /info")


def get_local_ip():
    """Get the local IP address."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"


def main():
    local_ip = get_local_ip()
    
    print("=" * 60)
    print("  ESP32 HTTP Speed Test Server")
    print("=" * 60)
    print()
    print(f"  Local IP:  {local_ip}")
    print(f"  Port:      {PORT}")
    print()
    print("  Endpoints:")
    print(f"    http://{local_ip}:{PORT}/test/1k    - 1 KB")
    print(f"    http://{local_ip}:{PORT}/test/10k   - 10 KB")
    print(f"    http://{local_ip}:{PORT}/test/100k  - 100 KB")
    print(f"    http://{local_ip}:{PORT}/test/1m    - 1 MB")
    print(f"    http://{local_ip}:{PORT}/test/10m   - 10 MB")
    print(f"    http://{local_ip}:{PORT}/info       - Server info")
    print()
    print("  Press Ctrl+C to stop")
    print("=" * 60)
    print()
    
    # Allow address reuse and use threading for concurrent connections
    class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
    
    with ThreadedTCPServer(("", PORT), SpeedTestHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer stopped.")


if __name__ == "__main__":
    main()
