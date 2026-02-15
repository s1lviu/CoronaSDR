# SDR over TCP (iOS)

SwiftUI iOS app for connecting to `rtl_tcp` SDR servers over LAN, processing IQ data, and rendering a live spectrum/waterfall.

## Repository Layout

- `SDRApp/` — iOS app workspace (Xcode project + Swift package modules)
- `SDRApp/Packages/` — local modular packages (`RTLTCPClientKit`, `SDRCoreDSP`, `SDRRender`, `AudioEngineKit`, `SDRModels`, `SDRSupport`, `CLiquidDSP`)
- `SDRApp/Docs/` — protocol, DSP notes, and onboarding docs
- `ios-rtl_tcp-sdr-implementation-spec.md` — implementation specification

## Requirements

- Xcode 16+
- iOS 18+ deployment target
- `rtl_tcp` server reachable on local network

## Build

From repo root:

```bash
cd SDRApp
./build.sh build
```

Optional signing override (if needed for your team):

```bash
cd SDRApp
TEAM_ID=<YOUR_TEAM_ID> CODE_SIGN_IDENTITY="Apple Development" ./build.sh build
```

## Open in Xcode

Open `SDRApp/CoronaSDR.xcodeproj` and run target `CoronaSDR` on a physical device.

## Notes

- `CLiquidDSP/lib/libliquid.a` is a local static dependency used by `SDRCoreDSP`.
- If you need to rebuild it, use `SDRApp/Tools/build_liquid_ios.sh`.
- Firebase local config is not committed: copy `SDRApp/App/SDRApp/Resources/GoogleService-Info.plist.example` to `SDRApp/App/SDRApp/Resources/GoogleService-Info.plist` for local Firebase upload.
