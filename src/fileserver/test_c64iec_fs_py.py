#!/usr/bin/env python3
"""
Unit tests for c64iec_fs.py

No real serial port is required.  All I/O is intercepted via a fake port
object (FakePort) that wraps BytesIO buffers, and a temporary directory is
used for all file operations.

Run with:
    python -m pytest test_c64iec_fs_py.py -v
  or:
    python test_c64iec_fs_py.py
"""

import io
import os
import struct
import sys
import tempfile
import time
import unittest

# ---------------------------------------------------------------------------
# Make sure the module can be imported even without a real serial port
# ---------------------------------------------------------------------------
import unittest.mock as mock

# Stub out 'serial' before importing the server so pyserial is not required
serial_stub = mock.MagicMock()
serial_stub.Serial = mock.MagicMock
sys.modules.setdefault('serial', serial_stub)

import c64iec_fs as srv  # noqa: E402  (import after stub)


# ---------------------------------------------------------------------------
# Fake serial port
# ---------------------------------------------------------------------------

class FakePort:
    """
    Minimal stand-in for serial.Serial.

    * write() appends bytes to self.out_buf
    * read(n) returns up to n bytes from self.in_buf
    * Helpers:
        sent_lines()  -> list[str]  decoded lines that the server sent
        feed(data)    -> put raw bytes into the rx buffer
    """

    def __init__(self):
        self.in_buf  = io.BytesIO()
        self.out_buf = io.BytesIO()
        self._in_pos = 0

    # ---- rx (server reads) -------------------------------------------------
    def feed(self, data: bytes) -> None:
        pos = self.in_buf.tell()
        self.in_buf.seek(0, 2)
        self.in_buf.write(data)
        self.in_buf.seek(pos)

    def read(self, n: int) -> bytes:
        self.in_buf.seek(self._in_pos)
        data = self.in_buf.read(n)
        self._in_pos = self.in_buf.tell()
        return data

    # ---- tx (server writes) ------------------------------------------------
    def write(self, data: bytes) -> None:
        self.out_buf.write(data)

    # ---- helpers -----------------------------------------------------------
    def sent_bytes(self) -> bytes:
        return self.out_buf.getvalue()

    def sent_lines(self) -> list:
        raw = self.out_buf.getvalue()
        return [l.decode('ascii', errors='replace')
                for l in raw.split(b'\n') if l]

    def first_line(self) -> str:
        lines = self.sent_lines()
        return lines[0] if lines else ''

    def reset_out(self) -> None:
        self.out_buf = io.BytesIO()

    def fileno(self):
        raise io.UnsupportedOperation("FakePort has no fileno")


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def _write_file(path: str, content: bytes) -> None:
    with open(path, 'wb') as f:
        f.write(content)


# ===========================================================================
# Tests: build_directory_listing
# ===========================================================================

class TestBuildDirectoryListing(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _listing(self):
        return srv.build_directory_listing(self.tmp)

    def test_load_address(self):
        data = self._listing()
        self.assertEqual(data[0], 0x01)
        self.assertEqual(data[1], 0x08)

    def test_empty_dir_has_header_and_footer(self):
        data = self._listing()
        # 2 lines (header + footer) * 32 bytes + 2 load address
        self.assertEqual(len(data), 2 * 32 + 2)

    def test_header_line_number_is_zero(self):
        data = self._listing()
        # Header starts at offset 2; line number at [2:4] within the line = bytes 4-5 of buf
        self.assertEqual(data[4], 0x00)
        self.assertEqual(data[5], 0x00)

    def test_file_appears_in_listing(self):
        _write_file(os.path.join(self.tmp, 'hello.prg'), b'\x00' * 100)
        data = self._listing()
        # 3 lines * 32 + 2 (load addr)
        self.assertEqual(len(data), 3 * 32 + 2)
        raw = data.decode('latin-1')
        self.assertIn('HELLO', raw)

    def test_non_prg_files_excluded(self):
        _write_file(os.path.join(self.tmp, 'readme.txt'), b'hello')
        _write_file(os.path.join(self.tmp, 'game.prg'),   b'\x00' * 10)
        data = self._listing()
        raw = data.decode('latin-1')
        self.assertNotIn('README', raw)
        self.assertIn('GAME', raw)

    def test_max_144_files(self):
        for i in range(150):
            _write_file(os.path.join(self.tmp, f'f{i:03d}.prg'), b'\x00' * 10)
        data = self._listing()
        # 2 + 144 lines * 32 + 2 (load addr)
        self.assertEqual(len(data), (2 + 144) * 32 + 2)

    def test_blocks_field(self):
        # 254 bytes = 1 block; 255 bytes = 2 blocks
        _write_file(os.path.join(self.tmp, 'one.prg'), b'\x00' * 254)
        data = self._listing()
        # File line at offset 32 (load-addr=2 bytes, then header line starts at 2,
        # but offset counter starts at LINE_SIZE=32 without the 2-byte prefix)
        line_offset = 32   # first file line in buf
        blocks = data[line_offset + 2] | (data[line_offset + 3] << 8)
        self.assertEqual(blocks, 1)

    def test_line_terminators_are_zero(self):
        _write_file(os.path.join(self.tmp, 'a.prg'), b'\x00' * 10)
        data = self._listing()
        for line_idx in range(3):   # header, file, footer
            # In the current layout the header line starts at buf[2] but the
            # offset counter for subsequent lines starts at LINE_SIZE=32 (no
            # load-addr adjustment), so actual terminator bytes are at
            # line_idx * 32 + 31  (31, 63, 95).
            term_pos = line_idx * 32 + 31
            self.assertEqual(data[term_pos], 0x00,
                             f"Line {line_idx} terminator != 0x00")

    def test_file_too_large_excluded(self):
        _write_file(os.path.join(self.tmp, 'big.prg'),   b'\x00' * (0xFFFF + 1))
        _write_file(os.path.join(self.tmp, 'small.prg'), b'\x00' * 10)
        data = self._listing()
        raw = data.decode('latin-1')
        self.assertNotIn('BIG', raw)
        self.assertIn('SMALL', raw)

    def test_name_too_long_excluded(self):
        _write_file(os.path.join(self.tmp, 'x' * 17 + '.prg'), b'\x00' * 10)
        _write_file(os.path.join(self.tmp, 'short.prg'),        b'\x00' * 10)
        data = self._listing()
        raw = data.decode('latin-1')
        self.assertIn('SHORT', raw)
        self.assertNotIn('X' * 17, raw)


# ===========================================================================
# Tests: handle_open
# ===========================================================================

class TestHandleOpen(unittest.TestCase):

    def setUp(self):
        self.tmp  = tempfile.mkdtemp()
        self.port = FakePort()
        self.channels    = {}
        self.read_starts = {}
        _write_file(os.path.join(self.tmp, 'small.prg'), b'HELLO C64!')

    def tearDown(self):
        import shutil
        for s in self.channels.values():
            try: s.close()
            except Exception: pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _open(self, fields):
        srv.handle_open(self.port, fields, self.channels, self.tmp)

    def test_malformed_missing_filename(self):
        self._open(['O', '0'])
        self.assertEqual(self.port.first_line(), 'E0')

    def test_open_nonexistent_returns_e3(self):
        self._open(['O', '0', 'ghost.prg'])
        self.assertEqual(self.port.first_line(), 'E3')

    def test_open_existing_returns_ok(self):
        self._open(['O', '0', 'small.prg'])
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertIn(0, self.channels)

    def test_auto_append_prg(self):
        self._open(['O', '0', 'small'])
        self.assertEqual(self.port.first_line(), 'OK')

    def test_case_insensitive_lookup(self):
        self._open(['O', '0', 'SMALL.PRG'])
        self.assertEqual(self.port.first_line(), 'OK')

    def test_open_for_write_creates_file(self):
        self._open(['O', '1', 'newfile.prg'])
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertTrue(os.path.isfile(os.path.join(self.tmp, 'newfile.prg')))

    def test_virtual_dollar_on_ch0(self):
        self._open(['O', '0', '$'])
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertIsInstance(self.channels[0], io.BytesIO)

    def test_virtual_dollar_on_write_channel_returns_e2(self):
        self._open(['O', '1', '$'])
        self.assertEqual(self.port.first_line(), 'E2')

    def test_wildcard_star_opens_first_prg(self):
        self._open(['O', '0', '*'])
        self.assertEqual(self.port.first_line(), 'OK')

    def test_wildcard_no_prg_returns_e3(self):
        import shutil
        shutil.rmtree(self.tmp)
        os.makedirs(self.tmp)
        self._open(['O', '0', '*'])
        self.assertEqual(self.port.first_line(), 'E3')

    def test_reopen_closes_previous_stream(self):
        self._open(['O', '0', 'small.prg'])
        old_stream = self.channels[0]
        self.port.reset_out()
        self._open(['O', '0', 'small.prg'])
        self.assertTrue(old_stream.closed)


# ===========================================================================
# Tests: handle_close
# ===========================================================================

class TestHandleClose(unittest.TestCase):

    def setUp(self):
        self.port     = FakePort()
        self.channels = {}

    def _close(self, fields):
        srv.handle_close(self.port, fields, self.channels)

    def test_malformed_missing_channel(self):
        self._close(['C'])
        self.assertEqual(self.port.first_line(), 'E0')

    def test_close_not_open_returns_e1(self):
        self._close(['C', '0'])
        self.assertEqual(self.port.first_line(), 'E1')

    def test_close_open_channel_returns_ok(self):
        self.channels[0] = io.BytesIO(b'data')
        self._close(['C', '0'])
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertNotIn(0, self.channels)

    def test_close_hex_channel(self):
        self.channels[15] = io.BytesIO(b'data')
        self._close(['C', 'F'])
        self.assertEqual(self.port.first_line(), 'OK')


# ===========================================================================
# Tests: handle_read
# ===========================================================================

class TestHandleRead(unittest.TestCase):

    def setUp(self):
        self.port        = FakePort()
        self.channels    = {}
        self.read_starts = {}

    def _read(self, fields):
        srv.handle_read(self.port, fields, self.channels, self.read_starts)

    def _parse_response(self):
        """Return (flag, data_bytes) from the port output buffer."""
        raw = self.port.sent_bytes()
        nl  = raw.index(b'\n')
        header = raw[:nl].decode('ascii')
        flag, count_str = header.split(',')
        count = int(count_str)
        data  = raw[nl + 1: nl + 1 + count]
        return flag, data

    def test_malformed_missing_channel(self):
        self._read(['R'])
        self.assertEqual(self.port.first_line(), 'E0')

    def test_read_closed_channel_returns_e1(self):
        self._read(['R', '0'])
        self.assertEqual(self.port.first_line(), 'E1')

    def test_small_file_single_chunk_flag_L(self):
        self.channels[0] = io.BytesIO(b'HELLO C64!')
        self._read(['R', '0'])
        flag, data = self._parse_response()
        self.assertEqual(flag, 'L')
        self.assertEqual(data, b'HELLO C64!')

    def test_multi_chunk_flag_M_then_L(self):
        payload = bytes(range(256)) * 3   # 768 bytes
        self.channels[0] = io.BytesIO(payload)

        self._read(['R', '0'])
        flag1, data1 = self._parse_response()
        self.assertEqual(flag1, 'M')
        self.assertEqual(len(data1), 256)

        self.port.reset_out()
        self._read(['R', '0'])
        flag2, data2 = self._parse_response()
        self.assertEqual(flag2, 'M')

        self.port.reset_out()
        self._read(['R', '0'])
        flag3, data3 = self._parse_response()
        self.assertEqual(flag3, 'L')

        self.assertEqual(data1 + data2 + data3, payload)

    def test_custom_read_size(self):
        self.channels[0] = io.BytesIO(b'ABCDE')
        self._read(['R', '0', '3'])
        flag, data = self._parse_response()
        self.assertEqual(data, b'ABC')
        self.assertEqual(flag, 'M')

        self.port.reset_out()
        self._read(['R', '0', '3'])
        flag2, data2 = self._parse_response()
        self.assertEqual(data2, b'DE')
        self.assertEqual(flag2, 'L')

    def test_invalid_size_falls_back_to_default(self):
        self.channels[0] = io.BytesIO(b'\x00' * 256)
        self._read(['R', '0', 'abc'])
        flag, data = self._parse_response()
        self.assertEqual(len(data), 256)

    def test_zero_size_falls_back_to_default(self):
        self.channels[0] = io.BytesIO(b'\x00' * 256)
        self._read(['R', '0', '0'])
        flag, data = self._parse_response()
        self.assertEqual(len(data), 256)

    def test_exact_chunk_boundary_flag_L(self):
        # File is exactly CHUNK_SIZE bytes -> single chunk, flag L
        self.channels[0] = io.BytesIO(bytes(range(256)))
        self._read(['R', '0'])
        flag, data = self._parse_response()
        self.assertEqual(flag, 'L')
        self.assertEqual(len(data), 256)

    def test_read_past_eof_sends_L_zero(self):
        self.channels[0] = io.BytesIO(b'X')
        self._read(['R', '0'])
        self.port.reset_out()
        # Stream is now at EOF; reading again should return L,0
        self._read(['R', '0'])
        flag, data = self._parse_response()
        self.assertEqual(flag, 'L')
        self.assertEqual(len(data), 0)

    def test_hex_channel_number(self):
        self.channels[10] = io.BytesIO(b'DATA')
        self._read(['R', 'A'])
        flag, data = self._parse_response()
        self.assertEqual(data, b'DATA')

    def test_directory_listing_readable(self):
        # Simulate what handle_open does for '$'
        content = b'\x01\x08' + b'\x00' * 62   # minimal fake dir
        self.channels[0] = io.BytesIO(content)
        self._read(['R', '0'])
        flag, data = self._parse_response()
        self.assertEqual(data, content)
        self.assertEqual(flag, 'L')


# ===========================================================================
# Tests: handle_write
# ===========================================================================

class TestHandleWrite(unittest.TestCase):

    def setUp(self):
        self.port     = FakePort()
        self.channels = {}

    def _write(self, fields, payload: bytes = b''):
        self.port.feed(payload)
        srv.handle_write(self.port, fields, self.channels)

    def test_malformed_missing_fields(self):
        self._write(['W', '1'])
        self.assertEqual(self.port.first_line(), 'E0')

    def test_write_to_closed_channel_drains_and_returns_e1(self):
        self._write(['W', '1', '3', 'E'], b'ABC')
        self.assertEqual(self.port.first_line(), 'E1')

    def test_write_data_appended_to_stream(self):
        buf = io.BytesIO()
        self.channels[1] = buf
        self._write(['W', '1', '5', 'C'], b'HELLO')
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertEqual(buf.getvalue(), b'HELLO')

    def test_write_eoi_flushes(self):
        buf = io.BytesIO()
        self.channels[1] = buf
        self._write(['W', '1', '5', 'E'], b'WORLD')
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertEqual(buf.getvalue(), b'WORLD')

    def test_multi_chunk_write(self):
        buf = io.BytesIO()
        self.channels[1] = buf
        self._write(['W', '1', '3', 'C'], b'FOO')
        self.port.reset_out()
        self._write(['W', '1', '3', 'E'], b'BAR')
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertEqual(buf.getvalue(), b'FOOBAR')

    def test_zero_byte_write(self):
        buf = io.BytesIO()
        self.channels[1] = buf
        self._write(['W', '1', '0', 'E'], b'')
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertEqual(buf.getvalue(), b'')


# ===========================================================================
# Tests: handle_list
# ===========================================================================

class TestHandleList(unittest.TestCase):

    def setUp(self):
        self.tmp  = tempfile.mkdtemp()
        self.port = FakePort()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _list(self):
        srv.handle_list(self.port, self.tmp)

    def test_empty_dir_no_lines_sent(self):
        self._list()
        self.assertEqual(self.port.sent_lines(), [])

    def test_single_file_correct_format(self):
        _write_file(os.path.join(self.tmp, 'test.prg'), b'\x00' * 42)
        self._list()
        lines = self.port.sent_lines()
        self.assertEqual(len(lines), 1)
        name, size = lines[0].split(',')
        self.assertEqual(name, 'test.prg')
        self.assertEqual(size, '42')

    def test_multiple_files(self):
        _write_file(os.path.join(self.tmp, 'a.prg'), b'\x00' * 10)
        _write_file(os.path.join(self.tmp, 'b.prg'), b'\x00' * 20)
        self._list()
        self.assertEqual(len(self.port.sent_lines()), 2)


# ===========================================================================
# Tests: close_all_channels
# ===========================================================================

class TestCloseAllChannels(unittest.TestCase):

    def test_closes_and_clears(self):
        s1 = io.BytesIO(b'a')
        s2 = io.BytesIO(b'b')
        channels    = {0: s1, 1: s2}
        read_starts = {0: time.monotonic()}

        srv.close_all_channels(channels, read_starts)

        self.assertEqual(channels, {})
        self.assertEqual(read_starts, {})
        # BytesIO.closed is True after close()
        self.assertTrue(s1.closed)
        self.assertTrue(s2.closed)


# ===========================================================================
# Tests: full open → read → close round-trip (integration-style)
# ===========================================================================

class TestOpenReadClose(unittest.TestCase):

    def setUp(self):
        self.tmp         = tempfile.mkdtemp()
        self.port        = FakePort()
        self.channels    = {}
        self.read_starts = {}

    def tearDown(self):
        import shutil
        srv.close_all_channels(self.channels, self.read_starts)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_full_read_small_file(self):
        content = b'PETSCII RULES'
        _write_file(os.path.join(self.tmp, 'demo.prg'), content)

        srv.handle_open(self.port, ['O', '0', 'demo.prg'], self.channels, self.tmp)
        self.port.reset_out()

        srv.handle_read(self.port, ['R', '0'], self.channels, self.read_starts)
        raw = self.port.sent_bytes()
        nl  = raw.index(b'\n')
        header = raw[:nl].decode('ascii')
        flag, count_str = header.split(',')
        data = raw[nl + 1: nl + 1 + int(count_str)]

        self.assertEqual(flag, 'L')
        self.assertEqual(data, content)

        self.port.reset_out()
        srv.handle_close(self.port, ['C', '0'], self.channels)
        self.assertEqual(self.port.first_line(), 'OK')
        self.assertNotIn(0, self.channels)

    def test_full_write_then_read_back(self):
        payload = b'HELLO FROM PYTHON'

        srv.handle_open(self.port, ['O', '1', 'out.prg'], self.channels, self.tmp)
        self.port.reset_out()

        self.port.feed(payload)
        srv.handle_write(self.port, ['W', '1', str(len(payload)), 'E'],
                         self.channels)
        self.assertEqual(self.port.first_line(), 'OK')

        self.port.reset_out()
        srv.handle_close(self.port, ['C', '1'], self.channels)

        # Now read back
        srv.handle_open(self.port, ['O', '0', 'out.prg'], self.channels, self.tmp)
        self.port.reset_out()

        srv.handle_read(self.port, ['R', '0'], self.channels, self.read_starts)
        raw = self.port.sent_bytes()
        nl  = raw.index(b'\n')
        data = raw[nl + 1: nl + 1 + len(payload)]
        self.assertEqual(data, payload)

    def test_virtual_dir_read(self):
        _write_file(os.path.join(self.tmp, 'game.prg'), b'\x00' * 100)

        srv.handle_open(self.port, ['O', '0', '$'], self.channels, self.tmp)
        self.assertEqual(self.port.first_line(), 'OK')
        self.port.reset_out()

        # Read all chunks
        all_data = b''
        for _ in range(20):
            srv.handle_read(self.port, ['R', '0'], self.channels, self.read_starts)
            raw = self.port.sent_bytes()
            nl  = raw.index(b'\n')
            header = raw[:nl].decode('ascii')
            flag, count_str = header.split(',')
            count = int(count_str)
            all_data += raw[nl + 1: nl + 1 + count]
            self.port.reset_out()
            if flag == 'L':
                break

        # Load address must be 0x0801
        self.assertEqual(all_data[0], 0x01)
        self.assertEqual(all_data[1], 0x08)
        raw_text = all_data.decode('latin-1')
        self.assertIn('GAME', raw_text)


# ===========================================================================
# Entry point
# ===========================================================================

if __name__ == '__main__':
    unittest.main(verbosity=2)
