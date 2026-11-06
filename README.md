# CoronaSDR

A free, open-source RTL-SDR client for iPhone and iPad. CoronaSDR connects to any `rtl_tcp` server on the local network and provides real-time spectrum, waterfall, scanning, station memory, background audio, and six demodulation modes.

[![App Store](https://img.shields.io/badge/App_Store-Download-0D96F6?logo=apple&logoColor=white)](https://apps.apple.com/app/coronasdr-rtl-sdr-client/id6759222137)
[![Website](https://img.shields.io/badge/Website-coronasdr.pages.dev-0ea5e9)](https://coronasdr.pages.dev/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## Features

- AM, NFM, WFM stereo, USB, LSB, and CW demodulation
- Foreground, receive-only CW text and FT8 message decoding, with independent monitoring mute, bounded history and text export
- Metal-accelerated spectrum and waterfall
- List scanning and range scanning
- Station favorites, tags, and CSV/TSV import/export
- Background audio, Now Playing controls, and deep links
- Gain, PPM, direct sampling, offset tuning, bias tee, and audio filters
- Optional Firebase Crashlytics and Performance telemetry

## Requirements

- Xcode 16 or newer
- iOS 18 or newer
- An RTL-SDR device connected to an `rtl_tcp` server

## Repository layout

- `SDRApp/` — Xcode project, Swift packages, and tests
- `site/` — static website deployed to Cloudflare Pages

## Build

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

## Decoder validation

Select **Decode → CW or FT8** on the Radio screen. CW selects a narrow channel and provides listening pitch and speed controls. FT8 selects USB and collects overlapping audio windows. Reception times are estimates because `rtl_tcp` supplies no capture timestamps. Both decoders require an active receiver session and pause in the background.

Host tests run without a radio or iOS device:

```bash
python3 SDRApp/scripts/test_decoders.py -c release
python3 SDRApp/scripts/test_cft8_safety.py
python3 SDRApp/scripts/benchmark_ft8.py
```

These require macOS, Xcode, Python 3.12+, CMake and RTK. The host harness downloads checksum-verified liquid-dsp 1.7.0 on its first run. Recorded fixtures, coverage, measured limitations and remaining device checks are documented in [Decoder validation](docs/DECODER-VALIDATION.md).

## Contributing

Bug reports and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes. Security issues should follow [SECURITY.md](SECURITY.md).

## License

The source code in this repository is licensed under the [GNU General Public License v3.0 only](LICENSE).

The official App Store binary is distributed separately by the copyright holder under the applicable App Store terms. This does not limit the GPL rights granted for the source code. Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Copyright © 2026 Silviu (YO6SAY).
