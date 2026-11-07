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

Runs the scan $REPEAT-COUNT times with the ESP32's internal pull-ups
  enabled (no extra hardware needed to test this) and prints each
  pass. A result that varies from pass to pass (showing a different
  subset of your 4 devices each time) is the classic signature of
  marginal signal integrity -- missing or too-weak pull-up resistors,
  a long/noisy bus, or a loose connection -- not a software problem.
  The ESP32's internal pull-ups are "weak" (the SDK's own doc comment
  for $i2c.Bus says so directly) and not reliable at normal/fast bus
  speeds with multiple devices, so if this is still flaky even with
  them enabled, the real fix is a pair of external pull-up resistors
  (common values: 2.2k-4.7k ohm) from SDA and SCL to VCC, sized for
  the bus as a whole, not per device -- if more than one of your 4
  boards already has its own onboard pull-ups, that's also worth
  checking, since multiple parallel pull-ups combine into a stronger
  (lower-resistance) pull-up than any single board's spec assumed.
*/

import gpio
import i2c

SDA ::= 19
SCL ::= 20
REPEAT-COUNT ::= 8

main:
  bus := i2c.Bus --sda=SDA --scl=SCL --frequency=100_000 --pull-up

  REPEAT-COUNT.repeat: | i/int |
    addresses := bus.scan --timeout-ms=200
    if addresses.is-empty:
      print "pass $i: no devices found"
    else:
      line := "pass $i:"
      addresses.do: | address/int |
        note := address == 0x24 ? "(PN532)" : ""
        line += " 0x$(%02x address)$note"
      print line
    sleep --ms=300

  bus.close
