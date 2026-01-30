#!/usr/bin/env python3
"""
TCP Audio Server - Receives raw PCM audio from ESP32 and saves to WAV file.

Usage:
    python3 tcp_audio_server.py [port] [output_file]
    
Default: port=8888, output=received_audio.wav
"""

import socket
import struct
import wave
import sys
import time
from datetime import datetime

# Configuration
HOST = '0.0.0.0'
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
OUTPUT_FILE = sys.argv[2] if len(sys.argv) > 2 else 'received_audio.wav'

# Audio format
SAMPLE_RATE = 16000
CHANNELS = 1
SAMPLE_WIDTH = 2  # 16-bit

def main():
    print(f"=== TCP Audio Server ===")
    print(f"Listening on port {PORT}")
    print(f"Output file: {OUTPUT_FILE}")
    print(f"Audio: {SAMPLE_RATE}Hz, {CHANNELS}ch, 16-bit")
    print(f"========================")
    print()
    
    # Create socket
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(1)
    
    print(f"Waiting for connection...")
    
    while True:
        try:
            conn, addr = server.accept()
            print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Connected: {addr}")
            
            # Receive audio data
            audio_data = bytearray()
            total_bytes = 0
            start_time = time.time()
            last_print = start_time
            
            while True:
                try:
                    data = conn.recv(4096)
                    if not data:
                        break
                    audio_data.extend(data)
                    total_bytes += len(data)
                    
                    # Print progress every second
                    now = time.time()
                    if now - last_print >= 1.0:
                        duration = total_bytes / (SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS)
                        print(f"  Received: {total_bytes} bytes ({duration:.1f}s audio)")
                        last_print = now
                        
                except socket.timeout:
                    continue
                except Exception as e:
                    print(f"  Error: {e}")
                    break
            
            conn.close()
            
            # Save to WAV file
            if len(audio_data) > 0:
                duration = len(audio_data) / (SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS)
                print(f"\nConnection closed. Total: {len(audio_data)} bytes ({duration:.1f}s)")
                
                timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                filename = f"audio_{timestamp}.wav"
                
                with wave.open(filename, 'wb') as wav:
                    wav.setnchannels(CHANNELS)
                    wav.setsampwidth(SAMPLE_WIDTH)
                    wav.setframerate(SAMPLE_RATE)
                    wav.writeframes(bytes(audio_data))
                
                print(f"Saved to: {filename}")
                
                # Also save raw PCM
                raw_filename = f"audio_{timestamp}.raw"
                with open(raw_filename, 'wb') as f:
                    f.write(bytes(audio_data))
                print(f"Raw PCM: {raw_filename}")
            else:
                print("\nNo audio data received.")
            
            print("\nWaiting for next connection...")
            
        except KeyboardInterrupt:
            print("\n\nServer stopped.")
            break
        except Exception as e:
            print(f"Error: {e}")
            continue
    
    server.close()

if __name__ == '__main__':
    main()
