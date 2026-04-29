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

#ifndef IEC_USE_LINE_DRIVERS
// Direct wiring scheme
IECBusHandler iecBus(
  ADAPTER_PIN_ATN,
  ADAPTER_PIN_CLK_IN,
  ADAPTER_PIN_DATA_IN);
#else
// Applying a line driver interface
IECBusHandler iecBus(
  ADAPTER_PIN_ATN,
  ADAPTER_PIN_CLK_IN,
  ADAPTER_PIN_CLK_OUT,
  ADAPTER_PIN_DATA_IN,
  ADAPTER_PIN_DATA_OUT,
  ADAPTER_PIN_RESET);
#endif

IECSerialFile* p_iecFile = nullptr;

void setup()
{
  Serial.begin(SERIAL_BAUD_RATE);
  Serial.setTimeout(5000);

  // Handshake
  Serial.println("<<< IEC Serial Adapter Started >>>");
  String config = Serial.readStringUntil('\n');

  // The PC can specify the device number to use by sending a configuration string like "D:8" (for device number 8).
  // If no valid configuration is received then the default device number defined by IEC_DEVICE_ID will be used.
  if (config.startsWith("D:") && config.length() > 2)
  {
    uint8_t devnr = strtoul(config.substring(2).c_str(), nullptr, 16);
    p_iecFile = new IECSerialFile(devnr);
  }
  else
  {
    p_iecFile = new IECSerialFile();
  }

  iecBus.attachDevice(p_iecFile);
  iecBus.begin();
}

void loop()
{
  iecBus.task();
}