# Telemetry Integration

This document covers production telemetry for CoronaSDR:
- Firebase Crashlytics for crash + non-fatal reporting.
- Firebase Performance for latency and DSP timing traces.
- `os.Logger` + signposts for local diagnostics and Instruments.

## 1) Xcode Setup

1. Firebase dependencies are declared in `project.yml`:
   - `FirebaseCore`
   - `FirebaseCrashlytics`
   - `FirebasePerformance`
2. Regenerate project after dependency changes:
   - `xcodegen generate`
3. Create local Firebase config:
   - copy `App/SDRApp/Resources/GoogleService-Info.plist.example`
   - to `App/SDRApp/Resources/GoogleService-Info.plist`
   - fill real values from Firebase Console
4. Build once so Xcode resolves Swift Package dependencies.

`GoogleService-Info.plist` is gitignored on purpose.  
If it is missing, the app runs in local-only telemetry mode (no Firebase upload).

## 2) Runtime Initialization

- Entry point: `App/SDRApp/SDRAppMain.swift`
- Service: `App/SDRApp/SDRAppMain.swift` (`TelemetryService` class)
- Firebase is configured at app startup.
- `PerformanceTrace` reporter is connected to Firebase Performance in `TelemetryService.configure()`.

## 3) Captured Events

### 3.1 Crashlytics

Crashlytics receives:
- crashes (automatic, Firebase handler)
- non-fatal events from app flow:
  - network connection failures
  - audio start failures
  - severe audio underrun incidents
  - debug uncaught exceptions in DEBUG builds

Custom keys set:
- `mode`
- `sample_rate_hz`
- `protocol_type`
- `device_class`
- `app_version`
- `build_number`

### 3.2 Firebase Performance

Trace names:
- `connect_latency`
- `first_audio_latency`
- `retune_latency`
- `dsp_block_processing`

Trace attributes include sanitized context:
- `mode`
- `sample_rate`
- `protocol`
- `device_class`
- operation-specific fields (for example `reason` on retune)

`dsp_block_processing` is sampled (not every block) to keep overhead bounded.

## 4) Redaction Rules

Do not send raw user network identifiers:
- hostnames
- IP addresses
- URLs containing LAN endpoints

`TelemetryService` sanitizes attribute keys and drops fields with `host`, `ip`, or `address`.

## 5) Verification Checklist

1. Launch app with valid Firebase config.
2. Connect to a server and start playback.
3. Trigger retunes and mode changes.
4. Confirm trace names appear in Firebase Performance dashboard.
5. Simulate failure conditions:
   - unreachable host for network failure non-fatal
   - force audio starvation (weak network / aggressive retune) for underrun non-fatal
6. Confirm Crashlytics receives non-fatal entries with sanitized keys only.

## 6) Relevant Files

- `App/SDRApp/SDRAppMain.swift`
- `Packages/SDRSupport/Sources/SDRSupport/PerformanceTrace.swift`
- `App/SDRApp/ViewModels/RadioViewModel.swift`
- `Packages/SDRCoreDSP/Sources/SDRCoreDSP/DSPPipeline.swift`
- `Packages/AudioEngineKit/Sources/AudioEngineKit/SDRAudioEngine.swift`
- `App/SDRApp/SDRAppMain.swift`
