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

#ifndef IECSERIALADAPTERCONFIG_H
#define IECSERIALADAPTERCONFIG_H

// Configuration options for IEC Serial Adapter device implementation.

// Pin definitions for the IEC bus signals. You can change these if you want to
// use different pins on your microcontroller, but make sure to update the wiring
// accordingly.
// NOTE: This implementation uses two ports for controlling IN and OUT signals of
//       the CLK and DATA lines and does not make possible to connect the MCU
//       directly to the IEC bus. If you want to connect directly, you will need
//       to change the pin definitions and wiring to match the standard IEC bus
//       pinout, and also update the IECConfig.h correctly.
// NOTE: The pin numbers here correspond to the Arduino Uno. If you're using a
//       different board (e.g. Mega), you may want to choose different pins that
//       are more convenient for your layout. Just make sure to update the pin
//       definitions in both this header and the main.cpp file where the
//       IECBusHandler is initialized.
#define ADAPTER_PIN_ATN          2
#define ADAPTER_PIN_CLK_IN       3
#define ADAPTER_PIN_DATA_IN      4
#define ADAPTER_PIN_RESET        7

#define ADAPTER_PIN_CLK_OUT      5
#define ADAPTER_PIN_DATA_OUT     6

// Device ID for IEC Serial Adapter device. This is the number that the C64 uses to address
// the device on the IEC bus. The standard IEC device IDs are 8 for the first
// disk drive, 9 for the second, and so on. You can choose any ID from 1 to 15,
// but make sure it doesn't conflict with other devices on your bus (e.g. if you
// have a real disk drive at ID 8, use a different ID for this device).
#define IEC_DEVICE_ID            9

// Size of the buffer used for each read/write operation. Larger sizes may
// improve performance but require more memory on the microcontroller. The IEC
// bus protocol allows up to 255 bytes per transfer, but the Arduino Uno has limited
// RAM, so 128 is a good balance for most users. If you have a microcontroller with
// more RAM (e.g. Mega), you could increase this value for better performance.
#define CHUNK_SIZE              128

// Serial communication settings. The baud rate must match the settings of the host computer
// that will be sending commands to the adapter. 115200 is a common choice for fast
// communication, but you can choose a different baud rate if needed.
#define SERIAL_BAUD_RATE        115200

#endif // IECSERIALADAPTERCONFIG_H