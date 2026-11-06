// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import uart
import pn53x show Pn53x

SDA ::= 16
SCL ::= 17
IRQ ::= 34

using-i2c [block]:
  sda := gpio.Pin SDA
  scl := gpio.Pin SCL
  irq := gpio.Pin IRQ

  bus := i2c.Bus --sda=sda --scl=scl --frequency=100_000
  device := bus.device Pn53x.I2C-ADDRESS

  pn53x := Pn53x.i2c device --irq=irq

  block.call pn53x

  device.close
  bus.close
  irq.close
  scl.close
  sda.close

RX ::= 16
TX ::= 17

using-uart [block]:
  rx := gpio.Pin RX
  tx := gpio.Pin TX

  port := uart.Port --rx=rx --tx=tx --baud-rate=115_200

  pn53x := Pn53x.uart port

  block.call pn53x

  port.close
  tx.close
  rx.close

main:
  print "starting"

  using-uart: | pn53x/Pn53x |
    pn53x.on

    print pn53x.miscellaneous.firmware-version

    print "Waiting for cards..."
    while true:
      target := pn53x.poll
      if target:
        print "found target: $target"
      else:
        print "no target found"

      print "powering down for 1000ms"
      pn53x.power.power-down
      sleep --ms=1000
      print "waking up"
      pn53x.power.wakeup

    pn53x.off
