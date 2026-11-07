// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Scans the I2C bus for responding addresses -- a first diagnostic step
  before trying to talk to the PN532 specifically. `Pn53x.I2C-ADDRESS`
  (0x24) should show up in the result if the PN532 is wired correctly
  and awake; if it doesn't, that's a wiring/power/pull-up problem, not
  a driver problem -- nothing in `toit-pn53x` needs fixing until this
  passes.
*/

import gpio
import i2c

SDA ::= 19
SCL ::= 20

main:
  bus := i2c.Bus --sda=SDA --scl=SCL --frequency=100_000

  print "Scanning..."
  addresses := bus.scan --timeout-ms=200
  if addresses.is-empty:
    print "No devices found at all -- check wiring (SDA/SCL not swapped,"
    print "common ground, pull-ups present) and that something is powered."
  else:
    addresses.do: | address/int |
      note := address == 0x24 ? "  <-- PN532" : ""
      print "0x$(%02x address)$note"

  bus.close
