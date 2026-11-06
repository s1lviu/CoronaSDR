# CoronaSDR — RTL-SDR app for iPhone and iPad

CoronaSDR is a free, open-source **software-defined radio (SDR) client for iOS and iPadOS**. Connect to an RTL-SDR receiver through an `rtl_tcp` server on your local network to tune signals, listen to radio, scan frequencies, and explore a live spectrum and waterfall.

The app supports AM, FM stereo, single sideband and CW reception, with experimental **CW Morse code and FT8 decoding** introduced in version 1.1.0. Receiver hardware and an `rtl_tcp` server are required separately.

[![Download CoronaSDR on the App Store](https://img.shields.io/badge/App_Store-Download-0D96F6?logo=apple&logoColor=white)](https://apps.apple.com/app/coronasdr-rtl-sdr-client/id6759222137)
[![CoronaSDR website](https://img.shields.io/badge/Website-coronasdr.pages.dev-0ea5e9)](https://coronasdr.pages.dev/)
[![Source license: GPL-3.0-only](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## Radio receiver features

- **Six reception modes:** AM, narrowband FM (NFM), wideband FM stereo (WFM), upper sideband (USB), lower sideband (LSB), and CW.
- **Live spectrum and waterfall:** Metal-accelerated signal displays, horizontal drag tuning, and adjustable receive bandwidth.
- **Frequency scanning:** scan a station list or a frequency range.
- **Station memories:** save favorites, organize stations with tags, and import or export CSV/TSV station lists.
- **Background listening:** audio playback with Now Playing controls; deep links for listening actions.
- **Receiver controls:** gain, frequency correction in PPM, direct sampling, offset tuning, and bias tee where supported by the receiver and server.
- **Audio controls:** squelch, audio filters, optional audio gain control, and noise blanking.
- **Larger-text layouts:** adaptable spectrum labels, receiver controls, and decoder actions.

## CW Morse code and FT8 decoding

Select **Decode → CW or FT8** on the Radio screen during an active receiver session.

- **CW decoder:** turn a selected Morse code signal into text using a narrow receive channel, with listening pitch independent of the selected carrier, a speed hint, and optional automatic speed tracking.
- **FT8 decoder:** receive messages with a bounded history, message details, and text sharing. Selecting FT8 applies a USB receive profile.
- **Monitoring controls:** mute listening audio while decoding continues in the foreground, or freeze displayed results while reception continues.

Both decoders are **experimental and receive-only**. They pause when the app moves to the background. Some signals and messages may be missed; FT8 reception times are estimates because `rtl_tcp` provides no RF capture timestamps. Recorded-signal results, known decoding gaps, and outstanding physical-device and receiver checks are documented in [CW and FT8 validation](docs/DECODER-VALIDATION.md).

## Connect an RTL-SDR receiver to your iPhone or iPad

### What you need

- An iPhone or iPad running iOS 18 or later.
- An RTL-SDR receiver connected to a computer or other host running an `rtl_tcp` server.
- A suitable antenna or signal input, and a local network connection between the server and your iPhone or iPad.

Available frequencies and receiver-specific controls depend on your hardware and server configuration. Xcode is needed only when building the app from source.

### Get started

1. Connect the RTL-SDR receiver to the server host and start its `rtl_tcp` service.
2. Connect your iPhone or iPad to the same local network and allow CoronaSDR local-network access when prompted.
3. Enter the server's hostname or IP address and TCP port in CoronaSDR, then connect.
4. Choose a frequency, reception mode, and bandwidth, then start listening. Save stations or enable CW/FT8 decoding as needed.

## Repository layout

- `SDRApp/` — Xcode project, Swift packages, and tests
- `site/` — static website deployed to Cloudflare Pages

## Build the iOS app from source

Building requires macOS and Xcode. The project and Swift packages are in [`SDRApp/`](SDRApp/).

Compile without signing:

```bash
cd SDRApp
xcodebuild -project CoronaSDR.xcodeproj -scheme CoronaSDR -sdk iphoneos CODE_SIGNING_ALLOWED=NO -configuration Debug build
```

To install on a physical device, use your Apple development team and a unique bundle identifier:

```bash
cd SDRApp
TEAM_ID=YOUR_TEAM_ID BUNDLE_ID=com.example.coronasdr ./build.sh build
```

Open `SDRApp/CoronaSDR.xcodeproj` in Xcode if you prefer the standard Xcode workflow.

Firebase is optional. Copy `SDRApp/App/SDRApp/Resources/GoogleService-Info.plist.example` to `GoogleService-Info.plist` and add your own Firebase project values only when telemetry is required.

## Decoder tests and validation

Host tests run without a radio or iOS device:

```bash
python3 SDRApp/scripts/test_decoders.py -c release
python3 SDRApp/scripts/test_cft8_safety.py
python3 SDRApp/scripts/benchmark_ft8.py
```

These require macOS, Xcode, Python 3.12+, CMake and RTK. The host harness downloads checksum-verified liquid-dsp 1.7.0 on its first run. Recorded fixtures, coverage, measured limitations and remaining device checks are documented in [Decoder validation](docs/DECODER-VALIDATION.md).

## Contributing

Bug reports and pull requests are welcome. Use [GitHub Issues](https://github.com/s1lviu/CoronaSDR/issues) for bug reports and feature requests, and read the [contribution guide](CONTRIBUTING.md) before submitting changes. Report security issues using the [security policy](SECURITY.md).

## License

The source code in this repository is licensed under the [GNU General Public License v3.0 only](LICENSE).

The official App Store binary is distributed separately by the copyright holder under the applicable App Store terms. This does not limit the GPL rights granted for the source code. Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Copyright © 2026 Silviu (YO6SAY).
