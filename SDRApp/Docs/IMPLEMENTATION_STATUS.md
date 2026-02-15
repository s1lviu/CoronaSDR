# iOS RTL-TCP SDR - Implementation Status

Updated: 2026-02-15  
Reference spec: `ios-rtl_tcp-sdr-implementation-spec.md`

## Legend
- `[x]` Implementat
- `[~]` Parțial implementat
- `[ ]` Neimplementat

## 1) Feature Set V1

### 1.1 Radio + DSP
- `[x]` Conectare `rtl_tcp` cu handshake `RTL0`
- `[x]` Demod: AM / NFM / WFM (mono) / USB / LSB / CW
- `[x]` Squelch AM & NFM
- `[x]` Audio AGC în demodulatoare
- `[x]` DC blocker pe IQ
- `[x]` Gain auto/manual + PPM
- `[x]` Profile sample rate (Low/Medium/High)
- `[x]` Spectrum + waterfall funcțional
- `[~]` Direct sampling auto sub 24 MHz (fără gating pe capabilități tuner)
- `[ ]` Control IQ offset / offset tuning în UI
- `[ ]` Bias-tee control în UI
- `[ ]` Filtre audio HP/LP ajustabile din UI

### 1.2 UX / Produs
- `[x]` Onboarding explicit despre server rtl_tcp
- `[x]` Test Connection (validare header/tuner)
- `[x]` Favorites/memories + tags + import/export CSV/TSV
- `[x]` Tuning: keypad + steps + digit cursor tap + drag tuning + BFO slider
- `[x]` Scan list + range scan (dwell/hold/skip/stop)
- `[x]` Lock Screen controls + Now Playing
- `[x]` Deep links end-to-end (`onOpenURL` -> parse -> action dispatch în Radio)
- `[~]` Accessibility de bază (labels), fără pass complet VoiceOver rotor/Dynamic Type
- `[x]` Crash/performance telemetry producție (Firebase + fallback local-only)

## 2) Tech Stack

- `[x]` SwiftUI + Observation
- `[x]` SwiftData
- `[x]` Network.framework (`NWConnection`, `NWPathMonitor`)
- `[x]` Accelerate (vDSP)
- `[x]` AVFoundation audio engine
- `[x]` Metal waterfall
- `[x]` MediaPlayer lock screen controls
- `[x]` `os.Logger`
- `[x]` liquid-dsp (resampler + demod FM/SSB)
- `[~]` Atomics: folosit `Synchronization.Atomic` (nu `swift-atomics` package)
- `[ ]` `CSV.swift` dependency (se folosește parser custom)
- `[x]` Firebase Crashlytics + Firebase Performance

## 3) Networking

- `[x]` Local network permission în `Info.plist`
- `[x]` Manual host/port workflow
- `[x]` TCP stream loop + separare de DSP
- `[x]` Reconnect exponential backoff + jitter
- `[x]` `NWPathMonitor` pentru rețea
- `[x]` Flush + settle window la retune/rate change

## 4) DSP / Audio / Rendering

- `[x]` Pipeline separat: Network -> IQ buffer -> DSP -> Audio buffer -> callback
- `[x]` Ring buffers lock-free + metrici underrun/overrun
- `[x]` Drift compensation (PI) pe resampler ratio
- `[x]` Mitigare jitter/background: jitter buffers mărite + receive batching TCP + IQ refill hysteresis în DSP
- `[x]` FFT vDSP + Hann + dBFS + smoothing/peak hold
- `[x]` Waterfall Metal cu row updates și scroll shader
- `[x]` Background audio capability
- `[x]` Interruption + route change handling
- `[~]` Fade utilities există, dar nu sunt aplicate explicit la toate tranzițiile retune/mode/rate

## 5) Screens

- `[x]` Onboarding
- `[x]` Main Radio
- `[x]` Stations + search + tags + import/export
- `[x]` Scan
- `[x]` Diagnostics
- `[x]` Settings
- `[x]` Diagnostics funcțional + telemetry backend conectat

## 6) Telemetry, Quality Gates, Testing

- `[x]` Logging categorii `os.Logger` (Network/DSP/Audio/UI/Scan)
- `[x]` `PerformanceTrace` integrat în fluxurile principale + reporter către telemetry backend
- `[x]` Crashlytics non-fatal + crash pipeline
- `[x]` Firebase Performance traces (connect/first-audio/retune/DSP block)
- `[x]` `TELEMETRY.md`
- `[ ]` Test harness deterministic (rtl_tcp replay)
- `[ ]` Suite de teste automată pentru scan/reconnect/dsp/audio
- `[ ]` Documentare rezultate quality gates (60 min/30 min/memory/reconnect<5s)

## 7) Docs & Tools

- `[x]` `ONBOARDING.md`
- `[x]` `PROTOCOLS.md`
- `[x]` `DSP_NOTES.md`
- `[x]` `TELEMETRY.md`
- `[~]` `Tools/mdns_advertiser` există ca folder, dar este gol

## 8) Backlog Prioritar

1. [x] P0 - Telemetry producție: Firebase Crashlytics + Performance + `TELEMETRY.md`.
2. [x] P0 - Deep links end-to-end: conectare `DeepLinkHandler` în `onOpenURL`.
3. P1 - Radio UX avansat: bandwidth control vizibil + HP/LP audio + AGC toggle explicit.
4. P1 - Advanced tuner controls: bias-tee, offset tuning, direct sampling capability checks.
5. P1 - CSV robust parser (`CSV.swift`) sau parser custom corect pentru quoted fields.
6. P2 - Test harness + teste automate + raport quality gates.
