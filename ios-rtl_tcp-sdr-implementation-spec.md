# iOS RTL-TCP SDR (SwiftUI, iOS 18+) — Implementation Spec (Agent-ready)

> Scop: Aplicație iOS nativă (SwiftUI) care se conectează **LAN-only** la un server `rtl_tcp` (și extensibil la `hfp_tcp`, `rsp_tcp`, etc.), primește IQ în timp real, afișează **spectrum + waterfall**, și demodulează **AM / NFM / WFM / SSB / CW** cu audio stabil și UI modern.  
> Target: **iOS 18+** (pentru SwiftData, Observation, APIs moderne).  
> Priorități: **performanță, stabilitate audio, UX de tuning**, scanning/memories, onboarding clar (evită review-urile negative).

---

## 0) Non-Goals (pentru V1)
- Conexiune USB directă la RTL-SDR (nu e suport iOS standard).
- Internet remote / NAT traversal (LAN-only; VPN e “user provided”).
- Decodoare digitale (ADS-B/AIS/APRS) — pot fi V2/V3.

---

## 1) Feature Set (V1 “better-than-competitor”)

### 1.1 Radio + DSP
- Conectare la `rtl_tcp` (TCP stream IQ).
- Demod: **AM, NFM, WFM (mono), SSB (USB/LSB), CW**.
- Squelch pentru AM & FM.
- Audio AGC (în special pentru AM/airband).
- Filtre audio HP/LP ajustabile.
- DC blocker + IQ offset (elimină DC spike).
- Gain control: auto/manual + slider, plus PPM.
- Multiple sample rates (profile “Low/Med/High” pentru rețea).
- Spectrum + waterfall stabile, fără glitch scroll.

### 1.2 UX / Produs
- Onboarding explicit: “ai nevoie de server rtl_tcp pe Pi/PC”.
- “Connection test” înainte de start.
- Favorite/memories nelimitat + organizare (tag/categorii).
- Import/Export **CSV/TSV** pentru stații.
- Tuning excelent:
  - keypad + steps,
  - selectare cifră + +/-,
  - drag tuning cu accelerație,
  - slider fine tune (BFO) pentru SSB/CW ±1000 Hz.
- Scan:
  - scan list (dwell, hold, squelch-open),
  - range scan (start/end/step).
- Lock Screen controls + Now Playing info.
- Deep links / Custom URL scheme: set frecvență, mod, start/stop.
- VoiceOver / accessibility complet.
- Crash + performance telemetry (minim pentru stabilitate în producție).

---

## 2) Tech Stack (MINIM COD / MAX CALITATE)

### 2.1 Apple Frameworks (obligatorii)
- **SwiftUI** + **Observation** (iOS 18)
- **SwiftData** (persistence)
- **Network.framework** (TCP: `NWConnection`; discovery `NWBrowser`)
- **Accelerate (vDSP/vForce)** (FFT + vector math)
- **AVFoundation** (`AVAudioEngine`, `AVAudioSession`, `AVAudioConverter`)
- **Metal / MetalKit** (waterfall render performant)
- **MediaPlayer** (Lock Screen / Remote Command Center)
- **os.Logger** (logging)

### 2.2 Third-party (obligatorii în acest spec)
- **liquid-dsp** (MIT/X11) – NCO, FIR, decimators, resamplers, PLL, AGC building blocks  
  - IMPORTANT: configurează build să **NU** includă FFTW (nu e necesar pe iOS; FFT pentru UI se face cu vDSP).
- **CSV.swift** (SPM) – import/export CSV/TSV rapid, API simplu pentru V1.
- **Firebase Crashlytics** + **Firebase Performance Monitoring** – crash reporting + traces de performanță.
- **Swift Atomics** (`apple/swift-atomics`) – primitive atomice robuste pentru ring buffer lock-free.

---

## 3) Repo Layout (Swift Package + App)

```
SDRApp/
  CoronaSDR.xcodeproj
  Packages/
    RTLTCPClientKit/          # networking + protocol parsing + discovery
    SDRCoreDSP/               # DSP pipeline + demod + filters + squelch + AGC
    SDRRender/                # FFT -> bins, smoothing, Metal waterfall renderer
    AudioEngineKit/           # audio ring buffer + AVAudioEngine integration
    SDRModels/                # models + SwiftData schema + CSV IO
    SDRSupport/               # logging, firebase telemetry, utils, diagnostics
  App/
    SDRApp/                   # SwiftUI screens + ViewModels + App lifecycle
  Tools/
    mdns_advertiser/          # optional: avahi service example for Pi
  Docs/
    ONBOARDING.md
    PROTOCOLS.md
    DSP_NOTES.md
```

---

## 4) Data Model (SwiftData)

### Entities
- `Station`
  - id: UUID
  - name: String
  - frequencyHz: Int
  - mode: DemodMode (enum)
  - bandwidthHz: Int
  - stepHz: Int
  - squelch: Float
  - gainMode: GainMode
  - gainValue: Float
  - ppm: Float
  - tags: [Tag] (many-to-many, relație SwiftData)
  - lastUsedAt: Date?
  - createdAt, updatedAt
- `Tag`
  - id: UUID
  - name: String (indexed, unique)
- `ServerProfile`
  - id: UUID
  - name: String
  - host: String
  - port: Int
  - protocolType: SDRProtocol (rtl_tcp / hfp_tcp / rsp_tcp / etc.)
  - sampleProfiles: [SampleProfile] (one-to-many, cascade delete)
  - connectionTimeoutMs: Int
  - reconnectPolicy: ReconnectPolicy
- `SampleProfile`
  - id: UUID
  - label: String (Low/Med/High)
  - sampleRate: Int
  - fftSize: Int
  - uiFps: Int
  - audioDecimationTarget: Int (ex: 48k)

### CSV/TSV
- Import/export stații:
  - columns: name, frequencyHz, mode, bandwidthHz, stepHz, squelch, tags
  - acceptă delimitator `,` sau `\t`.

---

## 5) Networking + Discovery

### 5.1 Local Network Permissions
- `NSLocalNetworkUsageDescription`: mesaj clar “Connect to SDR server on your local network”.
- `NSBonjourServices`: `_rtltcp._tcp`, `_hfp._tcp`, `_rsp._tcp` (extensibil).

### 5.2 Discovery (LAN)
- `NWBrowser` browse Bonjour services:
  - prefer `_rtltcp._tcp` (custom)
  - fallback manual add: IP + port.
- Provide `mdns_advertiser` docs for Raspberry Pi (Avahi service file).

### 5.3 TCP Streaming
- Use `NWConnection` with:
  - `.tcp`
  - receive loop with large buffers (ex: 64KB–256KB per receive)
- Absolutely NO DSP on networking queue.
- Networking pushes raw IQ bytes into `IQRingBuffer`.
- Connection resilience:
  - `NWPathMonitor` pentru schimbări de rețea (Wi-Fi drop/rejoin).
  - reconnect cu exponential backoff + jitter (ex: 0.5s -> 1s -> 2s -> 4s, max 8s).
  - reset pipeline state doar după reconnect validat (header `RTL0`).

---

## 6) rtl_tcp Protocol (V1 core)

### 6.1 Handshake / Header
- On connect, read initial header (magic `RTL0` + tuner info).  
- If header invalid -> fail with explicit UI error.

### 6.2 Commands (minimum)
- set frequency (Hz)
- set sample rate
- gain mode (auto/manual)
- set gain (tenths dB)
- ppm correction
- direct sampling (optional toggle; keep UI hidden if unsupported)
- bias-tee (optional; safe default off)

### 6.3 Robust state rules
- App este “source of truth”.
- La orice retune / rate change:
  - flush IQ buffer
  - discard N ms samples (“settle window”, ex 100–250ms) înainte să re-începi audio.

---

## 7) Real-time Pipeline (Performance & Stability)

### 7.1 Strict thread separation
- `NetworkActor`: receive bytes -> IQ ring buffer
- `DSPWorker`: pull IQ blocks -> DSP -> audio blocks + FFT frames
- `RenderWorker`: FFT frames -> bins -> Metal textures (waterfall)
- `AudioCallback`: pull from audio ring buffer only

### 7.2 Ring Buffers (mandatory)
- `IQRingBuffer`: stores bytes or converted int16/float complex; size for jitter: 0.5–2 sec.
- `AudioRingBuffer`: stores Float32 mono; size 0.5–1 sec.
- Use lock-free indices (Swift Atomics). Never allocate in callbacks.
- Track high/low watermarks pentru diagnoză underrun/overrun.

### 7.3 Backpressure policy
- If CPU load high:
  - drop waterfall frames first
  - drop spectrum update rate
  - never block socket receive
  - preserve audio continuity.

### 7.4 Clock Drift Control (mandatory)
- Problema: ceasul audio hardware și rata DSP efectivă nu sunt identice pe sesiuni lungi.
- Soluție:
  - țintește `AudioRingBuffer` fill la setpoint (ex: 50%).
  - control loop lent (PI simplu) ajustează `resamplerRatio` în fereastră mică (ex: ±150 ppm).
  - la deviații mari, aplică fade + re-center buffer fără click.

---

## 8) DSP Implementation (V1)

### 8.1 Input formats
- `rtl_tcp`: typically 8-bit unsigned interleaved IQ.
- Convert block wise:
  - I = (byte - 128) / 128.0
  - Q = (byte - 128) / 128.0

### 8.2 Preprocessing
- DC blocker option:
  - simple IIR high-pass or running mean removal on I/Q.
- IQ Offset option:
  - shift center frequency slightly to move DC spike away.

### 8.3 Channelization
Common block for all modes:
1) NCO mix to baseband (liquid-dsp NCO) OR vectorized mix
2) LPF FIR (liquid-dsp FIR) with configurable bandwidth
3) Decimate to mode-specific intermediate rate

### 8.4 Demod chains (minimum viable high quality)

#### AM
- Envelope: sqrt(I^2 + Q^2) (use vDSP hypot/magnitude)
- DC remove (audio HP)
- AGC tuned for voice (attack fast, decay slow)
- Audio LPF + resample -> 48k

#### NFM
- Quadrature discriminator (fast approximation)
- Deemphasis (50/75 µs selectable)
- Squelch (noise-based post HPF)
- Resample -> 48k

#### WFM (mono)
- Wider IF bandwidth; decimate carefully
- FM demod + deemphasis
- Resample -> 48k

#### SSB (USB/LSB)
- Mix with BFO offset (fine tune slider)
- Sharp audio bandpass (2.1–2.8 kHz adjustable)
- AGC (speech-friendly)

#### CW
- BFO offset + narrow filter (200–800 Hz)
- Optional sidetone

### 8.5 Resampling
- Primary: **liquid-dsp resampler** (single canonical path pentru pipeline determinist).
- Optional fallback: `AVAudioConverter` doar pentru debug/comparison.
- Resamplerul trebuie să suporte ratio fracționar dinamic (controlat de loop-ul de drift).
- Output always 48k Float32 mono.

---

## 9) FFT + Waterfall Rendering

### 9.1 FFT
- Use **vDSP FFT**:
  - window (Hann)
  - FFT size from profile (2048/4096)
  - power spectrum in dBFS
  - smoothing EMA + peak hold

### 9.2 Waterfall (Metal)
- `MTKView` hosted in SwiftUI
- Each FFT frame -> 1-row texture update; scroll via texture coordinate shift (no CPU image shifts).
- Target UI fps from profile (ex 20–30 fps). Never update per DSP block.

---

## 10) Audio Engine

### 10.1 AVAudioSession
- category: `.playback` (și `.playAndRecord` doar dacă adaugi TX)
- mode: `.default`
- `setPreferredSampleRate(48000)` și `setPreferredIOBufferDuration` (ex: 5.3–10.6 ms, în funcție de device)
- support AirPlay routing by default (system handles).

### 10.2 Playback
- `AVAudioEngine` + custom source node pulling from `AudioRingBuffer`.
- Must be click-free on:
  - retune
  - mode switch
  - sample rate change  
  Use fades (2–10ms) + buffer flush.

### 10.3 Lock Screen / Remote Controls
- `MPNowPlayingInfoCenter` updates: station name, frequency, mode
- `MPRemoteCommandCenter`: play/pause, next/prev station, step up/down.

### 10.4 Background Playback (mandatory)
- Enable `UIBackgroundModes` cu `audio` în app capabilities.
- Handle interruptions/route changes (`AVAudioSession.interruptionNotification`, `routeChangeNotification`).
- La revenire din background: resync UI-only layers fără a întrerupe audio path.

---

## 11) UX Screens (SwiftUI)

### 11.1 Onboarding & Connection
- Screen 1: “You need rtl_tcp server on Pi/PC. This app connects over LAN.”
- Screen 2: Discovery list + manual add
- “Test Connection” button: connect -> validate header -> show sample throughput -> success/fail.

### 11.2 Main Radio
- Waterfall + spectrum
- Frequency entry:
  - keypad + step
  - digit select + +/- (fast)
  - drag tuning with inertia
- Mode selector
- Bandwidth pinch + dropdown
- Gain, PPM, squelch, AGC toggles
- Quick presets (FM broadcast, airband, etc.)

### 11.3 Stations / Memories
- List + search + tags
- CSV import/export
- Scan config pages (list scan + range scan)

### 11.4 Diagnostics (pro, reduce support load)
- Throughput Mbps, IQ buffer fill %, audio underruns, dropped frames
- Current sample rate, fft size, CPU estimate
- “Server on Wi-Fi recommended wired” hint.

### 11.5 Accessibility
- Every control labeled.
- VoiceOver rotor for frequency digits.
- Dynamic Type support.

---

## 12) Scanning (V1)

### 12.1 Scan List
- Input: list of stations
- Logic:
  - tune -> wait settle -> check squelch open for dwell window
  - if open: hold N seconds, then resume
  - user can pause/skip.

### 12.2 Range Scan
- Input: start/end/step, mode, bandwidth, squelch
- Same logic with stepping.

Performance: scanning retune must flush buffers and fade audio to avoid clicks.

---

## 13) Telemetry, Logging, Quality Gates

### 13.1 Crashlytics + Firebase Performance Monitoring
- Crashlytics: capture crashes + non-fatal errors (network failures, protocol parse failures, audio underruns severe).
- Firebase Performance: traces pentru:
  - connect latency,
  - first-audio latency,
  - retune latency,
  - DSP block processing time.
- Add custom keys (mode, sampleRate, protocolType, device class), fără IP/host brut.

### 13.2 os.Logger
- categories: Network, DSP, Audio, UI, Scan
- enable debug logs via hidden setting.

### 13.3 Required performance gates (before release)
- Stable playback (no dropouts) at:
  - sample rate 1.024 MS/s on good LAN
  - UI 20 fps waterfall
- 60 min session fără underrun/overrun repetitiv (cu drift compensation activ).
- Memory stable (no growth) in 30 min run:
  - connect + retune frequently
  - scan enabled
- CPU within reason on mid-tier device (iPhone 12+ recommended baseline).
- reconnect automat < 5s după Wi-Fi bounce (în condiții LAN normale).

---

## 14) Implementation Order (Agent Steps)

### Step A — Foundation
1) Create packages + app shell
2) Add SwiftData models + settings store
3) Add Crashlytics + Firebase Performance + os.Logger

### Step B — Networking
1) Implement discovery `NWBrowser`
2) Implement `RTLTCPConnection` with handshake validation
3) Implement command writer (freq, rate, gain, ppm)
4) Implement `IQRingBuffer`
5) Implement reconnect/backoff + path monitor

### Step C — Audio Engine
1) Implement `AudioRingBuffer`
2) Hook `AVAudioEngine` source node pulling audio
3) Add fade in/out utilities
4) Add background playback capability + interruption handling

### Step D — DSP Core
1) IQ conversion + DC blocker
2) Channelizer (NCO + FIR + decimate)
3) AM + NFM demod
4) WFM mono demod
5) SSB USB/LSB + CW + BFO fine tune
6) Squelch + AGC
7) Resampler to 48k + dynamic drift compensation loop

### Step E — FFT + Rendering
1) vDSP FFT pipeline -> bins
2) Metal waterfall renderer
3) SwiftUI wrapper `MTKViewRepresentable`

### Step F — UX + Features
1) Main radio screen with robust tuning controls
2) Stations CRUD + CSV import/export
3) Scan list + range scan
4) Lock screen controls + now playing
5) Deep links
6) Accessibility pass

### Step G — QA & Perf
1) Instruments: Leaks, Allocations, Time Profiler
2) Stress: retune spam, mode switch spam, scan 30 min
3) Stress: Wi-Fi bounce + reconnect recovery tests
4) Validate telemetry dashboards + network profile presets + diagnostics

---

## 15) Acceptance Criteria (V1)

- Connect to `rtl_tcp` on LAN within 2 seconds on good network.
- AM/NFM/WFM/SSB/CW playable with stable audio.
- Waterfall scroll smooth (no stuck frames) at 20 fps profile.
- Mode switch without requiring reconnect (unless protocol limitation) and without crash.
- Favorites unlimited; CSV import/export works with 1k entries.
- Scan list + range scan functional.
- No memory growth > ~10% over 30 min continuous use.
- No audible drift artifacts over 60 min continuous playback.
- App recovers automatically after transient LAN disconnect without force-close.
- Lock Screen controls work while app is in background (audio capability enabled).
- Onboarding prevents “I didn’t know I need server” complaints.

---

## 16) Notes / Pitfalls

- Never do DSP work on network receive queue.
- Never allocate in audio callback.
- Drop UI frames, not audio.
- Keep FFT path separate from demod path.
- Keep one canonical resampling path in production (liquid-dsp), avoid dual behavior drift bugs.
- Control drift via adaptive resampler ratio; fixed ratio will fail in long sessions.
- Ensure liquid-dsp integration doesn’t pull FFTW. On iOS, use vDSP for FFT always.
- Treat server config as the biggest support variable; diagnostic screen is mandatory.

---

## 17) Deliverables

- Xcode project builds iOS 18+.
- Packages compiled with SPM.
- Docs:
  - `ONBOARDING.md` (Pi setup + wired recommendation)
  - `DSP_NOTES.md` (rates, filters, demod math)
  - `PROTOCOLS.md` (rtl_tcp commands supported)
  - `TELEMETRY.md` (Crashlytics + Firebase Performance setup, redaction rules, dashboards)
- Test harness:
  - simulated rtl_tcp stream (file replay) for deterministic DSP tests.
