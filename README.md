<div align="center">

# CoronaSDR

### RTL-SDR Client for iPhone and iPad

Turn your RTL-SDR dongle into a portable software-defined radio — listen to FM broadcasts, aircraft, marine, amateur radio, weather stations, and more from your iOS device.

[![Website](https://img.shields.io/badge/Website-coronasdr.pages.dev-blue?style=flat-square)](https://coronasdr.pages.dev/)
[![Platform](https://img.shields.io/badge/Platform-iOS%2018.0%2B-lightgrey?style=flat-square&logo=apple)](https://apps.apple.com/app/coronasdr-rtl-sdr-client/id6759222137)
[![Protocol](https://img.shields.io/badge/Protocol-rtl__tcp-green?style=flat-square)](https://osmocom.org/projects/rtl-sdr/wiki)
[![Issues](https://img.shields.io/github/issues/s1lviu/CoronaSDR?style=flat-square)](https://github.com/s1lviu/CoronaSDR/issues)

<a href="https://apps.apple.com/app/coronasdr-rtl-sdr-client/id6759222137">
  <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="50">
</a>

</div>

---

## Requirements

- **iOS 18.0+** on iPhone or iPad
- An **RTL-SDR** dongle connected to an [`rtl_tcp`](https://osmocom.org/projects/rtl-sdr/wiki) server on the same network

## Features

<table>
  <tr>
    <td width="50%">

**Radio & DSP**
- 6 demodulation modes: AM, NFM, WFM, USB, LSB, CW
- Squelch (AM, NFM)
- FM de-emphasis: 50 µs / 75 µs
- Configurable high-pass and low-pass audio filters
- BFO tuning for SSB and CW

</td>
    <td width="50%">

**Spectrum Display**
- Real-time FFT spectrum analyzer
- Waterfall display
- GPU-accelerated rendering via Metal

</td>
  </tr>
  <tr>
    <td>

**Tuning & Control**
- Frequency keypad, step buttons, and drag-to-tune
- Gain (auto/manual), PPM correction
- Direct sampling (Auto, Off, I, Q)
- Offset tuning, bias-tee toggle
- 4 performance profiles: Ultra Low to High sample rate

</td>
    <td>

**Station Management & Scanning**
- Save favorites with tags
- CSV/TSV import and export
- List scan and range scan
- Dwell, hold, and skip via squelch

</td>
  </tr>
  <tr>
    <td>

**Playback & Integration**
- Background audio playback
- Lock screen and Now Playing controls
- Deep link automation via `coronasdr://`

</td>
    <td>

**Diagnostics**
- Live throughput (Mbps)
- IQ and audio buffer fill levels
- Overrun / underrun counters
- Network and audio quality indicators

</td>
  </tr>
</table>

## Getting Started

### 1. Set up your RTL-SDR server

Connect your RTL-SDR dongle to a computer (Linux, macOS, Raspberry Pi, etc.) and start `rtl_tcp`:

```bash
rtl_tcp -a 0.0.0.0 -p 1234 -s 2400000
```

### 2. Connect from CoronaSDR

Open the app, enter the server's IP address and port (`1234`), and tap connect. The built-in connection test will verify everything works.

### 3. Start listening

Pick a mode, tune to a frequency, and you're on the air.

## Running rtl_tcp as a System Service

For a persistent server (e.g. on a Raspberry Pi), create `/etc/systemd/system/rtl_tcp.service`:

```ini
[Unit]
Description=RTL-SDR rtl_tcp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rtl_tcp -a 0.0.0.0 -p 1234 -s 2400000
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Then enable and start it:

```bash
sudo systemctl enable --now rtl_tcp
sudo systemctl status rtl_tcp
```

### Network Tips

- Keep your iPhone/iPad and the server on the **same LAN/subnet**
- Use **wired Ethernet** for the server whenever possible
- At **2.4 MSPS**, IQ throughput is ~4.8 MB/s (~38 Mbps) — make sure your Wi-Fi can handle it

## Deep Links

Automate CoronaSDR using the `coronasdr://` URL scheme. Works from Shortcuts, Safari, or other apps.

| Action | URL | Notes |
|--------|-----|-------|
| Tune | `coronasdr://tune?freq=100000000&mode=WFM` | Tune to 100 MHz in WFM mode |
| Start | `coronasdr://start` | Start playback |
| Stop | `coronasdr://stop` | Stop playback |

**Parameters for `tune`:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `freq` | Yes | Frequency in Hz (`1000` – `4294967295`) |
| `mode` | No | `AM`, `NFM`, `WFM`, `USB`, `LSB`, `CW` (case-insensitive) |

## Things to Listen To

Not sure where to start? Here are some popular frequencies:

| Band | Frequency | Mode | What You'll Hear |
|------|-----------|------|------------------|
| FM Broadcast | 88 – 108 MHz | WFM | Local radio stations |
| Airband | 118 – 137 MHz | AM | Aircraft communications |
| 2m Amateur | 144 – 148 MHz | NFM / USB | Ham radio repeaters and simplex |
| ISS Downlink | 145.800 MHz | NFM | International Space Station voice |
| Marine VHF | 156.800 MHz (Ch 16) | NFM | Maritime distress and calling |
| NOAA Weather | 162.400 – 162.550 MHz | NFM | Weather radio (US) |
| 70cm Amateur | 420 – 450 MHz | NFM | Ham radio UHF activity |
| ADS-B | 1090 MHz | — | Aircraft position data (requires external decoder) |

> **Tip:** Frequencies vary by region. Check your local band plans for amateur radio and public safety allocations.

## Feedback and Bug Reports

Found a bug or have a feature request? Please open an issue:

**[github.com/s1lviu/CoronaSDR/issues](https://github.com/s1lviu/CoronaSDR/issues)**

When reporting a bug, include:

- iPhone/iPad model and iOS version
- RTL-SDR tuner type
- Server command line or service config
- Mode, frequency, and performance profile
- Steps to reproduce with expected vs. actual behavior

## Support the Project

If you enjoy CoronaSDR, consider supporting its development:

[![PayPal](https://img.shields.io/badge/PayPal-Donate-blue?style=flat-square&logo=paypal)](https://www.paypal.com/paypalme/silviustroe)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support-yellow?style=flat-square&logo=buymeacoffee)](https://buymeacoffee.com/silviu)

---

<div align="center">

Made with 📻 by a ham radio enthusiast

</div>
