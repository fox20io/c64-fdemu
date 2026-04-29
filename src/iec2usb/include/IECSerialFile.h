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

#ifndef IECSERIALFILE_H
#define IECSERIALFILE_H

#include <Arduino.h>
#include <IECSerialAdapterConfig.h>
#include <IECFileDevice.h>
#include <IECBusHandler.h>

/// @brief This class implements an IEC file device that communicates with a host
/// computer over the serial port. The host computer can send commands to open
/// files, read/write data, and close files on the IEC bus. The device translates
/// these commands into serial messages and waits for responses from the host.
class IECSerialFile : public IECFileDevice
{
 public: 
  IECSerialFile(uint8_t devnr = IEC_DEVICE_ID);

 protected:
  virtual void    begin();
  virtual bool    open(uint8_t channel, const char *name, uint8_t nameLen);
  virtual uint8_t read(uint8_t channel, uint8_t *buffer, uint8_t bufferSize, bool *eoi);
  virtual uint8_t write(uint8_t channel, uint8_t *buffer, uint8_t n, bool eoi);
  virtual void    close(uint8_t channel);

private:
  uint8_t   _responseBuffer[CHUNK_SIZE];
  uint16_t  _bufferDataLength = 0;
  uint16_t  _bufferPointer = 0;
  bool      _isEOI = false;
  bool      _waitingForOpenResponse = false;

private:
  uint8_t   LoadNextChunk(uint8_t channel);
};

#endif // IECSERIALFILE_H