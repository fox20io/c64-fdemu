#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# C64 IEC File Server
# Copyright (C) 2026 Norbert Laszlo
# -----------------------------------------------------------------------------
# Requirements:
#   pip install pyserial
# Usage:
#   python c64iec_fs.py [--port COM5] [--baud 115200] [--basedir C:\]
#   python c64iec_fs.py --port /dev/ttyUSB0 --baud 115200 --basedir /home/user/c64files
# -----------------------------------------------------------------------------
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
# -----------------------------------------------------------------------------

import argparse
import io
import os
import re
import sys
import threading
import time

try:
    import serial
except ImportError:
    print("ERROR: pyserial is not installed. Run: pip install pyserial")
    sys.exit(1)

CHUNK_SIZE      = 256
RECONNECT_DELAY = 3   # seconds between reconnect attempts

_stop_event = threading.Event()   # set on Ctrl+C to exit all loops

# ---------------------------------------------------------------------------
# Serial helpers
# ---------------------------------------------------------------------------

def read_line(port: serial.Serial) -> str:
    """Read bytes from port until \\n, return decoded ASCII string (no \\r\\n).

    Uses a short read timeout so KeyboardInterrupt is delivered on all
    platforms (blocking reads swallow SIGINT on Windows).
    Raises serial.SerialException if the port is closed/disconnected.
    Raises KeyboardInterrupt if _stop_event is set.
    """
    buf = bytearray()
    while not _stop_event.is_set():
        ch = port.read(1)   # returns b'' on timeout, byte on data
        if not ch:
            continue
        if ch == b'\n':
            break
        if ch != b'\r':
            buf += ch
    if _stop_event.is_set():
        raise KeyboardInterrupt
    return buf.decode('ascii', errors='replace')


def send_line(port: serial.Serial, text: str) -> None:
    """Send ASCII text followed by \\n."""
    port.write((text + '\n').encode('ascii'))


def read_exact(port: serial.Serial, count: int) -> bytes:
    """Read exactly *count* bytes from port, blocking until all arrive."""
    buf = bytearray()
    while len(buf) < count:
        chunk = port.read(count - len(buf))
        if chunk:
            buf += chunk
    return bytes(buf)


# ---------------------------------------------------------------------------
# CBM directory listing builder
# ---------------------------------------------------------------------------

def build_directory_listing(base_dir: str) -> bytes:
    """
    Build a CBM-style directory listing as raw bytes.

    Layout of each 32-byte line:
      [0-1]  Link pointer (LE 16-bit) to the start of the next line
      [2-3]  Line number  (LE 16-bit) -- 0 for header, filesize/254 for files
      [4-30] Content (spaces + PETSCII text)
      [31]   0x00 terminator
    """
    LOAD_ADDRESS = 0x0801
    LINE_SIZE    = 32
    MAX_FILES    = 144

    all_files = sorted(
        [
            f for f in os.scandir(base_dir)
            if f.is_file()
            and f.name.lower().endswith('.prg')
            and f.stat().st_size <= 0xFFFF
            and len(os.path.splitext(f.name)[0]) <= 16
        ],
        key=lambda f: f.name.lower()
    )[:MAX_FILES]

    total_lines = 2 + len(all_files)
    # Layout: 2 bytes load address + total_lines * 32 bytes + 2 bytes end-of-BASIC null pointer
    buf = bytearray(total_lines * LINE_SIZE + 2)

    # Load address (LE)
    buf[0] = LOAD_ADDRESS & 0xFF
    buf[1] = (LOAD_ADDRESS >> 8) & 0xFF

    # --- Header line (index 0) -----------------------------------------------
    # Memory address of the next line = LOAD_ADDRESS + LINE_SIZE
    # (the 2-byte load-address prefix in the buffer is NOT placed in memory)
    next_addr = LOAD_ADDRESS + LINE_SIZE + 2
    buf[2] = next_addr & 0xFF
    buf[3] = (next_addr >> 8) & 0xFF

    # Line content (line number = 0, reverse-video quote, disk name, id)
    header_content = b"\x00\x00\x12\"** C64-FDEMU ***\" 00 2A\x00"
    buf[4:4 + len(header_content)] = header_content

    offset = LINE_SIZE

    for f in all_files:
        next_off = LOAD_ADDRESS + offset + LINE_SIZE
        buf[offset + 0] = next_off & 0xFF
        buf[offset + 1] = (next_off >> 8) & 0xFF

        blocks = max(1, -(-f.stat().st_size // 254))   # ceiling division
        buf[offset + 2] = blocks & 0xFF
        buf[offset + 3] = (blocks >> 8) & 0xFF

        # Fill content area with spaces
        for i in range(27):
            buf[offset + 4 + i] = 0x20

        name = os.path.splitext(f.name)[0].upper()
        # Keep only printable ASCII
        name = ''.join(c for c in name if 0x20 <= ord(c) <= 0x7E)
        name_bytes = name.encode('ascii')

        # Column where the quoted name starts (depends on block-count width)
        if blocks < 10:
            col = 8
        elif blocks < 100:
            col = 7
        else:
            col = 6

        buf[offset + col - 1] = 0x22  # opening "
        for i, b in enumerate(name_bytes):
            buf[offset + col + i] = b
        buf[offset + col + 16] = 0x22  # closing "

        buf[offset + col + 18] = ord('P')
        buf[offset + col + 19] = ord('R')
        buf[offset + col + 20] = ord('G')
        buf[offset + 31] = 0x00

        offset += LINE_SIZE

    # --- Footer line ---------------------------------------------------------
    # Link pointer = 0x0000 signals end of BASIC program.
    # buf[offset+0] and buf[offset+1] are already 0x00 from bytearray().
    # The two trailing 0x00 bytes in buf (beyond the footer line) form the
    # canonical end-of-BASIC null pointer the C64 BASIC interpreter expects.

    # Exactly 30 bytes: line-number (2) + text (27) + null terminator (1).
    # The two 0x00 bytes that follow (the buffer's trailing "+2") are already
    # zero and serve as the end-of-BASIC program marker.
    footer_content = b"\x00\x00BLOCK FREE.                \x00\x00\x00"
    next_off = LOAD_ADDRESS + offset + LINE_SIZE
    buf[offset + 0] = next_off & 0xFF
    buf[offset + 1] = (next_off >> 8) & 0xFF
    buf[offset + 2 : offset + 2 + len(footer_content)] = footer_content

    return bytes(buf)


# ---------------------------------------------------------------------------
# Progress bar helper
# ---------------------------------------------------------------------------

def _print_progress(channel: int, total_size: int, pos: int, bytes_read: int,
                    is_last: bool, start_time: float) -> None:
    elapsed = time.monotonic() - start_time
    bps = int(pos / elapsed) if elapsed > 0 else 0

    if is_last:
        tot_kb = f"{total_size / 1024:.1f}"
        sys.stdout.write(f"\r\033[K[READ] Finished 100% {tot_kb}KB {bps}B/s\n")
    else:
        pct = int(pos / total_size * 100) if total_size > 0 else 100
        bar_width = 20
        filled = int(bar_width * pct / 100)
        bar = '\u2588' * filled + '\u2591' * (bar_width - filled)
        pos_kb = f"{pos / 1024:.1f}"
        tot_kb = f"{total_size / 1024:.1f}"
        sys.stdout.write(f"\r\033[K[READ] ch={channel} {bar} {pct}% {pos_kb}/{tot_kb}KB {bps}B/s")

    sys.stdout.flush()


# ---------------------------------------------------------------------------
# Command handlers
# ---------------------------------------------------------------------------

def handle_open(port: serial.Serial, fields: list, channels: dict,
                base_dir: str) -> None:
    if len(fields) < 3:
        print("[OPEN] malformed")
        send_line(port, "E0")
        return

    try:
        channel = int(fields[1], 16)
    except ValueError:
        print("[OPEN] invalid channel")
        send_line(port, "E0")
        return

    file_name = fields[2]
    print(f"[OPEN] ch={channel} file='{file_name}'", end='')

    if channel < 0 or channel > 15:
        print(" -> FAIL (invalid channel)")
        send_line(port, "E1")
        return

    # Close any existing stream on the channel
    if channel in channels:
        try:
            channels[channel].close()
        except Exception:
            pass
        del channels[channel]

    # --- Virtual file: "$" = directory listing --------------------------------
    if file_name in ('$', '$0', '$1'):
        if channel != 0:
            print(" -> FAIL ($ is read-only)")
            send_line(port, "E2")
            return
        try:
            content = build_directory_listing(base_dir)
            channels[channel] = io.BytesIO(content)
            file_count = sum(
                1 for f in os.scandir(base_dir)
                if f.is_file() and f.name.lower().endswith('.prg')
            )
            print(f" -> OK (virtual, {file_count} file(s), {len(content)} bytes)")
            send_line(port, "OK")
        except Exception as exc:
            print(f" -> FAIL ({exc})")
            send_line(port, "E*")
        return

    # --- Wildcard: "*", ":*" or "0:*" -> first .prg file in base_dir --------
    if file_name in ('*', ':*', '0:*'):
        prg_files = sorted(
            [f for f in os.scandir(base_dir)
             if f.is_file() and f.name.lower().endswith('.prg')
             and len(os.path.splitext(f.name)[0]) <= 16],
            key=lambda f: f.name.lower()
        )
        if not prg_files:
            print(" -> FAIL (no .prg files in base_dir)")
            send_line(port, "E3")
            return
        file_name = prg_files[0].name
        print(f" -> resolved to '{file_name}'", end='')

    # Append .prg if no extension
    _, ext = os.path.splitext(file_name)
    if ext.lower() != '.prg':
        file_name += '.prg'

    file_path = os.path.join(base_dir, file_name)

    # Case-insensitive lookup
    if not os.path.isfile(file_path):
        file_name_lower = file_name.lower()
        try:
            for entry in os.scandir(base_dir):
                if entry.is_file() and entry.name.lower() == file_name_lower:
                    file_path = entry.path
                    break
        except Exception:
            pass

    try:
        if channel == 0:
            if not os.path.isfile(file_path):
                print(" -> FAIL (not found)")
                send_line(port, "E3")
                return
            channels[channel] = open(file_path, 'rb')
        else:
            channels[channel] = open(file_path, 'wb')

        print(" -> OK")
        send_line(port, "OK")
    except PermissionError as exc:
        print(f" -> FAIL ({exc})")
        send_line(port, "E2")
    except Exception as exc:
        print(f" -> FAIL ({exc})")
        send_line(port, "E*")


def handle_close(port: serial.Serial, fields: list, channels: dict) -> None:
    if len(fields) < 2:
        print("[CLOSE] malformed")
        send_line(port, "E0")
        return

    try:
        channel = int(fields[1], 16)
    except ValueError:
        print("[CLOSE] invalid channel")
        send_line(port, "E0")
        return

    print(f"[CLOSE] ch={channel}", end='')

    if channel in channels:
        try:
            channels[channel].close()
            del channels[channel]
            print(" -> OK")
            send_line(port, "OK")
        except Exception as exc:
            print(f" -> FAIL ({exc})")
            send_line(port, "E*")
    else:
        print(" -> FAIL (not open)")
        send_line(port, "E1")


def handle_read(port: serial.Serial, fields: list, channels: dict,
                read_starts: dict) -> None:
    if len(fields) < 2:
        print("[READ] malformed")
        send_line(port, "E0")
        return

    try:
        channel = int(fields[1], 16)
    except ValueError:
        print("[READ] invalid channel")
        send_line(port, "E0")
        return

    read_size = CHUNK_SIZE
    if len(fields) >= 3:
        try:
            s = int(fields[2])
            if s > 0:
                read_size = s
        except ValueError:
            pass

    if channel not in channels:
        send_line(port, "E1")
        return

    stream = channels[channel]

    # Record start time for speed measurement
    if channel not in read_starts:
        read_starts[channel] = time.monotonic()

    try:
        data = stream.read(read_size)
        bytes_read = len(data)

        # Determine total size and remaining bytes without disturbing position
        pos_after = stream.tell()
        try:
            total_size = os.fstat(stream.fileno()).st_size
        except Exception:
            # BytesIO or unseekable: seek to end for size, then restore
            total_size = stream.seek(0, 2)
            stream.seek(pos_after)

        remaining = total_size - pos_after
        is_last = (bytes_read < read_size) or (remaining == 0)
        flag = 'L' if is_last else 'M'

        send_line(port, f"{flag},{bytes_read}")
        if bytes_read > 0:
            port.write(data)

        if bytes_read == 0:
            return

        start_time = read_starts[channel]
        _print_progress(channel, total_size, pos_after, bytes_read, is_last, start_time)

        if is_last:
            read_starts.pop(channel, None)

    except Exception as exc:
        print(f"[READ] ERROR: {exc}")
        send_line(port, "E*")


def handle_write(port: serial.Serial, fields: list, channels: dict) -> None:
    if len(fields) < 4:
        print("[WRITE] malformed")
        send_line(port, "E0")
        return

    try:
        channel   = int(fields[1], 16)
        byte_count = int(fields[2])
    except ValueError:
        print("[WRITE] malformed")
        send_line(port, "E0")
        return

    eoi = (fields[3] == 'E')
    print(f"[WRITE] ch={channel} len={byte_count} eoi={eoi}", end='')

    if channel not in channels:
        print(" -> FAIL (not open)")
        # Drain the raw bytes to keep the stream in sync
        if byte_count > 0:
            read_exact(port, byte_count)
        send_line(port, "E1")
        return

    try:
        data = read_exact(port, byte_count)
        stream = channels[channel]
        if data:
            stream.write(data)
        if eoi:
            stream.flush()
        print(" -> OK")
        send_line(port, "OK")
    except Exception as exc:
        print(f" -> FAIL ({exc})")
        send_line(port, "E*")


def handle_list(port: serial.Serial, base_dir: str) -> None:
    print("[LIST]", end='')
    try:
        files = list(os.scandir(base_dir))
        for f in files:
            if f.is_file():
                send_line(port, f"{f.name},{f.stat().st_size}")
        count = sum(1 for f in files if f.is_file())
        print(f" -> {count} file(s)")
    except Exception as exc:
        print(f" -> FAIL ({exc})")
        send_line(port, "E*")


# ---------------------------------------------------------------------------
# Channel management
# ---------------------------------------------------------------------------

def close_all_channels(channels: dict, read_starts: dict) -> None:
    for ch, stream in list(channels.items()):
        try:
            stream.close()
        except Exception:
            pass
    channels.clear()
    read_starts.clear()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description='C64 IEC File Server - serial protocol bridge'
    )
    parser.add_argument('--port',    default='COM5',  help='Serial port name (default: COM5)')
    parser.add_argument('--baud',    default=115200, type=int, help='Baud rate (default: 115200)')
    parser.add_argument('--basedir', default=os.path.expanduser('~'),
                        help='Base directory for .prg files (default: home dir)')
    args = parser.parse_args()

    base_dir = os.path.realpath(args.basedir)

    print("=== C64 IEC File Server ===")
    print(f"Port   : {args.port} @ {args.baud} 8-N-1")
    print(f"BaseDir: {base_dir}")
    print()

    channels:    dict = {}
    read_starts: dict = {}

    while True:
        port = None
        try:
            port = serial.Serial(
                port          = args.port,
                baudrate      = args.baud,
                bytesize      = serial.EIGHTBITS,
                parity        = serial.PARITY_NONE,
                stopbits      = serial.STOPBITS_ONE,
                timeout       = 0.1,    # short timeout so KeyboardInterrupt is delivered
                write_timeout = 5,
                dsrdtr        = False,  # do NOT use DSR/DTR as flow control
                rtscts        = False,  # do NOT use RTS/CTS flow control
            )
            # Assert DTR & RTS as plain signals so the MCU sees a live host
            port.dtr = True
            port.rts = True

            print("Port opened. Waiting for commands... (Ctrl+C to stop)")
            print()

            while True:
                line = read_line(port)
                if not line.strip():
                    continue

                # IEC bus driver reset detection
                if re.search(r'<<<.*>>>', line):
                    print()
                    print(f"*** IEC driver reset detected: {line}")
                    close_all_channels(channels, read_starts)
                    port.reset_input_buffer()
                    print("*** All channels closed, buffer flushed. Ready.")
                    print()
                    continue

                fields = line.split(',')
                cmd    = fields[0]

                if cmd != 'R':
                    print(f">> {line}")

                if   cmd == 'O': handle_open (port, fields, channels, base_dir)
                elif cmd == 'C': handle_close(port, fields, channels)
                elif cmd == 'R': handle_read (port, fields, channels, read_starts)
                elif cmd == 'W': handle_write(port, fields, channels)
                elif cmd == 'L': handle_list (port, base_dir)
                else:
                    print(f"[UNKNOWN] cmd='{cmd}' - ignoring")

        except KeyboardInterrupt:
            _stop_event.set()
            print("\nShutting down...")
            close_all_channels(channels, read_starts)
            if port and port.is_open:
                port.close()
            break

        except Exception as exc:
            print(f"Port error: {exc} - reconnecting in {RECONNECT_DELAY}s...")

        finally:
            close_all_channels(channels, read_starts)
            if port:
                try:
                    if port.is_open:
                        port.close()
                except Exception:
                    pass

        # Wait before retrying, staying responsive to Ctrl+C
        for _ in range(RECONNECT_DELAY * 10):
            if _stop_event.is_set():
                break
            time.sleep(0.1)
        if _stop_event.is_set():
            break

        print(f"Reconnecting to {args.port}...")

    print("Port closed. Goodbye.")


if __name__ == '__main__':
    main()
