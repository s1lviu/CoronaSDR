# RTL-TCP Protocol Reference

## Connection

- **Transport**: TCP
- **Default port**: 1234
- **Data format**: Raw 8-bit unsigned interleaved IQ (I0, Q0, I1, Q1, ...)

## Initial Header (12 bytes)

On connect, the server sends a 12-byte header:

| Offset | Size | Description |
|--------|------|-------------|
| 0      | 4    | Magic: `RTL0` (ASCII) |
| 4      | 4    | Tuner type (big-endian uint32) |
| 8      | 4    | Gain count (big-endian uint32) |

### Tuner Types

| Value | Tuner |
|-------|-------|
| 0     | Unknown |
| 1     | E4000 |
| 2     | FC0012 |
| 3     | FC0013 |
| 4     | FC2580 |
| 5     | R820T |
| 6     | R828D |

## Commands (Client -> Server)

Each command is 5 bytes: 1 byte command ID + 4 bytes big-endian parameter.

| ID   | Command | Parameter |
|------|---------|-----------|
| 0x01 | Set frequency | Hz (uint32) |
| 0x02 | Set sample rate | Hz (uint32) |
| 0x03 | Set gain mode | 0=auto, 1=manual |
| 0x04 | Set gain | Tenths of dB (uint32) |
| 0x05 | Set freq correction | PPM (int32 as uint32) |
| 0x06 | Set IF gain | Stage:gain packed |
| 0x07 | Set test mode | 0=off, 1=on |
| 0x08 | Set AGC mode | 0=off, 1=on |
| 0x09 | Set direct sampling | 0=off, 1=I, 2=Q |
| 0x0A | Set offset tuning | 0=off, 1=on |
| 0x0B | Set RTL xtal freq | Hz (uint32) |
| 0x0C | Set tuner xtal freq | Hz (uint32) |
| 0x0D | Set tuner gain by index | Index (uint32) |
| 0x0E | Set bias-tee | 0=off, 1=on |

## Supported Commands in This App (V1)

- Set frequency (0x01)
- Set sample rate (0x02)
- Set gain mode (0x03)
- Set gain (0x04)
- Set freq correction / PPM (0x05)
- Set bias-tee (0x0E)

## Data Stream

After the header, the server continuously sends raw IQ data:
- 8-bit unsigned: each sample byte ranges 0-255
- Interleaved: I, Q, I, Q, ...
- Conversion to float: `(byte - 127.5) / 127.5`

## Typical Sample Rates

| Rate | Bandwidth | Use Case |
|------|-----------|----------|
| 1,024,000 | ~1 MHz | Low bandwidth, reliable on poor networks |
| 2,048,000 | ~2 MHz | Medium bandwidth |
| 2,400,000 | ~2.4 MHz | Maximum stable for RTL-SDR |
