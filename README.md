# PN53x

A driver for the PN532/PN533 NFC reader.

Part of the [toit-nfc](https://github.com/milkmansson/toit-nfc) package
family; see that repository for the overall architecture and progress notes.

## Documentation
User manual: https://www.nxp.com/docs/en/user-guide/141520.pdf

## Notes
The chip supports UART, I2C and SPI; this driver implements all three
(`Pn53x.uart`, `Pn53x.i2c`, `Pn53x.spi`).

The firmware does anticollision and ISO-DEP chaining itself, and has a
hardware MIFARE Classic Crypto1 unit, unlike frame-level chips such as the
MFRC522.

### SPI transport

Per application note AN133910: the PN532 shifts data LSB-first on the
wire, which is unusual for an SPI peripheral and which Toit's `spi`
library has no setting for (it only configures CPOL/CPHA via `--mode`),
so every byte is bit-reversed in software on both directions. Before a
response can be read, the host polls a status control byte until the
chip reports it's ready — this replaces the IRQ pin the I2C transport
uses for the same purpose. Create the `spi.Device` with `--mode=0`.

The UART and I2C transports' framing in this driver hasn't changed since
before this ISO-DEP/DES work started, and have the same status: not yet
checked against a real board. SPI is new this session and is the same —
not yet checked against a real board. The bit-reversal and status-poll
logic can't be unit-tested from outside this file, since both are
library-private helpers on a class that itself wraps the SDK's own `spi`
types — the same situation the UART/I2C transports are already in,
which is why none of them have test files.

---

Parts of this repository were developed with the help of [Claude Code](https://claude.com/claude-code).
