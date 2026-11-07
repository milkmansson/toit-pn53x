// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
A driver for the PN532 and PN533 NFC reader.
*/

import uart
import gpio
import i2c
import spi
import nfc.card-type show CardType
import nfc.reader show Reader ReaderCapabilities Target

abstract class Communication_:
  static HEADER-SIZE_ ::= 5  // Preamble, start code * 2, length, length checksum.
  static FOOTER-SIZE_ ::= 2  // Data checksum and postamble.

  abstract read-frame_ max-size/int -> ByteArray
  abstract write-frame frame/ByteArray

  /**
  # Inheritance
  Note that the Wakeup time depends on the oscillator, but according to
    the User manual (UM0701-02), section 7.2.11, page 100, footnote, it's less than
    2ms when using an appropriate quartz and layout.
  */
  abstract wakeup

  /**
  Reads data from the NFC reader.

  The frame must not have more than $max-data-size data bytes.
  */
  read --max-data-size/int -> ByteArray:
    frame := read-frame_ (HEADER-SIZE_ + max-data-size + FOOTER-SIZE_)

    // Remove header and footer from frame.
    if frame[0] != 0x00 or frame[1] != 0x00 or frame[2] != 0xFF:
      throw "Invalid frame"
    size := frame[3]

    if size == 0: // Ack frame.
      if frame[4] != 0xFF or frame[5] != 0x00:  // Ack frame.
        throw "Invalid frame"
      return #[]

    if size > 0 and frame[4] != 0x100 - size:
      throw "Invalid frame"
    result := frame[5..size + 5]

    dcs := frame[5 + size]
    for i := 0; i < size; i++:
      dcs = (dcs + result[i]) & 0xFF
    if dcs != 0:
      throw "Invalid frame"

    if frame[5 + size + 1] != 0x00:
      throw "Invalid frame"

    return result

  write data/ByteArray:
    header-size := 5
    footer-size := 2
    frame-size := header-size + data.size + footer-size

    frame := ByteArray frame-size

    index := 0
    frame[index++] = 0x00 // Preamble: 1 byte. Equal to 0x00
    frame[index++] = 0x00 // Start code. 2 bytes.
    frame[index++] = 0xFF
    frame[index++] = data.size // Length. 1 byte.
    frame[index++] = 0x100 - data.size // Length checksum. 1 byte.
    assert: index == header-size
    frame.replace index data
    index += data.size

    data-checksum := 0
    for i := 0; i < data.size; i++:
      data-checksum = (data-checksum + data[i]) & 0xFF
    frame[index++] = 0x100 - data-checksum // Data checksum. 1 byte.
    frame[index++] = 0x00 // Postamble. 1 byte.

    write-frame frame

class I2cCommunication_ extends Communication_:
  device_/i2c.Device
  irq_/gpio.Pin?

  constructor .device_ .irq_:
    if irq_: irq_.configure --input

  write-frame frame/ByteArray -> none:
    device_.write frame

  read-frame_ max-size/int -> ByteArray:
    // When reading, the PN532 prefixes the data with a status byte: 0x00
    // means "not ready yet", 0x01 means the real data follows. This is
    // the chip's own I2C protocol regardless of whether IRQ is wired --
    // IRQ (when present) is just a host-side shortcut to avoid polling
    // for it, not something the protocol depends on, so $irq_ is
    // optional: without it, this goes straight to the polling loop
    // below, which already has to handle "not ready yet" either way.
    if irq_:
      to-exception := catch: with-timeout --ms=15_000:
        irq_.wait-for 0
      if to-exception: print "*****************  to_exception: $to-exception $irq_.get"
    data /ByteArray? := null
    for i := 0; i < 100; i++:
      data = device_.read (max-size + 1)
      if data[0] != 0x00: break
      sleep --ms=10
    if data.size != (max-size + 1): print "not expected size $data.size != $max-size + 1"
    if data[0] == 0x00: throw "Unexpected status byte"
    return data[1..]

  wakeup:
    // Do nothing.

class UartCommunication_ extends Communication_:
  port_/uart.Port?

  constructor .port_:

  wakeup:
    // Libnfc claims that this is the wakeup preamble.
    // TODO(florian): find this information in the spec and document it.
    // Found the section: Section 7.2.11.
    port_.out.write #[0x55, 0x55, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

  write-frame frame/ByteArray -> none:
    port_.out.write frame

  read-frame_ max-size/int -> ByteArray:
    // TODO(florian): synchronize on the preamble and start-code.
    // Probably not really necessary, as we don't expect communication errors.

    // Peek into the stream to get the size of the frame.
    frame-data-size := port_.in.peek-byte 3
    if frame-data-size == 0:
      // Ack frame.
      return port_.in.read-bytes 6

    frame-size := Communication_.HEADER-SIZE_ + frame-data-size + Communication_.FOOTER-SIZE_
    return port_.in.read-bytes frame-size

/**
SPI framing for the PN532 (application note AN133910, "PN532 SPI").

Unlike most SPI peripherals, the PN532 shifts data LSB-first on the wire.
  Toit's `spi` library only configures clock polarity/phase (CPOL/CPHA),
  not bit order, so every byte sent or received here is bit-reversed in
  software to compensate ($reverse-bits_).

Before any data exchange, the host must poll a status byte (the
  STATREAD control byte) until the PN532 reports it's ready; this is how
  the chip signals "I have a response for you" in SPI mode, replacing
  the I2C transport's IRQ pin.
*/
class SpiCommunication_ extends Communication_:
  static STATUS-READ_ ::= 0x02
  static DATA-WRITE_ ::= 0x01
  static DATA-READ_ ::= 0x03
  static READY_ ::= 0x01

  device_/spi.Device

  constructor .device_:

  wakeup:
    // Application note AN133910 says to hold NSS (chip select) low for
    // about 1 ms to bring the chip out of deep sleep; a status read
    // does exactly that as a side effect, so it doubles as the wakeup
    // pulse.
    catch: read-status_

  write-frame frame/ByteArray -> none:
    out := ByteArray frame.size + 1
    out[0] = reverse-bits_ DATA-WRITE_
    frame.size.repeat: out[it + 1] = reverse-bits_ frame[it]
    device_.write out

  read-frame_ max-size/int -> ByteArray:
    with-timeout --ms=1000:
      while not read-status_: sleep --ms=1

    out := ByteArray max-size + 1
    out[0] = reverse-bits_ DATA-READ_
    device_.transfer out --read
    result := ByteArray max-size
    max-size.repeat: result[it] = reverse-bits_ out[it + 1]
    return result

  read-status_ -> bool:
    out := #[reverse-bits_ STATUS-READ_, 0x00]
    device_.transfer out --read
    return (reverse-bits_ out[1]) == READY_

  static reverse-bits_ byte/int -> int:
    result := 0
    8.repeat:
      result = (result << 1) | (byte & 1)
      byte >>= 1
    return result

/**
A target found by $Initiator.list-passive-targets.
*/
class Pn53xTarget implements Target:
  pn53x_/Pn53x
  target-number_/int
  uid/ByteArray
  /** The target's SENS_RES (ATQA for ISO 14443 Type A). */
  atqa/ByteArray
  /** The target's SEL_RES (SAK for ISO 14443 Type A). */
  sak/int

  constructor .pn53x_ .target-number_ .uid .atqa .sak:

  /** See $Target.type. */
  type -> int:
    return CardType.from-sak sak uid

  /**
  See $Target.transceive.

  The PN532 firmware always handles the CRC itself for this exchange, so
    $check-crc has no effect here; it exists to satisfy $Target.
  */
  transceive bytes/ByteArray --check-crc/bool=false -> ByteArray?:
    return pn53x_.initiator.data-exchange bytes --target-number=target-number_

  /** See $Target.close. */
  close -> none:
    pn53x_.initiator.deselect --target-number=target-number_

  stringify -> string:
    uid-str := ""
    uid.do: uid-str += "$(%02x it)"
    return "UID: $uid-str - $(CardType.to-string type)"

class Initiator:
  static COMMAND-DATA-EXCHANGE_ ::= 0x40
  static COMMAND-DESELECT_ ::= 0x44
  static COMMAND-LIST-PASSIVE-TARGET_ ::= 0x4A

  pn53x_/Pn53x

  constructor .pn53x_:

  /**
  Polls for passive ISO 14443 Type A targets (including MIFARE) in the
    field.

  Returns up to $max-targets $Pn53xTarget, or an empty list if none
    responded.
  */
  list-passive-targets --max-targets/int=1 -> List:
    if not 1 <= max-targets <= 2: throw "INVALID_ARGUMENT"
    baud-rate-modulation-type := 0x00  // 106 kbps, ISO 14443 Type A / Mifare.

    max-target-data-size := 1  // Target number.
        + 2   // SENS_RES (ATQA).
        + 1   // SEL_RES (SAK).
        + 1   // NFCIDLength.
        + 10  // NFCID (UID). 10 bytes covers the longest (triple-size) UID.
    max-response-size := 1  // NbTg, number of initialized targets.
        + max-targets * max-target-data-size

    // Next bytes could be used to specify the UID of the target to look for.
    response := pn53x_.send-command_ COMMAND-LIST-PASSIVE-TARGET_
        #[max-targets, baud-rate-modulation-type]
        --max-response-size=max-response-size

    nb-targets := response[0]
    index := 1
    return List nb-targets:
      target-number := response[index++]
      atqa := response[index .. index + 2]
      index += 2
      sak := response[index++]
      uid-length := response[index++]
      uid := response[index .. index + uid-length]
      index += uid-length
      // A trailing ATS (for ISO-DEP-capable targets) may follow here; not
      // parsed yet, as ISO-DEP support hasn't landed.
      Pn53xTarget pn53x_ target-number uid atqa sak

  // target_number == 0: deselect all targets.
  deselect --target-number/int -> bool:
    if not 0 <= target-number <= 2: throw "INVALID_ARGUMENT"
    response := pn53x_.send-command_ COMMAND-DESELECT_ #[target-number] --response-size=1
    return response[0] == 0x00

  data-exchange data/ByteArray --target-number/int --max-response-size=-1 -> ByteArray:
    if not 0 <= target-number <= 2: throw "INVALID_ARGUMENT"
    command-data := #[target-number] + data
    response := pn53x_.send-command_ COMMAND-DATA-EXCHANGE_ command-data --max-response-size=(1 + max-response-size)
    status := response[0]
    if status != 0x00: throw (Pn53xException status)
    return response[1..]

class Miscellaneous:
  static COMMAND-DIAGNOSE_ ::= 0x00
  static COMMAND-GET-FIRMWARE-VERSION_ ::= 0x02
  static COMMAND-GET-GENERAL-STATUS_ ::= 0x04
  static COMMAND-SAM-CONFIGURATION_ ::= 0x14

  static SAM-MODE-NORMAL_ ::= 0x01
  static SAM-MODE-VIRTUAL-CARD_ ::= 0x02
  static SAM-MODE-WIRED-CARD_ ::= 0x03
  static SAM-MODE-DUAL-CARD_ ::= 0x04

  pn53x_/Pn53x

  constructor .pn53x_:

  /**
  Configures the SAM (Security Access Module).

  It is also used to set the power mode of the device to normal.

  The timeout is only required for the Virtual Card mode.
  */
  // TODO(florian): the timeout is in 50ms units. It may be null.
  // Should we take `--timeout-ms` instead?
  set-sam-configuration_ mode/int --timeout/int?=null -> none:
    if timeout or mode == SAM-MODE-VIRTUAL-CARD_: throw "UNIMPLEMENTED"
    // In theory we could also take over the P70_IRQ pin, but we don't need that yet.
    data := #[mode]
    pn53x_.send-command_ COMMAND-SAM-CONFIGURATION_ data --response-size=0

  /*
  // TODO(florian): can't find good parameters for this.
  // Also seems to require that the board is powered by 5V.
  /**
  Runs a self-diagnostic test, checking the continuity of the transmission paths of the antenna.

  Returns whether the antenna was detected.
  */
  self-test --antenna/bool threshold/int -> bool:
    if not 0 <= threshold <= 0xFF: throw "INVALID_ARGUMENT"

    if not antenna: throw "INVALID_ARGUMENT"
    ANTENNA-TEST ::= 0x07
    response := send-command_ COMMAND-DIAGNOSE #[ANTENNA-TEST] --response-size=1
    return response[0] == 0x00
  */

  /**
  Runs a diagnostic test, sending $data to the device and checking that the
    data is echoed back.

  The data must have at most 262 bytes.
  */
  self-test --communication-line/bool data/ByteArray -> bool:
    if not communication-line: throw "INVALID_ARGUMENT"
    if data.size > 262: throw "INVALID_ARGUMENT"

    if data.size >= 254: throw "UNIMPLEMENTED"

    COMMUNICATION-LINE-TEST ::= 0x00
    diagnostic-data := #[COMMUNICATION-LINE-TEST] + data
    response := pn53x_.send-command_ COMMAND-DIAGNOSE_ diagnostic-data --response-size=(data.size + 1)
    return diagnostic-data == response

  /**
  Runs a self-diagnosis, checking that the ROM is correct.

  Returns whether the test was successful.
  */
  self-test --rom/bool -> bool:
    if not rom: throw "INVALID_ARGUMENT"
    ROM-TEST ::= 0x01
    response := pn53x_.send-command_ COMMAND-DIAGNOSE_ #[ROM-TEST] --response-size=1
    return response[0] == 0x00

  /**
  Runs a self-diagnosis, checking that the RAM is working correctly.

  Returns whether the test was successful.
  */
  self-test --ram/bool -> bool:
    if not ram: throw "INVALID_ARGUMENT"
    RAM-TEST ::= 0x02
    response := pn53x_.send-command_ COMMAND-DIAGNOSE_ #[RAM-TEST] --response-size=1
    return response[0] == 0x00

  firmware-version -> FirmwareVersion:
    response := pn53x_.send-command_ COMMAND-GET-FIRMWARE-VERSION_ #[] --response-size=4
    return FirmwareVersion response[0] response[1] response[2] response[3]

  general-status -> GeneralStatus:
    min-response-size := 1 // Error code.
        + 1  // Field, indicates if an external RF field is present. (1 or 0).
        + 1  // NbTg, number of targets currently controlled by the PN532 acting as initiator.
        + 1  // SAM status
    max-response-size := min-response-size + 2 * 4  // Up to two target infos.
    response := pn53x_.send-command_ COMMAND-GET-GENERAL-STATUS_ #[] --max-response-size=max-response-size
    if response.size < 4: throw "INVALID_RESPONSE"
    index := 0
    error-code := response[index++]
    field-present := response[index++] != 0
    nb-targets := response[index++]
    if not 0 <= nb-targets <= 2: throw "Unexpected number of controlled targets $nb-targets"
    if response.size < min-response-size + nb-targets * 4: throw "INVALID_RESPONSE"
    target-infos := List nb-targets:
      logical-number := response[index++]
      encoded-bit-rate-reception := response[index++]
      bit-rate-reception/int := ?
      if encoded-bit-rate-reception == 0x00: bit-rate-reception = 106_000
      else if encoded-bit-rate-reception == 0x01: bit-rate-reception = 212_000
      else if encoded-bit-rate-reception == 0x02: bit-rate-reception = 424_000
      else: throw "Unexpected bit-rate value."
      encoded-bit-rate-transmission := response[index++]
      bit-rate-transmission/int := ?
      if encoded-bit-rate-transmission == 0x00: bit-rate-transmission = 106_000
      else if encoded-bit-rate-transmission == 0x01: bit-rate-transmission = 212_000
      else if encoded-bit-rate-transmission == 0x02: bit-rate-transmission = 424_000
      else: throw "Unexpected bit-rate value."
      modulation-type := response[index++]
      TargetInfo logical-number bit-rate-reception bit-rate-transmission modulation-type

    sam-status := SamStatus response[index++]

    return GeneralStatus error-code field-present target-infos sam-status

class Power:
  static COMMAND-POWER-DOWN_ ::= 0x16

  pn53x_/Pn53x

  constructor .pn53x_:

  wakeup:
    // Wakeup the chip so we can communicate with it.
    // It's safe to do this even if the chip is already awake.
    //   Note that the Wakeup time depends on the oscillator, but according to
    // the User manual (UM0701-02), section 7.2.11, page 100, footnote, it's less than
    // 2ms when using an appropriate quartz and layout.
    pn53x_.communication_.wakeup

    if pn53x_.power-mode_ == Pn53x.POWER-MODE-LOW-VBAT_:
      // Switch to normal mode.
      // This is done by sending a SAMConfiguration command.
      // See user manual 141520, Rev. 02. Section 3.1.3.3, page 13.
      pn53x_.miscellaneous.set-sam-configuration_ Miscellaneous.SAM-MODE-NORMAL_
    pn53x_.power-mode_ = Pn53x.POWER-MODE-NORMAL_

  power-down:
    WAKEUP-I2C ::= 0x80
    WAKEUP-GPIO ::= 0x40
    WAKEUP-SPI ::= 0x20
    WAKEUP-UART ::= 0x10
    WAKEUP-RF ::= 0x08
    WAKEUP-INT1 ::= 0x02
    WAKEUP-INT0 ::= 0x01

    wakeup-enable-bits := WAKEUP-I2C | WAKEUP-SPI | WAKEUP-UART

    // The power down command can only have an additional "generate-irq" byte which
    // can be used if $WAKEUP-RF is enabled.

    data := #[wakeup-enable-bits]
    response := pn53x_.send-command_ COMMAND-POWER-DOWN_ data --response-size=1
    if response[0] != 0x00:
      throw (Pn53xException response[0])

    pn53x_.power-mode_ = Pn53x.POWER-MODE-POWER-DOWN_
    // The chip needs ~1ms to go into power down mode during which no command should be sent.
    sleep --ms=1

class Pn53x implements Reader:
  /**
  The I2C address of the PN53x.
  Note that the user manual lists the address as 0x48, which corresponds to the shifted address.
  */
  static I2C-ADDRESS ::= 0x24
  static I2C-MAX-SPEED ::= 400_000

  static POWER-MODE-NORMAL_ ::= 0
  // Only on PN532:
  /**
  The chip is powered down and needs to be woken up using $Communication_.wakeup.
  */
  static POWER-MODE-POWER-DOWN_ ::= 1
  /**
  The chip is powered down and needs to be woken up using $Communication_.wakeup.
  To avoid it going back to sleep, the SAMConfiguration command needs to be sent as well.
  */
  static POWER-MODE-LOW-VBAT_ ::= 2

  static CHIP-PN532_ ::= 0x00
  static CHIP-PN533_ ::= 0x01

  // TODO(florian): test with PN533 as well.
  chip-type_/int ::= CHIP-PN532_

  communication_/Communication_
  reset-pin_/gpio.Pin?

  /**
  The current power mode of the device.

  If null, then the device was not turned on yet (see $on).

  We assume that the device is reset when an instance of this class is created.
    As such, the initial power mode is $POWER-MODE-LOW-VBAT_.

  User manual 141520, Rev. 02. Section 3.1.3.3, page 13.
  */
  power-mode_/int? := null

  miscellaneous_/Miscellaneous? := null
  initiator_/Initiator? := null
  power_/Power? := null

  constructor.uart port/uart.Port --reset/gpio.Pin?=null:
    communication_ = UartCommunication_ port
    reset-pin_ = configure-reset-pin_ reset

  /**
  $irq is optional: the PN532's I2C "ready" status byte (see
    $I2cCommunication_.read-frame_) doesn't actually need it, so this
    works over just SDA/SCL/VCC/GND, at the cost of pure polling
    instead of an IRQ-driven wait for each response.
  */
  constructor.i2c device/i2c.Device --irq/gpio.Pin?=null --reset/gpio.Pin?=null:
    communication_ = I2cCommunication_ device irq
    reset-pin_ = configure-reset-pin_ reset

  /**
  $device should be created with --mode=0 (CPOL=0, CPHA=0), per
    AN133910. See $SpiCommunication_ for the framing details.
  */
  constructor.spi device/spi.Device --reset/gpio.Pin?=null:
    communication_ = SpiCommunication_ device
    reset-pin_ = configure-reset-pin_ reset

  /**
  Configures $pin for output, regardless of how the caller constructed
    it -- $reset_ calls $gpio.Pin.set directly, so the pin needs to
    already be in output mode by the time it gets there.
  */
  static configure-reset-pin_ pin/gpio.Pin? -> gpio.Pin?:
    if pin: pin.configure --output
    return pin

  on -> none:
    reset_
    power.wakeup

  /** See $Reader.off. */
  off -> none:
    power.power-down

  /** See $Reader.capabilities. */
  capabilities -> ReaderCapabilities:
    return ReaderCapabilities
        --no-supports-raw-frames
        --firmware-does-anticollision

  /**
  Polls once for a target in the field.

  The chip's firmware always does a fresh selection, so $new has no effect
    here; it exists to satisfy $Reader.poll.
  */
  poll --new/bool=false -> Target?:
    targets := initiator.list-passive-targets
    if targets.is-empty: return null
    return targets[0]

  /**
  Resets the device if a reset pin was given.
  */
  reset_:
    if reset-pin_:
      reset-pin_.set 0
      sleep --ms=10
      reset-pin_.set 1

    power-mode_ = (chip-type_ == CHIP-PN532_) ? POWER-MODE-LOW-VBAT_ : POWER-MODE-NORMAL_

    // TODO(florian): we are waiting 10ms here, to be sure that the device is ready.
    // We don't need to do this, if the board was powered on earlier and no reset pin
    // was given.
    sleep --ms=10

  miscellaneous -> Miscellaneous:
    if not miscellaneous_: miscellaneous_ = Miscellaneous this
    return miscellaneous_

  initiator -> Initiator:
    if not initiator_: initiator_ = Initiator this
    return initiator_

  power -> Power:
    if not power_: power_ = Power this
    return power_

  send-command_ command/int data/ByteArray --max-response-size/int -> ByteArray:
    frame-data := ByteArray data.size + 2
    frame-data[0] = 0xD4  // Frame identifier (TFI). 0xD4 for system controller to PN532; 0xD5 for responses.
    frame-data[1] = command
    frame-data.replace 2 data
    if power-mode_ != POWER-MODE-NORMAL_:
      communication_.wakeup
    communication_.write frame-data
    read-ack_
    return read-response_ command --max-size=max-response-size

  send-command_ command/int data/ByteArray --response-size/int -> ByteArray:
    response := send-command_ command data --max-response-size=response-size
    if response.size != response-size: throw "INVALID_RESPONSE"
    return response

  read-ack_:
    // An ack-frame doesn't have any data, but we could also receive an
    // error frame which sends us 1 byte.
    ack := communication_.read --max-data-size=0
    if not ack.is-empty:
      // We got an error frame.
      // TODO(florian: extract error code).
      throw "Error frame: $ack"

  read-response_ command/int --max-size/int -> ByteArray:
    // Responses are prefixed by `0xD5` and the command+1 that was sent.
    response-size := max-size + 2
    data := communication_.read --max-data-size=response-size
    if data[0] != 0xD5: throw "Unexpected response to $command: $data"
    if data[1] != command + 1: throw "Unexpected response to $command: $data"
    return data[2..]

class FirmwareVersion:
  ic/int
  version/int
  revision/int
  support/int

  constructor .ic .version .revision .support:

  supports-iso14443-type-a -> bool:
    return support & 0x01 != 0

  supports-iso14443-type-b -> bool:
    return support & 0x02 != 0

  supports-iso18092 -> bool:
    return support & 0x04 != 0

  stringify -> string:
    ic-name/string := ?
    if ic == 0x32:
      ic-name = "PN532"
    else:
      // TODO(florian): Check if PN533 has ic equal to 0x33
      ic-name = "Unknown IC: $ic"

    supports-str := ""
    if supports-iso14443-type-a: supports-str += " ISO14443A"
    if supports-iso14443-type-b: supports-str += " ISO14443B"
    if supports-iso18092: supports-str += " ISO18092"
    return "IC: $ic-name, Version: $version, Revision: $revision, Supports:$supports-str"

class GeneralStatus:
  error-code/int
  field-present/bool
  target-infos/List
  sam-status/SamStatus

  constructor .error-code .field-present .target-infos .sam-status:

  stringify -> string:
    error-string := Pn53xException.error-code-to-string error-code
    return "Error code: $error-string, Field present: $field-present, Target infos: $target-infos, SAM status: $sam-status"

class SamStatus:
  status-bits/int

  constructor .status-bits:

  /**
  Whether a full negative pulse has been detected on the CLAD line.
  */
  negative-pulse-detected -> bool: return status-bits & 0x01 != 0

  /**
  Whether an external RF field has been detected and switched off during or after a transaction.
  */
  external-rf-detected-and-off -> bool: return status-bits & 0x02 != 0
  /**
  Whether a timeout has been detected after SigActIRQ has fell down.
  */
  timeout-after-sig-act-irq -> bool: return status-bits & 0x04 != 0

  /**
  The CLAD line level. High if 1, low if 0.
  */
  clad-line-level -> int: return status-bits >> 7

  stringify -> string:
    return "Negative pulse detected: $negative-pulse-detected, External RF detected and off: $external-rf-detected-and-off, Timeout after SigActIRQ: $timeout-after-sig-act-irq, CLAD line level: $clad-line-level"

class TargetInfo:
  logical-number/int
  bit-rate-reception/int
  bit-rate-transmission/int
  modulation-type/int

  constructor .logical-number .bit-rate-reception .bit-rate-transmission .modulation-type:

  modulation-type-as-string -> string:
    // User manual, section 7.2.3, page 74
    if modulation-type == 0x00:
      return "Mifare, Iso14443-3 Type A, Iso14443-3 Type B, Iso18092 passive 106 kpbs"
    else if modulation-type == 0x10:
      return "FeliCa, Iso18092 passive 212/424 kpbs"
    else if modulation-type == 0x01:
      return "Iso18092 Active mode"
    else if modulation-type == 0x02:
      return "Innovision Jewel tag"
    return "Unknown modulation type"

  stringify -> string:
    return "Logical number: $logical-number, Bit rate reception: $bit-rate-reception, Bit rate transmission: $bit-rate-transmission, Modulation type: $modulation-type-as-string"

class Pn53xException:
  static error-code-to-string code/int -> string:
    code &= 0x3F
    if code == 0x00: return "No error"
    if code == 0x01: return "Time Out"
    if code == 0x02: return "CRC error"
    if code == 0x03: return "Parity error"
    if code == 0x04: return "Collision error"
    if code == 0x05: return "Framing error during Mifare operation"
    if code == 0x06: return "Abnormal bit-collision during bit-wise anticollision at 106 kbps"
    if code == 0x07: return "Communication buffer size insufficient"
    if code == 0x09: return "RF buffer overflow" // Bit BufferOvfl of the register CIO_Error.
    if code == 0x0A: return "RF Field not switched on in time"
    if code == 0x0B: return "RF Protocol error"
    if code == 0x0D: return "Temperature error. Overheating detected."
    if code == 0x0E: return "Internal buffer overflow"
    if code == 0x10: return "Invalid parameter"
    if code == 0x12: return "Operation not supported" // DEP protocol.
    // DEP, Mifare or ISO/IEC14443-4 protocol.
    // Can be
    // - bad Mifare key
    // - bad length of the RF received frame,
    // - incorrect value of PCB or PFB.
    // - invalid or unexpected RF received frame.
    // - NAD or DID incoherence.
    if code == 0x13: return "Data format does not match specification"
    if code == 0x14: return "Mifare - Authentication error"
    if code == 0x23: return "UID check byte is wrong" // ISO/IEC14443-3.
    if code == 0x25: return "Invalid device state" // DEP protocol.
    if code == 0x26: return "Operation not allowed in this configuration"
    // Reasons for the following error:
    // Initiator vs Target, unknown target number, target not in the good state, ...
    if code == 0x27: return "Unacceptable command due to context of the PN532"
    if code == 0x29: return "PN53x configured as target has been released by initiator"
    // PN532 and ISO/IEC14443-3B only:
    // Means that the card has been exchanged with another one.
    if code == 0x2A: return "ID of card doesn't match"
    // PN532 and ISO/IEC14443-3B only:
    if code == 0x2B: return "Card has been removed"
    // In DEP 212/424 kpbs passive:
    if code == 0x2C: return "Mismatch between NFCID3 initiator and target"
    if code == 0x2D: return "Over-current event has been detected"
    if code == 0x2E: return "NAD missing in DEP frame"
    throw "Unknown error code: $code"

  error-code/int

  constructor .error-code:

  stringify -> string:
    result := "Error $error-code - "
    result += error-code-to-string error-code
    return result
