#!/usr/bin/env python3
"""
bk_flash.py — Command-line flash tool for Beken BK7258 (macOS/Linux).

Protocol: BK HCI over UART (reverse-engineered from cp/components/bk_download/).

Usage:
    python3 bk_flash.py --port /dev/cu.usbserial-130 flash all-app.bin
    python3 bk_flash.py --port /dev/cu.usbserial-130 monitor
    python3 bk_flash.py --port /dev/cu.usbserial-130 link-check
"""

import argparse
import struct
import sys
import time
import zlib

import serial

# ── BK HCI Protocol Constants ──────────────────────────────────────────

# Common commands
CMD_LINK_CHECK      = 0x00
RSP_LINK_CHECK      = 0x01
CMD_REG_WRITE       = 0x01
CMD_REG_READ        = 0x03
CMD_REBOOT          = 0x0E
CMD_SET_BAUDRATE    = 0x0F
CMD_CHECK_CRC32     = 0x10
CMD_RESET           = 0x70
CMD_STAY_ROM        = 0xAA
CMD_STARTUP         = 0xFE

# Flash commands (carried via cmd_id=0xF4)
FLASH_CMD_WRITE         = 0x06
FLASH_CMD_SECTOR_WRITE  = 0x07
FLASH_CMD_READ          = 0x08
FLASH_CMD_SECTOR_READ   = 0x09
FLASH_CMD_CHIP_ERASE    = 0x0A
FLASH_CMD_SECTOR_ERASE  = 0x0B
FLASH_CMD_REG_READ      = 0x0C
FLASH_CMD_REG_WRITE     = 0x0D
FLASH_CMD_SPI_OPERATE   = 0x0E
FLASH_CMD_SIZE_ERASE    = 0x0F

# Extended commands (can be common or flash type)
EXT_CMD_RAM_WRITE   = 0x21
EXT_CMD_RAM_READ    = 0x23
EXT_CMD_JUMP        = 0x25

SECTOR_SIZE = 4096


class BkFlasher:
    """Beken BK7258 UART flash programmer."""

    def __init__(self, port: str, baudrate: int = 115200, timeout: float = 2.0):
        self.port = port
        self.baudrate = baudrate
        self.ser = serial.Serial(port, baudrate, timeout=timeout)
        self.verbose = False

    def close(self):
        if self.ser and self.ser.is_open:
            self.ser.close()

    # ── Low-level BK HCI framing ───────────────────────────────────────

    def _send_common_cmd(self, cmd_id: int, params: bytes = b"") -> None:
        """Send a BK HCI common command: 01 E0 FC <len> <cmd_id> [params]"""
        cmd_len = 1 + len(params)  # cmd_id + params
        frame = bytes([0x01, 0xE0, 0xFC, cmd_len, cmd_id]) + params
        if self.verbose:
            print(f"  TX: {frame.hex()}")
        self.ser.write(frame)

    def _send_flash_cmd(self, flash_cmd_id: int, params: bytes = b"") -> None:
        """Send a BK HCI flash command: 01 E0 FC FF F4 <len_lo> <len_hi> <flash_cmd_id> [params]"""
        flash_cmd_len = 1 + len(params)  # flash_cmd_id + params
        frame = bytes([0x01, 0xE0, 0xFC, 0xFF, 0xF4])
        frame += struct.pack("<H", flash_cmd_len)
        frame += bytes([flash_cmd_id]) + params
        if self.verbose:
            print(f"  TX: {frame[:16].hex()}... ({len(frame)} bytes)")
        self.ser.write(frame)

    def _recv_common_rsp(self, expected_cmd_id: int = None, timeout: float = 3.0) -> bytes:
        """
        Receive a BK HCI common response: 04 0E <len> 01 E0 FC <cmd_id> [params]
        Returns the full payload after the 04 0E header (including len, 01 E0 FC, cmd_id, params).
        """
        deadline = time.time() + timeout
        buf = b""

        while time.time() < deadline:
            byte = self.ser.read(1)
            if not byte:
                continue
            buf += byte

            # Look for response pattern: 04 0E
            idx = buf.find(b"\x04\x0e")
            if idx < 0:
                # Keep only last byte (could be start of 04 0E)
                if len(buf) > 256:
                    buf = buf[-1:]
                continue

            # We found 04 0E, need at least 1 more byte for len
            remaining = buf[idx:]
            if len(remaining) < 3:
                more = self.ser.read(3 - len(remaining))
                remaining += more

            if len(remaining) < 3:
                continue

            rsp_len = remaining[2]

            if rsp_len == 0xFF:
                # Flash response: 04 0E FF 01 E0 FC F4 <len_lo> <len_hi> <flash_cmd_id> <status> [params]
                # Need at least 10 bytes total from start
                need = 10
                while len(remaining) < need:
                    more = self.ser.read(need - len(remaining))
                    if not more:
                        break
                    remaining += more

                if len(remaining) < 10:
                    continue

                flash_rsp_len = remaining[7] | (remaining[8] << 8)
                total_need = 10 + (flash_rsp_len - 2)  # -2 for flash_cmd_id and status already counted

                while len(remaining) < total_need:
                    more = self.ser.read(total_need - len(remaining))
                    if not more:
                        break
                    remaining += more

                if self.verbose:
                    print(f"  RX: {remaining[:32].hex()}... ({len(remaining)} bytes)")
                return remaining
            else:
                # Common response: 04 0E <len> 01 E0 FC <cmd_id> [params]
                total_need = 2 + 1 + rsp_len  # 04 0E + len_byte + payload
                while len(remaining) < total_need:
                    more = self.ser.read(total_need - len(remaining))
                    if not more:
                        break
                    remaining += more

                if self.verbose:
                    print(f"  RX: {remaining.hex()}")

                if expected_cmd_id is not None and len(remaining) >= 7:
                    actual_cmd_id = remaining[6]
                    if actual_cmd_id != expected_cmd_id:
                        if self.verbose:
                            print(f"  Warning: expected cmd_id 0x{expected_cmd_id:02x}, got 0x{actual_cmd_id:02x}")

                return remaining

        return b""

    # ── High-level commands ────────────────────────────────────────────

    def link_check(self) -> bool:
        """Send LINK_CHECK and check for response."""
        self.ser.reset_input_buffer()
        self._send_common_cmd(CMD_LINK_CHECK)
        rsp = self._recv_common_rsp(expected_cmd_id=RSP_LINK_CHECK, timeout=2.0)
        return len(rsp) > 0

    def stay_rom(self) -> bool:
        """Send STAY_ROM to keep bootloader active."""
        self._send_common_cmd(CMD_STAY_ROM, b"\x55")
        rsp = self._recv_common_rsp(expected_cmd_id=CMD_STAY_ROM, timeout=2.0)
        return len(rsp) > 0

    def set_baudrate(self, new_baudrate: int, delay_ms: int = 5) -> bool:
        """Change UART baudrate."""
        params = struct.pack("<IB", new_baudrate, delay_ms)
        self._send_common_cmd(CMD_SET_BAUDRATE, params)
        rsp = self._recv_common_rsp(expected_cmd_id=CMD_SET_BAUDRATE, timeout=2.0)
        if rsp:
            time.sleep(delay_ms / 1000.0 + 0.05)
            self.ser.baudrate = new_baudrate
            return True
        return False

    def reboot(self) -> None:
        """Send REBOOT command."""
        self._send_common_cmd(CMD_REBOOT, b"\xA5")
        # Don't wait for response, device will reboot

    def read_flash_id(self) -> int:
        """Read flash JEDEC ID via SPI_OPERATE command."""
        self._send_flash_cmd(FLASH_CMD_SPI_OPERATE, b"\x9F\x00\x00\x00")
        rsp = self._recv_common_rsp(timeout=3.0)
        if len(rsp) >= 14:
            # Flash response: ... <status> <id bytes>
            flash_id = (rsp[11] << 24) | (rsp[12] << 16) | (rsp[13] << 8) | rsp[14] if len(rsp) > 14 else 0
            return flash_id
        return 0

    def sector_erase(self, addr: int) -> bool:
        """Erase a 4KB sector at the given address."""
        params = struct.pack("<I", addr)
        self._send_flash_cmd(FLASH_CMD_SECTOR_ERASE, params)
        rsp = self._recv_common_rsp(timeout=5.0)
        if rsp and len(rsp) >= 10:
            status = rsp[10] if len(rsp) > 10 else 0xFF
            return status == 0
        return False

    def sector_write(self, addr: int, data: bytes) -> bool:
        """Write a 4KB sector (must be exactly 4096 bytes)."""
        assert len(data) == SECTOR_SIZE, f"Data must be {SECTOR_SIZE} bytes, got {len(data)}"
        params = struct.pack("<I", addr) + data
        self._send_flash_cmd(FLASH_CMD_SECTOR_WRITE, params)
        rsp = self._recv_common_rsp(timeout=10.0)
        if rsp and len(rsp) >= 11:
            status = rsp[10]
            return status == 0
        return False

    def check_crc32(self, start_addr: int, end_addr: int) -> int:
        """Calculate CRC32 of flash region [start_addr, end_addr]."""
        params = struct.pack("<II", start_addr, end_addr)
        self._send_common_cmd(CMD_CHECK_CRC32, params)
        rsp = self._recv_common_rsp(expected_cmd_id=CMD_CHECK_CRC32, timeout=30.0)
        if rsp and len(rsp) >= 11:
            crc = struct.unpack("<I", rsp[7:11])[0]
            return crc
        return 0

    # ── Flash procedure ────────────────────────────────────────────────

    def connect(self, retries: int = 20) -> bool:
        """
        Try to establish connection with bootloader.
        The bootloader sends a startup indication at power-on, then listens
        for LINK_CHECK for a short window. We keep sending LINK_CHECK
        until we get a response.
        """
        print(f"Connecting to {self.port} at {self.baudrate} baud...")
        print("  (Power-cycle or reset the board now)")

        for i in range(retries):
            self.ser.reset_input_buffer()
            self._send_common_cmd(CMD_LINK_CHECK)
            time.sleep(0.05)

            # Check for any response
            rsp = self._recv_common_rsp(timeout=0.3)
            if rsp:
                # Check if it's a startup indication or link check response
                if len(rsp) >= 7:
                    cmd_id = rsp[6]
                    if cmd_id == RSP_LINK_CHECK:
                        print(f"  Connected! (attempt {i+1})")
                        return True
                    elif cmd_id == CMD_STARTUP:
                        print(f"  Got startup indication, sending link check...")
                        # Send link check again
                        self._send_common_cmd(CMD_LINK_CHECK)
                        rsp2 = self._recv_common_rsp(expected_cmd_id=RSP_LINK_CHECK, timeout=1.0)
                        if rsp2:
                            print(f"  Connected!")
                            return True

            sys.stdout.write(f"\r  Attempt {i+1}/{retries}...")
            sys.stdout.flush()

        print("\n  Failed to connect.")
        return False

    def flash_firmware(self, firmware_path: str, start_addr: int = 0,
                       fast_baudrate: int = 0) -> bool:
        """Flash a firmware binary to the device."""
        with open(firmware_path, "rb") as f:
            data = f.read()

        total_size = len(data)
        total_sectors = (total_size + SECTOR_SIZE - 1) // SECTOR_SIZE

        print(f"\nFlashing {firmware_path}")
        print(f"  Size: {total_size} bytes ({total_sectors} sectors)")
        print(f"  Start address: 0x{start_addr:08X}")

        # Step 1: Connect
        if not self.connect():
            return False

        # Step 2: Stay in ROM
        print("  Sending STAY_ROM...")
        if not self.stay_rom():
            print("  Warning: No response to STAY_ROM (may still work)")

        # Step 3: Optionally switch to faster baudrate
        if fast_baudrate and fast_baudrate != self.baudrate:
            print(f"  Switching to {fast_baudrate} baud...")
            if self.set_baudrate(fast_baudrate):
                print(f"  Baudrate set to {fast_baudrate}")
            else:
                print(f"  Failed to set baudrate, continuing at {self.baudrate}")

        # Step 4: Read flash ID
        flash_id = self.read_flash_id()
        if flash_id:
            print(f"  Flash ID: 0x{flash_id:08X}")
        else:
            print("  Warning: Could not read flash ID")

        # Step 5: Erase and write sectors
        print(f"\n  Erasing and writing {total_sectors} sectors...")
        start_time = time.time()

        for i in range(total_sectors):
            addr = start_addr + i * SECTOR_SIZE
            chunk = data[i * SECTOR_SIZE:(i + 1) * SECTOR_SIZE]

            # Pad to sector size if needed
            if len(chunk) < SECTOR_SIZE:
                chunk += b"\xFF" * (SECTOR_SIZE - len(chunk))

            # Skip empty sectors (all 0xFF)
            if chunk == b"\xFF" * SECTOR_SIZE:
                progress = (i + 1) / total_sectors * 100
                sys.stdout.write(f"\r  [{progress:5.1f}%] Skipping empty sector at 0x{addr:08X}")
                sys.stdout.flush()
                continue

            # Erase sector
            if not self.sector_erase(addr):
                print(f"\n  Error: Failed to erase sector at 0x{addr:08X}")
                return False

            # Write sector
            if not self.sector_write(addr, chunk):
                print(f"\n  Error: Failed to write sector at 0x{addr:08X}")
                return False

            progress = (i + 1) / total_sectors * 100
            elapsed = time.time() - start_time
            speed = ((i + 1) * SECTOR_SIZE) / elapsed / 1024 if elapsed > 0 else 0
            sys.stdout.write(f"\r  [{progress:5.1f}%] 0x{addr:08X} ({speed:.1f} KB/s)")
            sys.stdout.flush()

        elapsed = time.time() - start_time
        print(f"\n\n  Flash complete! ({elapsed:.1f}s)")

        # Step 6: Verify CRC32
        print("  Verifying CRC32...")
        end_addr = start_addr + total_size - 1

        # Calculate local CRC32 (matching the firmware's CRC init with 0xFFFFFFFF)
        local_crc = 0xFFFFFFFF
        for i in range(0, total_size, 256):
            chunk = data[i:i + 256]
            local_crc = zlib.crc32(chunk, local_crc) & 0xFFFFFFFF

        device_crc = self.check_crc32(start_addr, end_addr)
        if device_crc == local_crc:
            print(f"  CRC32 OK: 0x{local_crc:08X}")
        else:
            print(f"  CRC32 MISMATCH! Local=0x{local_crc:08X}, Device=0x{device_crc:08X}")

        # Step 7: Reboot
        print("  Rebooting device...")
        self.reboot()
        print("  Done!")

        return True


def cmd_flash(args):
    """Flash firmware to device."""
    flasher = BkFlasher(args.port, args.baudrate)
    flasher.verbose = args.verbose
    try:
        success = flasher.flash_firmware(
            args.firmware,
            start_addr=args.addr,
            fast_baudrate=args.fast_baudrate,
        )
        sys.exit(0 if success else 1)
    finally:
        flasher.close()


def cmd_link_check(args):
    """Test link check with bootloader."""
    flasher = BkFlasher(args.port, args.baudrate)
    flasher.verbose = args.verbose
    try:
        if flasher.connect(retries=args.retries):
            print("Link check successful!")

            if flasher.stay_rom():
                print("STAY_ROM successful!")

            flash_id = flasher.read_flash_id()
            if flash_id:
                print(f"Flash ID: 0x{flash_id:08X}")
        else:
            print("Link check failed.")
            sys.exit(1)
    finally:
        flasher.close()


def cmd_monitor(args):
    """Serial monitor (like minicom)."""
    print(f"Opening {args.port} at {args.baudrate} baud...")
    print("Press Ctrl+C to exit.\n")

    ser = serial.Serial(args.port, args.baudrate, timeout=0.1)
    try:
        while True:
            data = ser.read(256)
            if data:
                try:
                    text = data.decode("utf-8", errors="replace")
                    sys.stdout.write(text)
                    sys.stdout.flush()
                except Exception:
                    sys.stdout.write(data.hex() + " ")
                    sys.stdout.flush()
    except KeyboardInterrupt:
        print("\n\nMonitor stopped.")
    finally:
        ser.close()


def main():
    parser = argparse.ArgumentParser(description="Beken BK7258 Flash Tool")
    parser.add_argument("--port", "-p", required=True, help="Serial port (e.g., /dev/cu.usbserial-130)")
    parser.add_argument("--baudrate", "-b", type=int, default=115200, help="Initial baud rate (default: 115200)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")

    sub = parser.add_subparsers(dest="command", required=True)

    # flash command
    p_flash = sub.add_parser("flash", help="Flash firmware to device")
    p_flash.add_argument("firmware", help="Path to firmware binary (e.g., all-app.bin)")
    p_flash.add_argument("--addr", type=lambda x: int(x, 0), default=0, help="Start address (default: 0)")
    p_flash.add_argument("--fast-baudrate", type=int, default=921600,
                         help="Faster baudrate for transfer (default: 921600, 0 to disable)")

    # link-check command
    p_link = sub.add_parser("link-check", help="Test link with bootloader")
    p_link.add_argument("--retries", type=int, default=30, help="Number of retries (default: 30)")

    # monitor command
    sub.add_parser("monitor", help="Serial monitor")

    args = parser.parse_args()

    if args.command == "flash":
        cmd_flash(args)
    elif args.command == "link-check":
        cmd_link_check(args)
    elif args.command == "monitor":
        cmd_monitor(args)


if __name__ == "__main__":
    main()
