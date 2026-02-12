#!/usr/bin/env python3
"""
Automated BK7258 Mic Test
1. Open serial port
2. Wait for board to boot + start recording
3. While recording: play TTS audio from PC speaker (board mic picks it up)
4. Capture hex PCM data from serial
5. Decode to WAV file
6. Print stats
"""

import serial
import struct
import wave
import sys
import time
import os
import subprocess

PORT = "/dev/cu.usbserial-130"
BAUD = 115200
SAMPLE_RATE = 8000
OUTPUT_WAV = "/Users/idy/Vibing/embed-zig/docs/mic_capture.wav"
TTS_TEXT = "你好，这是麦克风测试。一二三四五六七八九十。"

def play_tts(text):
    """Play TTS audio from PC speaker using macOS say command"""
    print(f"[PC] Playing TTS: {text}")
    subprocess.Popen(["say", "-v", "Ting-Ting", text])

def main():
    print(f"[PC] Opening {PORT}...")
    ser = serial.Serial(PORT, BAUD, timeout=1)
    ser.reset_input_buffer()

    print("[PC] Waiting for board to start (look for WAIT_FOR_PC)...")
    print("[PC] If board already running, press RESET button on board")

    samples = []
    stats_line = None
    tts_played = False

    # Phase 1: Wait for DATA_START, accumulate lines
    raw_buf = b""
    phase = "wait"  # wait -> capture -> done
    start = time.time()

    while time.time() - start < 180:  # 3 min timeout
        data = ser.read(ser.in_waiting or 1)
        if not data:
            continue
        raw_buf += data

        # Process complete lines from buffer
        while b'\n' in raw_buf:
            line_bytes, raw_buf = raw_buf.split(b'\n', 1)
            line = line_bytes.decode('utf-8', errors='replace').strip()
            if not line:
                continue

            if phase == "wait":
                print(f"[BK] {line}")

                if "Waiting 2s" in line and not tts_played:
                    time.sleep(0.5)
                    play_tts(TTS_TEXT)
                    tts_played = True

                if "Stats:" in line:
                    stats_line = line

                if "DATA_START" in line:
                    print("[PC] Capturing PCM hex data...")
                    phase = "capture"

            elif phase == "capture":
                if "DATA_END" in line:
                    print(f"[PC] Capture done: {len(samples)} samples")
                    phase = "done"
                    break

                # Extract hex data: look for "D:" after log prefix
                # Format: "ap0:app:I(12345):D:AABBCCDDEE..."
                d_idx = line.find("D:")
                if d_idx >= 0:
                    hex_str = line[d_idx + 2:]
                    # Only parse if it looks like valid hex (all hex chars)
                    hex_str = hex_str.strip()
                    if len(hex_str) >= 4 and all(c in '0123456789ABCDEFabcdef' for c in hex_str):
                        for i in range(0, len(hex_str) - 3, 4):
                            chunk = hex_str[i:i+4]
                            if len(chunk) == 4:
                                u16 = int(chunk, 16)
                                if u16 >= 0x8000:
                                    i16val = u16 - 0x10000
                                else:
                                    i16val = u16
                                samples.append(i16val)
                        if len(samples) % 5000 == 0 and len(samples) > 0:
                            print(f"[PC] ... {len(samples)} samples captured")

        if phase == "done":
            break

    ser.close()

    if len(samples) == 0:
        print("[PC] ERROR: No samples captured!")
        return 1

    # Print stats
    import statistics
    abs_vals = [abs(s) for s in samples]
    print(f"\n[PC] === Results ===")
    print(f"[PC] Samples: {len(samples)}")
    print(f"[PC] Duration: {len(samples)/SAMPLE_RATE:.1f}s")
    print(f"[PC] Min: {min(samples)}, Max: {max(samples)}")
    print(f"[PC] Avg abs: {sum(abs_vals)//len(abs_vals)}")
    print(f"[PC] RMS: {int((sum(s*s for s in samples)/len(samples))**0.5)}")

    if max(abs_vals) < 10:
        print("[PC] WARNING: Data appears to be all zeros/near-zero!")
    elif max(abs_vals) < 100:
        print("[PC] WARNING: Data is very quiet")
    else:
        print("[PC] Data has content (likely voice)")

    # Save WAV
    print(f"[PC] Saving WAV: {OUTPUT_WAV}")
    with wave.open(OUTPUT_WAV, 'w') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(SAMPLE_RATE)
        for s in samples:
            wf.writeframes(struct.pack('<h', s))

    print(f"[PC] Done! Play with: afplay {OUTPUT_WAV}")

    # Auto-play on macOS
    print("[PC] Playing WAV...")
    os.system(f"afplay {OUTPUT_WAV}")

    return 0

if __name__ == "__main__":
    sys.exit(main())
