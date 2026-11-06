# PN53x

A driver for the PN532/PN533 NFC reader.

Part of the [toit-nfc](https://github.com/milkmansson/toit-nfc) package
family; see that repository for the overall architecture and progress notes.

## Documentation
User manual: https://www.nxp.com/docs/en/user-guide/141520.pdf

## Notes
The chip supports UART, I2C and SPI. This driver currently implements UART
and I2C; SPI is not yet implemented.

The firmware does anticollision and ISO-DEP chaining itself, and has a
hardware MIFARE Classic Crypto1 unit, unlike frame-level chips such as the
MFRC522.
