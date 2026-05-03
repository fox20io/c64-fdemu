# ============================================================================
# Test client for c64iec_fs.ps1
# ============================================================================
#
# Usage:
#   1) Start the file server:
#        .\c64iec_fs.ps1 -PortName COM5 -BaseDir d:\c64_files
#
#   2) In ANOTHER PowerShell window, run:
#        .\test_c64iec_fs.ps1 -PortName COM6
#      (COM6 is the other end of the virtual pair if using com0com,
#       or use the same port name if looping back.)
#
#   The script creates a temporary test directory, seeds it with .prg files,
#   and exercises every protocol command.  Results are printed with
#   PASS / FAIL for each test case.
#
# Protocol (raw binary):
#   READ  response: <M|L>,<bytecount>\n  followed by <bytecount> raw bytes
#   WRITE request:  W,<ch>,<bytecount>,<E|C>\n  followed by <bytecount> raw bytes
#   Other commands use plain text responses (OK / E<code>).
#
# Prerequisites:
#   - A virtual serial-port pair (e.g. com0com: COM5 <-> COM6).
#   - The server must be running before you start this script.
#   - Use -SeedDir pointing to the server's BaseDir to auto-create test files.
# ============================================================================

param(
    [string]$PortName  = "COM7",
    [int]$BaudRate     = 115200,
    [string]$SeedDir   = "",          # optional: path to server's BaseDir to seed test files
    [int]$Timeout      = 5000         # ms to wait for each response line
)

# ── Seed test files if requested ──────────────────────────────────────────
if ($SeedDir -ne "") {
    if (-not (Test-Path $SeedDir)) { New-Item -ItemType Directory -Path $SeedDir -Force | Out-Null }

    # small.prg  – 10 bytes
    [System.IO.File]::WriteAllBytes((Join-Path $SeedDir "small.prg"),
        [System.Text.Encoding]::ASCII.GetBytes("HELLO C64!"))

    # exact256.prg – exactly 256 bytes (one full default chunk)
    $buf256 = New-Object byte[] 256
    for ($i = 0; $i -lt 256; $i++) { $buf256[$i] = $i % 256 }
    [System.IO.File]::WriteAllBytes((Join-Path $SeedDir "exact256.prg"), $buf256)

    # multi.prg – 600 bytes (needs multiple chunks)
    $buf600 = New-Object byte[] 600
    for ($i = 0; $i -lt 600; $i++) { $buf600[$i] = $i % 256 }
    [System.IO.File]::WriteAllBytes((Join-Path $SeedDir "multi.prg"), $buf600)

    Write-Host "Seeded test files in $SeedDir"
}

# ── Counters ────────────────────────────────────────────────────────────────
$script:passed = 0
$script:failed = 0
$script:testNum = 0

# ── Helpers ─────────────────────────────────────────────────────────────────

function Send-Cmd([System.IO.Ports.SerialPort]$p, [string]$cmd) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$cmd`n")
    $p.Write($bytes, 0, $bytes.Length)
}

function Send-RawBytes([System.IO.Ports.SerialPort]$p, [byte[]]$data) {
    $p.Write($data, 0, $data.Length)
}

function Receive-Line([System.IO.Ports.SerialPort]$p) {
    $sb   = New-Object System.Text.StringBuilder
    $stop = [DateTime]::UtcNow.AddMilliseconds($Timeout)
    while ([DateTime]::UtcNow -lt $stop) {
        if ($p.BytesToRead -gt 0) {
            $ch = [char]$p.ReadChar()
            if ($ch -eq "`n") { return $sb.ToString() }
            if ($ch -ne "`r") { [void]$sb.Append($ch) }
            $stop = [DateTime]::UtcNow.AddMilliseconds($Timeout)   # reset on activity
        } else {
            Start-Sleep -Milliseconds 5
        }
    }
    return $null   # timeout
}

function Receive-RawBytes([System.IO.Ports.SerialPort]$p, [int]$count) {
    $buf  = New-Object byte[] $count
    $read = 0
    $stop = [DateTime]::UtcNow.AddMilliseconds($Timeout)
    while ($read -lt $count -and [DateTime]::UtcNow -lt $stop) {
        if ($p.BytesToRead -gt 0) {
            $n = $p.Read($buf, $read, [Math]::Min($count - $read, $p.BytesToRead))
            $read += $n
            $stop = [DateTime]::UtcNow.AddMilliseconds($Timeout)   # reset on activity
        } else {
            Start-Sleep -Milliseconds 5
        }
    }
    if ($read -lt $count) {
        Write-Host "  [WARN] Receive-RawBytes: expected $count bytes, got $read" -ForegroundColor Yellow
    }
    if ($read -eq 0) { return ,@() }
    return ,$buf[0..($read - 1)]
}

# Read one chunk: parses "<M|L>,<bytecount>\n" header, then reads raw bytes.
# Returns @{ Flag = "M"|"L"; Data = [byte[]] }
function Receive-Chunk([System.IO.Ports.SerialPort]$p) {
    $header = Receive-Line $p
    if ($null -eq $header) { return $null }
    $parts = $header.Split(',')
    $flag  = $parts[0]
    $count = [int]$parts[1]
    if ($count -gt 0) {
        $data = Receive-RawBytes $p $count
    } else {
        $data = @()
    }
    return @{ Flag = $flag; Data = [byte[]]$data }
}

function Receive-AllLines([System.IO.Ports.SerialPort]$p, [int]$maxLines = 100) {
    $lines = @()
    for ($i = 0; $i -lt $maxLines; $i++) {
        $line = Receive-Line $p
        if ($null -eq $line) { break }
        $lines += $line
    }
    return $lines
}

function Assert-Eq($actual, $expected, [string]$label) {
    $script:testNum++
    if ($actual -eq $expected) {
        Write-Host "  [PASS] #$($script:testNum) $label" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] #$($script:testNum) $label" -ForegroundColor Red
        Write-Host "         expected: '$expected'" -ForegroundColor Yellow
        Write-Host "         actual:   '$actual'"   -ForegroundColor Yellow
        $script:failed++
    }
}

function Assert-True([bool]$cond, [string]$label) {
    $script:testNum++
    if ($cond) {
        Write-Host "  [PASS] #$($script:testNum) $label" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] #$($script:testNum) $label" -ForegroundColor Red
        $script:failed++
    }
}

# ── Open serial port ───────────────────────────────────────────────────────
$port = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, `
    ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$port.ReadTimeout  = $Timeout
$port.WriteTimeout = 5000
$port.DtrEnable    = $true
$port.RtsEnable    = $true

try {
    $port.Open()
    Write-Host "=== C64 IEC - File Server Test Suite ===" -ForegroundColor Cyan
    Write-Host "Port: $PortName @ $BaudRate"
    Write-Host ""

    # ====================================================================
    # TEST GROUP 1: OPEN / CLOSE basics
    # ====================================================================
    Write-Host "--- OPEN / CLOSE ---" -ForegroundColor Cyan

    # 1.1 – Open non-existent file for read -> E3
    Send-Cmd $port "O,0,__nonexistent__.xyz"
    $r = Receive-Line $port
    Assert-Eq $r "E3" "Open non-existent file returns E3"

    # 1.2 – Open malformed (missing fields) -> E0
    Send-Cmd $port "O,0"
    $r = Receive-Line $port
    Assert-Eq $r "E0" "Open with missing filename returns E0"

    # 1.3 – Open small.prg for read on ch 0 -> OK
    Send-Cmd $port "O,0,small.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open small.prg for read returns OK"

    # 1.4 – Close ch 0 -> OK
    Send-Cmd $port "C,0"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Close ch 0 returns OK"

    # 1.5 – Close already-closed channel -> E1
    Send-Cmd $port "C,0"
    $r = Receive-Line $port
    Assert-Eq $r "E1" "Close already-closed ch returns E1"

    # 1.6 – Close malformed -> E0
    Send-Cmd $port "C"
    $r = Receive-Line $port
    Assert-Eq $r "E0" "Close with missing channel returns E0"

    # 1.7 – Open without .prg extension (auto-appended) -> OK
    Send-Cmd $port "O,0,small"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open 'small' (auto-append .prg) returns OK"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # TEST GROUP 2: READ – small file (single chunk)
    # ====================================================================
    Write-Host "--- READ (small file, single chunk) ---" -ForegroundColor Cyan

    Send-Cmd $port "O,0,small.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open small.prg"

    Send-Cmd $port "R,0"
    $chunk = Receive-Chunk $port
    Assert-Eq $chunk.Flag "L" "10-byte file: flag = L (last)"
    Assert-Eq $chunk.Data.Length 10 "10-byte file: got 10 bytes"
    $text = [System.Text.Encoding]::ASCII.GetString($chunk.Data)
    Assert-Eq $text "HELLO C64!" "10-byte file: content matches"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # Read not-open channel -> E1
    Send-Cmd $port "R,0"
    $r = Receive-Line $port
    Assert-Eq $r "E1" "Read on closed channel returns E1"

    # Read malformed -> E0
    Send-Cmd $port "R"
    $r = Receive-Line $port
    Assert-Eq $r "E0" "Read with missing channel returns E0"

    Write-Host ""

    # ====================================================================
    # TEST GROUP 3: READ – exact 256 bytes (boundary)
    # ====================================================================
    Write-Host "--- READ (exact 256-byte boundary) ---" -ForegroundColor Cyan

    Send-Cmd $port "O,0,exact256.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open exact256.prg"

    Send-Cmd $port "R,0"
    $chunk = Receive-Chunk $port
    Assert-Eq $chunk.Data.Length 256 "exact256: got 256 bytes"
    Assert-Eq $chunk.Flag "L" "exact256: flag = L (file is exactly one chunk)"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # TEST GROUP 4: READ – multi-chunk with default size
    # ====================================================================
    Write-Host "--- READ (multi-chunk, default 256) ---" -ForegroundColor Cyan

    Send-Cmd $port "O,0,multi.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open multi.prg (600 bytes)"

    $allData    = New-Object System.IO.MemoryStream
    $chunkCount = 0
    $lastFlag   = ""

    while ($true) {
        Send-Cmd $port "R,0"
        $chunk    = Receive-Chunk $port
        $lastFlag = $chunk.Flag
        if ($chunk.Data.Length -gt 0) {
            $allData.Write($chunk.Data, 0, $chunk.Data.Length)
        }
        $chunkCount++

        if ($lastFlag -eq "L") { break }
        if ($chunkCount -gt 10) { break }   # safety
    }

    $totalBytes = $allData.ToArray()
    Assert-Eq $totalBytes.Length 600 "multi.prg: total bytes = 600"
    Assert-Eq $chunkCount 3 "multi.prg: 3 chunks (256+256+88)"
    Assert-Eq $lastFlag "L" "multi.prg: last flag = L"

    # Verify content integrity
    $ok = $true
    for ($i = 0; $i -lt 600; $i++) {
        if ($totalBytes[$i] -ne ($i % 256)) { $ok = $false; break }
    }
    Assert-True $ok "multi.prg: content integrity check"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # TEST GROUP 5: READ – custom size parameter
    # ====================================================================
    Write-Host "--- READ (custom size parameter) ---" -ForegroundColor Cyan

    # 5.1 – Read small.prg with size=5 -> two chunks of 5 bytes
    Send-Cmd $port "O,0,small.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open small.prg for chunked read"

    Send-Cmd $port "R,0,5"
    $chunk = Receive-Chunk $port
    Assert-Eq $chunk.Data.Length 5 "size=5: first chunk is 5 bytes"
    Assert-Eq $chunk.Flag "M" "size=5: first chunk flag = M (more)"
    $text1 = [System.Text.Encoding]::ASCII.GetString($chunk.Data)
    Assert-Eq $text1 "HELLO" "size=5: first chunk = 'HELLO'"

    Send-Cmd $port "R,0,5"
    $chunk = Receive-Chunk $port
    Assert-Eq $chunk.Data.Length 5 "size=5: second chunk is 5 bytes"
    Assert-Eq $chunk.Flag "L" "size=5: second chunk flag = L (last)"
    $text2 = [System.Text.Encoding]::ASCII.GetString($chunk.Data)
    Assert-Eq $text2 " C64!" "size=5: second chunk = ' C64!'"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # 5.2 – Read small.prg with size=3 -> chunks of 3, 3, 3, 1
    Send-Cmd $port "O,0,small.prg"
    Receive-Line $port | Out-Null

    $allData    = New-Object System.IO.MemoryStream
    $chunkCount = 0
    $lastChunkSize = 0

    while ($true) {
        Send-Cmd $port "R,0,3"
        $chunk = Receive-Chunk $port
        if ($chunk.Data.Length -gt 0) {
            $allData.Write($chunk.Data, 0, $chunk.Data.Length)
        }
        $lastChunkSize = $chunk.Data.Length
        $chunkCount++

        if ($chunk.Flag -eq "L") { break }
        if ($chunkCount -gt 20) { break }
    }

    Assert-Eq $allData.Length 10 "size=3: total = 10 bytes"
    Assert-Eq $chunkCount 4 "size=3: 4 chunks (3+3+3+1)"
    Assert-Eq $lastChunkSize 1 "size=3: last chunk is 1 byte"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # 5.3 – Read with size=1024 (larger than file) -> single chunk
    Send-Cmd $port "O,0,small.prg"
    Receive-Line $port | Out-Null

    Send-Cmd $port "R,0,1024"
    $chunk = Receive-Chunk $port
    Assert-Eq $chunk.Data.Length 10 "size=1024: got all 10 bytes in one chunk"
    Assert-Eq $chunk.Flag "L" "size=1024: flag = L"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # 5.4 – Read multi.prg with size=100 -> 6 chunks
    Send-Cmd $port "O,0,multi.prg"
    Receive-Line $port | Out-Null

    $allData    = New-Object System.IO.MemoryStream
    $chunkCount = 0

    while ($true) {
        Send-Cmd $port "R,0,100"
        $chunk = Receive-Chunk $port
        if ($chunk.Data.Length -gt 0) {
            $allData.Write($chunk.Data, 0, $chunk.Data.Length)
        }
        $chunkCount++

        if ($chunk.Flag -eq "L") { break }
        if ($chunkCount -gt 20) { break }
    }

    Assert-Eq $allData.Length 600 "size=100: total = 600 bytes"
    Assert-Eq $chunkCount 6 "size=100: 6 chunks (100*6)"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # 5.5 – Read with size=0 -> should fall back to default (256)
    Send-Cmd $port "O,0,multi.prg"
    Receive-Line $port | Out-Null

    $allData    = New-Object System.IO.MemoryStream
    $chunkCount = 0

    while ($true) {
        Send-Cmd $port "R,0,0"
        $chunk = Receive-Chunk $port
        if ($chunk.Data.Length -gt 0) {
            $allData.Write($chunk.Data, 0, $chunk.Data.Length)
        }
        $chunkCount++

        if ($chunk.Flag -eq "L") { break }
        if ($chunkCount -gt 20) { break }
    }

    Assert-Eq $allData.Length 600 "size=0 fallback: total = 600 bytes"
    Assert-Eq $chunkCount 3 "size=0 fallback: 3 chunks (uses default 256)"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # 5.6 – Read with non-numeric size -> should fall back to default (256)
    Send-Cmd $port "O,0,multi.prg"
    Receive-Line $port | Out-Null

    $allData    = New-Object System.IO.MemoryStream
    $chunkCount = 0

    while ($true) {
        Send-Cmd $port "R,0,abc"
        $chunk = Receive-Chunk $port
        if ($chunk.Data.Length -gt 0) {
            $allData.Write($chunk.Data, 0, $chunk.Data.Length)
        }
        $chunkCount++

        if ($chunk.Flag -eq "L") { break }
        if ($chunkCount -gt 20) { break }
    }

    Assert-Eq $allData.Length 600 "size=abc fallback: total = 600 bytes"
    Assert-Eq $chunkCount 3 "size=abc fallback: 3 chunks (uses default 256)"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # 5.7 – Mix different sizes across consecutive reads on same file
    Send-Cmd $port "O,0,small.prg"
    Receive-Line $port | Out-Null

    Send-Cmd $port "R,0,3"     # "HEL"
    $c1 = Receive-Chunk $port
    Assert-Eq $c1.Data.Length 3 "mixed sizes: first read (3) = 3 bytes"
    Assert-Eq $c1.Flag "M" "mixed sizes: first flag = M"

    Send-Cmd $port "R,0,2"     # "LO"
    $c2 = Receive-Chunk $port
    Assert-Eq $c2.Data.Length 2 "mixed sizes: second read (2) = 2 bytes"
    Assert-Eq $c2.Flag "M" "mixed sizes: second flag = M"

    Send-Cmd $port "R,0,100"   # " C64!" (5 bytes, less than 100 -> last)
    $c3 = Receive-Chunk $port
    Assert-Eq $c3.Data.Length 5 "mixed sizes: third read (100) = 5 bytes (remaining)"
    Assert-Eq $c3.Flag "L" "mixed sizes: third flag = L"

    $combined = [System.Text.Encoding]::ASCII.GetString($c1.Data + $c2.Data + $c3.Data)
    Assert-Eq $combined "HELLO C64!" "mixed sizes: reassembled content matches"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # TEST GROUP 6: WRITE (raw binary) and read-back
    # ====================================================================
    Write-Host "--- WRITE ---" -ForegroundColor Cyan

    # 6.1 – Write a file on channel 1, then read it back
    $writeData = [System.Text.Encoding]::ASCII.GetBytes("PETSCII RULES")

    Send-Cmd $port "O,1,test_write.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open test_write.prg for write"

    Send-Cmd $port "W,1,$($writeData.Length),E"
    Send-RawBytes $port $writeData
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Write raw data returns OK"

    Send-Cmd $port "C,1"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Close write channel"

    # Read it back
    Send-Cmd $port "O,0,test_write.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open test_write.prg for read"

    Send-Cmd $port "R,0"
    $chunk = Receive-Chunk $port
    $text = [System.Text.Encoding]::ASCII.GetString($chunk.Data)
    Assert-Eq $text "PETSCII RULES" "Read-back content matches written data"
    Assert-Eq $chunk.Flag "L" "Read-back flag = L"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # 6.2 – Write malformed -> E0
    Send-Cmd $port "W,1"
    $r = Receive-Line $port
    Assert-Eq $r "E0" "Write malformed returns E0"

    # 6.3 – Write to not-open channel -> E1 (server drains raw bytes)
    Send-Cmd $port "W,2,2,E"
    $discard = [byte[]](0x41, 0x42)
    Send-RawBytes $port $discard
    $r = Receive-Line $port
    Assert-Eq $r "E1" "Write to closed channel returns E1"

    # 6.4 – Multi-chunk write with C (continue) then E (end)
    Send-Cmd $port "O,1,test_multi_write.prg"
    Receive-Line $port | Out-Null

    $part1 = [System.Text.Encoding]::ASCII.GetBytes("FIRST ")
    $part2 = [System.Text.Encoding]::ASCII.GetBytes("SECOND")

    Send-Cmd $port "W,1,$($part1.Length),C"
    Send-RawBytes $port $part1
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Multi-write chunk 1 (C) returns OK"

    Send-Cmd $port "W,1,$($part2.Length),E"
    Send-RawBytes $port $part2
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Multi-write chunk 2 (E) returns OK"

    Send-Cmd $port "C,1"
    Receive-Line $port | Out-Null

    # Read back
    Send-Cmd $port "O,0,test_multi_write.prg"
    Receive-Line $port | Out-Null

    Send-Cmd $port "R,0"
    $chunk = Receive-Chunk $port
    $text = [System.Text.Encoding]::ASCII.GetString($chunk.Data)
    Assert-Eq $text "FIRST SECOND" "Multi-write read-back matches"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # TEST GROUP 7: LIST
    # ====================================================================
    Write-Host "--- LIST ---" -ForegroundColor Cyan

    Send-Cmd $port "L"
    $lines = Receive-AllLines $port
    Assert-True ($lines.Length -ge 1) "LIST returns at least 1 file entry"

    # Check format: each line should be "filename,size"
    $formatOk = $true
    foreach ($l in $lines) {
        if ($l.Split(',').Length -lt 2) { $formatOk = $false; break }
    }
    Assert-True $formatOk "LIST lines have 'name,size' format"

    Write-Host ""

    # ====================================================================
    # TEST GROUP 8: Virtual directory "$" (CBM-format binary)
    # ====================================================================
    Write-Host "--- Virtual directory (\$) ---" -ForegroundColor Cyan

    Send-Cmd $port "O,0,$"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Open virtual dir listing"

    $allData = New-Object System.IO.MemoryStream
    while ($true) {
        Send-Cmd $port "R,0"
        $chunk = Receive-Chunk $port
        if ($chunk.Data.Length -gt 0) {
            $allData.Write($chunk.Data, 0, $chunk.Data.Length)
        }
        if ($chunk.Flag -eq "L") { break }
    }
    $dirBytes = $allData.ToArray()
    Assert-True ($dirBytes.Length -gt 0) "Virtual dir has content"

    # CBM directory starts with load address 0x01 0x08
    Assert-Eq $dirBytes[0] 0x01 "Virtual dir: load address low = 0x01"
    Assert-Eq $dirBytes[1] 0x08 "Virtual dir: load address high = 0x08"

    # Each line is 32 bytes; first line starts at offset 2.
    # Bytes 4-5 are the line number (header = 0x0000).
    Assert-Eq $dirBytes[4] 0x00 "Virtual dir: header line number low = 0"
    Assert-Eq $dirBytes[5] 0x00 "Virtual dir: header line number high = 0"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    # Open $ on non-zero channel -> E2
    Send-Cmd $port "O,1,$"
    $r = Receive-Line $port
    Assert-Eq $r "E2" "Open \$ on write channel returns E2"

    # Read virtual dir with custom size
    Send-Cmd $port "O,0,$"
    Receive-Line $port | Out-Null

    Send-Cmd $port "R,0,10"
    $chunk = Receive-Chunk $port
    Assert-True ($chunk.Data.Length -le 10) "Virtual dir: custom size=10 returns <= 10 bytes"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # TEST GROUP 9: UNKNOWN command
    # ====================================================================
    Write-Host "--- UNKNOWN command ---" -ForegroundColor Cyan

    # Unknown commands are silently ignored by the server (no response).
    # We just verify the server doesn't crash by sending the next valid command.
    Send-Cmd $port "Z,garbage"
    Start-Sleep -Milliseconds 500

    Send-Cmd $port "O,0,small.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Server still alive after unknown command"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # TEST GROUP 10: Reconnect after port close
    # ====================================================================
    Write-Host "--- Reconnect after port close ---" -ForegroundColor Cyan

    # Close the test-side port to simulate a device disconnect.
    $port.Close()
    Write-Host "  [INFO] Port closed from test side. Waiting for server to detect disconnect..."
    Start-Sleep -Seconds 4   # give the server time to notice and re-enter its reconnect loop

    # Reopen the test-side port.
    $port.Open()
    Write-Host "  [INFO] Port reopened. Verifying server reconnected..."

    # Give the server a moment to call Open() on its side too.
    Start-Sleep -Milliseconds 500

    # Send a simple command and expect a valid response.
    Send-Cmd $port "O,0,small.prg"
    $r = Receive-Line $port
    Assert-Eq $r "OK" "Server reconnected and responds after port re-open"

    Send-Cmd $port "C,0"
    Receive-Line $port | Out-Null

    Write-Host ""

    # ====================================================================
    # SUMMARY
    # ====================================================================
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  PASSED: $($script:passed)" -ForegroundColor Green
    Write-Host "  FAILED: $($script:failed)" -ForegroundColor $(if ($script:failed -gt 0) { "Red" } else { "Green" })
    Write-Host "  TOTAL:  $($script:testNum)"
    Write-Host "==========================================" -ForegroundColor Cyan

    if ($script:failed -gt 0) {
        exit 1
    }
}
catch {
    Write-Host "FATAL: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 2
}
finally {
    if ($port.IsOpen) { $port.Close() }
    $port.Dispose()
    Write-Host "Port closed."
}
