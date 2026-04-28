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

IECSerialFile iecFile;

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

void setup()
{
  Serial.begin(SERIAL_BAUD_RATE);
  Serial.setTimeout(5000);
  iecBus.attachDevice(&iecFile);
  iecBus.begin();

  Serial.println("<<< IEC Serial Adapter Started >>>");
}

void loop()
{
  iecBus.task();
}