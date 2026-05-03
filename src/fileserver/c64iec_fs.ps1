# -----------------------------------------------------------------------------
# C64 IEC File Server
# Copyright (C) 2026 Norbert Laszlo
# -----------------------------------------------------------------------------
# Usage:
#   .\c64iec_fs.ps1 [-PortName COM5] [-BaudRate 115200] [-BaseDir D:\c64_files] [-DevID -1]
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

param(
    [string]$PortName = "COM5",
    [int]$BaudRate = 115200,
    [string]$BaseDir = "C:\",
    [int]$DevID = -1 # -1=adapter default, 0-15=force specific device number
)

$VERSION = "1.0"

$ChunkSize = 256

# --- State: open file handles per channel (0-15) ---------------------------
$channels  = @{}
$readStart = @{}   # per-channel Stopwatch for speed measurement

# --- Constants for directory listing generation -----------------------------
$DIR_LIST_HEADER = [Text.Encoding]::ASCII.GetBytes("`0`0$([char]0x12)`" C64-FDEMU V$VERSION `" 00 2A`0")
$DIR_LIST_FOOTER = [Text.Encoding]::ASCII.GetBytes("`0`0BLOCK FREE.$(' ' * 16)`0`0`0")
$DIR_LIST_PRG = [Text.Encoding]::ASCII.GetBytes("PRG")
$DIR_LIST_SPC27 = [Text.Encoding]::ASCII.GetBytes("$(' ' * 27)")

# --- Helpers ----------------------------------------------------------------

function Read-Line([System.IO.Ports.SerialPort]$port) {
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        while ($port.BytesToRead -eq 0) {
            Start-Sleep -Milliseconds 5
        }
        $ch = [char]$port.ReadChar()
        if ($ch -eq "`n") { break }
        if ($ch -ne "`r") {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Send-Line([System.IO.Ports.SerialPort]$port, [string]$line) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$line`n")
    $port.Write($bytes, 0, $bytes.Length)
}

function ConvertFrom-HexString([string]$hex) {
    if ([string]::IsNullOrEmpty($hex)) { return ,@() }
    $count = $hex.Length / 2
    $buf = New-Object byte[] $count
    for ($i = 0; $i -lt $count; $i++) {
        $buf[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
    }
    return ,$buf
}

function ConvertTo-HexString([byte[]]$data, [int]$length) {
    if ($length -eq 0) { return "" }
    $sb = New-Object System.Text.StringBuilder ($length * 2)
    for ($i = 0; $i -lt $length; $i++) {
        [void]$sb.Append($data[$i].ToString("X2"))
    }
    return $sb.ToString()
}

function Show-HexDump([byte[]]$buf) {
    Write-Host "\n"
    $offset = 0
    while ($offset -lt $buf.Length) {
        $lineBytes = [System.Math]::Min(16, $buf.Length - $offset)
        $hexPart = ($buf[$offset..($offset + $lineBytes - 1)] | ForEach-Object { $_.ToString("X2") }) -join ' '
        $asciiPart = ($buf[$offset..($offset + $lineBytes - 1)] | ForEach-Object {
            if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } else { '.' }
        }) -join ''
        Write-Host ("{0:X8}  {1,-48}  {2}" -f $offset, $hexPart, $asciiPart)
        $offset += $lineBytes
    }
}

# Build a CBM-style directory listing as a byte array.
# Each line is exactly 32 bytes:
#   [0-1]  Link pointer (LE 16-bit) to the start of the next line
#   [2-3]  Line number  (LE 16-bit) — 0 for header, filesize/254 for files
#   [4-30] Content
#   [31]   0x00 terminator
function New-DirectoryListing {
    $LoadAddress = 0x0801
    $LineSize = 32
    $MaxFiles = 144
    $files = Get-ChildItem -Path $BaseDir -File | Where-Object { $_.Length -le 0xFFFF -band $_.Extension -eq ".prg" -and $_.BaseName.Length -le 16 } | Select-Object -First $MaxFiles
    $totalLines = 2 + @($files).Count
    $buf = New-Object byte[] ($totalLines * $LineSize + 2)

    # --- Load address
    $buf[0] = [byte]($LoadAddress -band 0xFF)
    $buf[1] = [byte](($LoadAddress -shr 8) -band 0xFF)

    # --- Header line (line 0) ------------------------------------------------
    $nextAddr = $LoadAddress + $LineSize + 2

    # Link pointer to next line
    $buf[2] = [byte]($nextAddr -band 0xFF)
    $buf[3] = [byte](($nextAddr -shr 8) -band 0xFF)

    # Fixed header content
    $DIR_LIST_HEADER.CopyTo($buf, 4)

    $offset = $LineSize
    foreach ($f in $files) {
        $nextOff = $offset + $LineSize + $LoadAddress
        $buf[$offset + 0] = [byte]($nextOff -band 0xFF)
        $buf[$offset + 1] = [byte](($nextOff -shr 8) -band 0xFF)

        $blocks = [math]::Ceiling($f.Length / 254)
        $buf[$offset + 2] = [byte]($blocks -band 0xFF)
        $buf[$offset + 3] = [byte](($blocks -shr 8) -band 0xFF)

        $DIR_LIST_SPC27.CopyTo($buf, $offset + 4)

        $name = $f.BaseName.ToUpper()
        $name = -join ($name.ToCharArray() | Where-Object { [int]$_ -ge 0x20 -and [int]$_ -le 0x7E })
        $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($name)
        $offsetName = 6
        if ($blocks -lt 10) {
            $offsetName = 8
        } elseif ($blocks -lt 100) {
            $offsetName = 7
        }
        $buf[$offset + $offsetName - 1] = 0x22
        $nameBytes.CopyTo($buf, $offset + $offsetName)
        $buf[$offset + $offsetName + 16] = 0x22

        $DIR_LIST_PRG.CopyTo($buf, $offset + $offsetName + 18)
        $buf[$offset + 31] = 0x00

        $offset += $LineSize
    }

    # Fixed footer content
    $nextOff = $offset + $LineSize + $LoadAddress
    $buf[$offset + 0] = [byte]($nextOff -band 0xFF)
    $buf[$offset + 1] = [byte](($nextOff -shr 8) -band 0xFF)
    $DIR_LIST_FOOTER.CopyTo($buf, $offset + 2)

    return ,$buf
}

# --- Command handlers -------------------------------------------------------

function Invoke-OpenHandler([System.IO.Ports.SerialPort]$port, [string[]]$fields) {
    if ($fields.Length -lt 3) {
        Write-Host "[OPEN] malformed"
        Send-Line $port "E0"
        return
    }

    $channel = [Convert]::ToInt32($fields[1], 16)
    $fileName = $fields[2]

    Write-Host "[OPEN] ch=$channel file='$fileName'" -NoNewline

    if ($channel -lt 0 -or $channel -gt 15) {
        Write-Host " -> FAIL (invalid channel)"
        Send-Line $port "E1"
        return
    }

    if ($channels.ContainsKey($channel)) {
        try { $channels[$channel].Close() } catch {}
        $channels.Remove($channel)
    }

    # --- Virtual file: "$" = directory listing ---
    if ($fileName -eq '$' -or $fileName -eq '$0' -or $fileName -eq '$1') {
        if ($channel -ne 0) {
            Write-Host " -> FAIL (\$ is read-only)"
            Send-Line $port "E2"
            return
        }
        try {
            $contentBytes = New-DirectoryListing
            $stream = New-Object System.IO.MemoryStream (,$contentBytes)
            $channels[$channel] = $stream
            $fileCount = (Get-ChildItem -Path $BaseDir -File).Count
            Write-Host " -> OK (virtual, $fileCount file(s), $($contentBytes.Length) bytes)"
            Send-Line $port "OK"
        }
        catch {
            Write-Host " -> FAIL ($_)"
            Send-Line $port "E*"
        }
        return
    }

    # --- Wildcard: "*", ":*" or "0:*" -> first .prg file in BaseDir ---
    if ($fileName -eq '*' -or $fileName -eq ':*' -or $fileName -eq '0:*') {
        $first = Get-ChildItem -Path $BaseDir -File -Filter '*.prg' |
                 Where-Object { $_.BaseName.Length -le 16 } |
                 Select-Object -First 1
        if (-not $first) {
            Write-Host " -> FAIL (no .prg files in BaseDir)"
            Send-Line $port "E3"
            return
        }
        $fileName = $first.Name
        Write-Host " -> resolved to '$fileName'" -NoNewline
    }

    # Append .prg extension if the filename has no extension
    $ext = [System.IO.Path]::GetExtension($fileName)
    if ($ext -ine ".prg") {
        $fileName = $fileName + ".prg"
    }

    $filePath = Join-Path $BaseDir $fileName

    # C64 sends filenames in uppercase PETSCII — find the actual file
    # with a case-insensitive match in case the disk name differs.
    if (-not (Test-Path $filePath)) {
        $match = Get-ChildItem -Path $BaseDir -File |
                 Where-Object { $_.Name -ieq $fileName } |
                 Select-Object -First 1
        if ($match) { $filePath = $match.FullName }
    }

    try {
        if ($channel -eq 0) {
            if (-not (Test-Path $filePath)) {
                Write-Host " -> FAIL (not found)"
                Send-Line $port "E3"
                return
            }
            $stream = [System.IO.File]::OpenRead($filePath)
        } else {
            $stream = [System.IO.File]::Create($filePath)
        }
        $channels[$channel] = $stream
        Write-Host " -> OK"
        Send-Line $port "OK"
    }
    catch {
        Write-Host " -> FAIL ($_)"
        Send-Line $port "E*"
    }
}

function Invoke-CloseHandler([System.IO.Ports.SerialPort]$port, [string[]]$fields) {
    if ($fields.Length -lt 2) {
        Write-Host "[CLOSE] malformed"
        Send-Line $port "E0"
        return
    }

    $channel = [Convert]::ToInt32($fields[1], 16)
    Write-Host "[CLOSE] ch=$channel" -NoNewline

    if ($channels.ContainsKey($channel)) {
        try {
            $channels[$channel].Close()
            $channels.Remove($channel)
            Write-Host " -> OK"
            Send-Line $port "OK"
        }
        catch {
            Write-Host " -> FAIL ($_)"
            Send-Line $port "E*"
        }
    } else {
        Write-Host " -> FAIL (not open)"
        Send-Line $port "E1"
    }
}

function Invoke-ReadHandler([System.IO.Ports.SerialPort]$port, [string[]]$fields) {
    if ($fields.Length -lt 2) {
        Write-Host "[READ] malformed"
        Send-Line $port "E0"
        return
    }

    $channel = [Convert]::ToInt32($fields[1], 16)
    $readSize = $ChunkSize
    if ($fields.Length -ge 3 -and $fields[2] -match '^\d+$') {
        $readSize = [int]$fields[2]
        if ($readSize -le 0) { $readSize = $ChunkSize }
    }

    if (-not $channels.ContainsKey($channel)) {
        Write-Host " -> FAIL (not open)"
        Send-Line $port "E1"
        return
    }

    $stream = $channels[$channel]
    $buf = New-Object byte[] $readSize
    $bytesRead = $stream.Read($buf, 0, $readSize)

    $remaining = $stream.Length - $stream.Position
    $isLast = ($bytesRead -lt $readSize) -or ($remaining -eq 0)
    $flag = if ($isLast) { "L" } else { "M" }

    # Header line: flag,bytecount\n  then raw bytes (no hex encoding)
    Send-Line $port "$flag,$bytesRead"
    if ($bytesRead -gt 0) {
        $port.Write($buf, 0, $bytesRead)
    }

    # --- Progress bar (in-place) --------------------------------------------
    # bytesRead == 0 means the client read past EOF (stream already exhausted).
    # The "Finished" line was already printed on the previous call; skip it.
    if ($bytesRead -eq 0) { return }

    if (-not $readStart.ContainsKey($channel)) {
        $readStart[$channel] = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $sw = $readStart[$channel]
    $totalSize = $stream.Length
    $elapsed = $sw.Elapsed.TotalSeconds
    if ($elapsed -gt 0) {
        $bps = [math]::Round($stream.Position / $elapsed)
    } else {
        $bps = 0
    }
    $maxWidth = [Console]::WindowWidth - 1

    if ($isLast) {
        $sw.Stop()
        $readStart.Remove($channel)
        $totKB = "{0:N1}" -f ($totalSize / 1024)
        $text = "[READ] Finished 100% ${totKB}KB ${bps}B/s"
        if ($text.Length -gt $maxWidth) { $text = $text.Substring(0, $maxWidth) }
        $padding = ' ' * [math]::Max(0, $maxWidth - $text.Length)
        [Console]::CursorLeft = 0
        [Console]::WriteLine($text + $padding)
    } else {
        if ($totalSize -gt 0) {
            $pct = [math]::Round(($stream.Position / $totalSize) * 100)
        } else {
            $pct = 100
        }
        $barWidth = 20
        $filled   = [math]::Floor($barWidth * $pct / 100)
        $empty    = $barWidth - $filled
        $bar      = ([string][char]0x2588) * $filled + ([string][char]0x2591) * $empty
        $posKB    = "{0:N1}" -f ($stream.Position / 1024)
        $totKB    = "{0:N1}" -f ($totalSize / 1024)
        $text     = "[READ] ch=$channel $bar ${pct}% ${posKB}/${totKB}KB ${bps}B/s"
        if ($text.Length -gt $maxWidth) { $text = $text.Substring(0, $maxWidth) }
        $padding  = ' ' * [math]::Max(0, $maxWidth - $text.Length)
        [Console]::CursorLeft = 0
        [Console]::Write($text + $padding)
    }
}

function Invoke-WriteHandler([System.IO.Ports.SerialPort]$port, [string[]]$fields) {
    if ($fields.Length -lt 4) {
        Write-Host "[WRITE] malformed"
        Send-Line $port "E0"
        return
    }

    $channel = [Convert]::ToInt32($fields[1], 16)
    $byteCount = [int]$fields[2]
    $eoi = $fields[3] -eq "E"

    Write-Host "[WRITE] ch=$channel len=$byteCount eoi=$eoi" -NoNewline

    if (-not $channels.ContainsKey($channel)) {
        Write-Host " -> FAIL (not open)"
        # Drain the raw bytes so the stream stays in sync
        if ($byteCount -gt 0) {
            $discard = New-Object byte[] $byteCount
            $read = 0
            while ($read -lt $byteCount) {
                $read += $port.Read($discard, $read, $byteCount - $read)
            }
        }
        Send-Line $port "E1"
        return
    }

    try {
        # Read raw bytes from serial
        $data = New-Object byte[] $byteCount
        $read = 0
        while ($read -lt $byteCount) {
            $n = $port.Read($data, $read, $byteCount - $read)
            $read += $n
        }

        $stream = $channels[$channel]
        if ($data.Length -gt 0) {
            $stream.Write($data, 0, $data.Length)
        }
        if ($eoi) {
            $stream.Flush()
        }
        Write-Host " -> OK"
        Send-Line $port "OK"
    }
    catch {
        Write-Host " -> FAIL ($_)"
        Send-Line $port "E*"
    }
}

function Invoke-ListHandler([System.IO.Ports.SerialPort]$port) {
    Write-Host "[LIST]" -NoNewline

    try {
        $files = Get-ChildItem -Path $BaseDir -File
        foreach ($f in $files) {
            Send-Line $port "$($f.Name),$($f.Length)"
        }
        Write-Host " -> $($files.Count) file(s)"
    }
    catch {
        Write-Host " -> FAIL ($_)"
        Send-Line $port "E*"
    }
}

# --- Main loop --------------------------------------------------------------

Write-Host "=== C64 IEC File Server - Version $VERSION ==="
Write-Host "Port: $PortName @ $BaudRate 8-N-1"
Write-Host "Base directory: $(Resolve-Path $BaseDir)"
Write-Host "Device ID: $(if ($DevID -ge 0 -and $DevID -le 15) { $DevID } else { 'adapter default' })"
Write-Host ""

function Close-AllChannels {
    foreach ($ch in @($channels.Keys)) {
        try { $channels[$ch].Close() } catch {}
    }
    $channels.Clear()
    $readStart.Clear()
}

$reconnectDelay = 3   # seconds between reconnect attempts

while ($true) {
    $port = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, `
        ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $port.ReadTimeout = -1
    $port.WriteTimeout = 5000
    $port.DtrEnable = $true
    $port.RtsEnable = $true

    try {
        $port.Open()
        Write-Host "Port opened. Waiting for commands... (Ctrl+C to stop)"
        Write-Host ""

        while ($true) {
            $line = Read-Line $port
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            # Detect IEC bus driver reset: startup banner means the MCU rebooted.
            # Close all open channels/streams and drain any stale serial data.
            if ($line -match '<<<.*>>>') {
                Write-Host ""
                Write-Host "*** IEC driver reset detected: $line"
                Close-AllChannels
                # Drain any leftover bytes in the serial buffer
                if ($port.BytesToRead -gt 0) {
                    $port.DiscardInBuffer()
                }
                if ($DevID -ge 0 -and $DevID -le 15) {
                    Send-Line $port "D:$([Convert]::ToString($DevID, 16))"
                    Write-Host "*** Set device ID to $DevID"
                } else {
                    Send-Line $port ""
                }
                Write-Host "*** All channels closed, buffer flushed. Ready."
                Write-Host ""
                continue
            }

            $fields = $line.Split(',')

            if ($fields[0] -ne "R") {
                Write-Host ">> $line"
            }

            switch ($fields[0]) {
                "O" { Invoke-OpenHandler  $port $fields }
                "C" { Invoke-CloseHandler $port $fields }
                "R" { Invoke-ReadHandler  $port $fields }
                "W" { Invoke-WriteHandler $port $fields }
                "L" { Invoke-ListHandler  $port }
                default {
                    Write-Host "[UNKNOWN] cmd='$($fields[0])' - ignoring"
                }
            }
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`nShutting down..."
        Close-AllChannels
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
        break
    }
    catch {
        Write-Host "Port error: $_ - reconnecting in ${reconnectDelay}s..."
    }
    finally {
        Close-AllChannels
        if ($port.IsOpen) {
            try { $port.Close() } catch {}
        }
        $port.Dispose()
    }

    # Wait before attempting to reopen the port, but stay responsive to Ctrl+C
    $waited = 0
    while ($waited -lt $reconnectDelay) {
        Start-Sleep -Milliseconds 500
        $waited += 0.5
    }
    Write-Host "Reconnecting to $PortName..."
}

Write-Host "Port closed. Goodbye."
