// -----------------------------------------------------------------------------
// Copyright (C) 2026 Norbert Laszlo
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software Foundation,
// Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
// -----------------------------------------------------------------------------

#include <Arduino.h>
#include <IECSerialAdapterConfig.h>
#include <IECSerialFile.h>

IECSerialFile::IECSerialFile() : IECFileDevice(IEC_DEVICE_ID)
{
}

void IECSerialFile::begin()
{
    IECFileDevice::begin();
}

bool IECSerialFile::open(uint8_t channel, const char *name, uint8_t nameLen)
{
    Serial.print("O,");
    Serial.print(channel, HEX);
    Serial.print(",");
    Serial.write((const uint8_t *)name, nameLen);
    Serial.println();

    _bufferPointer = 0;
    _bufferDataLength = 0;
    _isEOI = false;
    _waitingForOpenResponse = true;

    return true;
}

uint8_t IECSerialFile::LoadNextChunk(uint8_t channel)
{
    // Consume the deferred OPEN response before first read
    if (_waitingForOpenResponse)
    {
        _waitingForOpenResponse = false;
        String openResponse = Serial.readStringUntil('\n');
        openResponse.trim();
        if (!openResponse.startsWith("OK"))
        {
            _isEOI = true;
            return 0;
        }
    }

    // Request next chunk
    Serial.print("R,");
    Serial.print(channel, HEX);
    Serial.print(",");
    Serial.println(CHUNK_SIZE);

    // Read header line: <M|L|E...>,<bytecount>\n
    String header = Serial.readStringUntil('\n');
    header.trim();

    if (header.length() == 0 || header.charAt(0) == 'E')
    {
        _isEOI = true;
        return 0;
    }

    int commaIndex = header.indexOf(',');
    if (commaIndex < 0)
    {
        _isEOI = true;
        return 0;
    }

    _isEOI = (header.charAt(0) == 'L');
    _bufferPointer = 0;

    // Parse byte count from header
    uint8_t byteCount = (uint8_t)header.substring(commaIndex + 1).toInt();
    if (byteCount > CHUNK_SIZE)
        byteCount = CHUNK_SIZE;

    // Read raw bytes directly into buffer
    uint8_t bytesRead = 0;
    while (bytesRead < byteCount)
    {
        int b = Serial.read();
        if (b < 0)
        {
            // Timeout — wait a bit and retry
            if (Serial.available() == 0)
            {
                unsigned long start = millis();
                while (Serial.available() == 0 && (millis() - start) < 5000)
                    ;
                if (Serial.available() == 0)
                    break; // hard timeout
            }
            continue;
        }
        _responseBuffer[bytesRead++] = (uint8_t)b;
    }

    return bytesRead;
}

uint8_t IECSerialFile::read(uint8_t channel, uint8_t *buffer, uint8_t bufferSize, bool *eoi)
{
    uint8_t dataLen = 0;

    while (dataLen < bufferSize)
    {
        if (_bufferPointer >= _bufferDataLength)
        {
            _bufferDataLength = LoadNextChunk(channel);

            if (_bufferDataLength == 0)
            {
                break;
            }
        }

        uint8_t available = _bufferDataLength - _bufferPointer;
        uint8_t needed = bufferSize - dataLen;
        uint8_t toCopy = min(available, needed);

        for (uint8_t i = 0; i < toCopy; i++)
        {
            buffer[dataLen++] = _responseBuffer[_bufferPointer++];
        }
    }

    *eoi = _isEOI && (_bufferPointer >= _bufferDataLength);
    
    return dataLen;
}

uint8_t IECSerialFile::write(uint8_t channel, uint8_t *buffer, uint8_t n, bool eoi)
{
    // Header: W,<ch>,<bytecount>,<eoi>\n
    Serial.print("W,");
    Serial.print(channel, HEX);
    Serial.print(",");
    Serial.print(n);
    Serial.print(",");
    Serial.println(eoi ? "E" : "C");

    // Raw data bytes
    if (n > 0)
    {
        Serial.write(buffer, n);
    }

    // Wait for server acknowledgement
    String response = Serial.readStringUntil('\n');
    response.trim();
    if (response.startsWith("OK"))
        return n;
    return 0;
}

void IECSerialFile::close(uint8_t channel)
{
    Serial.print("C,");
    Serial.print(channel, HEX);
    Serial.println();

    // Consume the server's response so it doesn't pollute the next command
    String response = Serial.readStringUntil('\n');
    (void)response;
}