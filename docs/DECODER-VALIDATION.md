# CW / FT8 implementation and validation

Validation date: 2026-11-06. This records observed evidence, not a physical-device release certification.

## Delivered behavior

- Receive-only Off/CW/FT8 selection on the Radio screen. CW selects 500 Hz receive bandwidth; FT8 selects USB, 3.5 kHz bandwidth and zero BFO. Ordinary receiver settings restore on exit unless the user explicitly changed them during decoding. Temporary profiles do not overwrite persisted listening preferences.
- One selected CW carrier, narrow intermediate-rate filtering, independent 300–1200 Hz listening pitch, 5–60 WPM speed hint, optional speed tracking, uncertain-character markers and bounded transcript.
- FT8 standard/nonstandard calls, free text, telemetry, visible unsupported payloads, bounded history, details and sharing. Listening mute leaves foreground decoding active; display freeze leaves reception active. Scanning stops decoding. Backgrounding pauses decoding; a muted receiving session stops on background entry.
- Fixed nominal 12 kHz audio branches before playback drift correction, squelch, optional audio AGC, blanking, tone filters and clipping. USB's internal AGC is disabled while FT8 is selected. A centered CW carrier is protected from the IQ DC remover when no software offset exists.
- Complete I/Q pairs across odd TCP chunks, overflow, settling and flush; atomic generation/index metadata; a continuous decimation grid across arbitrary block sizes. Discontinuities reset decoder history of timing/hash state without silently concatenating reception intervals.
- Serial worker with at most 48,000 queued audio samples / 256 queued blocks. FT8 uses 216,000-sample windows and 36,000-sample hops, at most three passes, 512 candidates per pass, and 160 results. Initial BP decoding uses 25 iterations; bounded retries use 50 iterations and order-two recovery. UI retains 200 FT8 messages / 10,000 CW characters. In-flight results from old configurations are rejected. Overlapping windows are deduplicated by payload, frequency and sample position; later retransmissions remain visible.

The decoder is a small independent `SDRDecoding` module so its actual production code can run in host tests without UIKit. `DecoderAudioPath` remains in `SDRCoreDSP` and uses the same production FIR/resampler as the app. No cloud service, microphone input, transmitter, automated replies or spotting was added.

## Reproduce

Use macOS, Xcode, CMake, Python 3.12+ and RTK. Run from the repository root:

```sh
python3 SDRApp/scripts/test_decoders.py -c release
python3 SDRApp/scripts/test_decoders.py --sanitize address
python3 SDRApp/scripts/test_decoders.py --sanitize thread
python3 SDRApp/scripts/test_cft8_safety.py
python3 SDRApp/scripts/benchmark_ft8.py
```

The first command downloads liquid-dsp v1.7.0, verifies SHA-256 `33c42ebc2e6088570421e282c6332e899705d42b4f73ebd1212e6a11da714dd4`, and builds a separate Mac library. The harness copies production sources into an ignored build directory; it does not substitute decoder or DSP stubs. `--liquid-build PATH` can use an already built native library.

For an installed arm64 iOS simulator, obtain its UDID with `xcrun simctl list devices available`, then run:

```sh
python3 SDRApp/scripts/test_simulator.py --device SIMULATOR_UDID
```

This builds a separate simulator liquid-dsp archive and runs app unit and UI test schemes sequentially. It overrides device-only platform/library settings for that build; the bundled physical-device archive is unchanged. Simulator setup on this machine required downloading a runtime and the missing Metal toolchain component.

Unsigned device build:

```sh
cd SDRApp
xcodegen generate
xcodebuild -project CoronaSDR.xcodeproj -scheme CoronaSDR -sdk iphoneos -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO build
```

## Recorded FT8 evidence

Recordings and original annotations are pinned from [ft8_lib's corpus](https://github.com/kgoba/ft8_lib/tree/9fec6ca39886edbf96f4f5e71edc76da5074e871/test/wav). SHA-256 values and reference-run provenance are in `SDRApp/Tests/DecoderTests/Fixtures/README.txt`. Input is 12 kHz mono PCM; tests append silence to make the 18-second integration window.

| Recording | Original annotations | Before this correction | Current matches | Additional independently reproduced outputs |
|---|---:|---:|---:|---:|
| `191111_110115.wav` | 1 | 0 | 1 | 0 |
| `191111_110130.wav` | 5 | 4 | 5 | 0 |
| `websdr_test1.wav` | 18 | 13 | 17 | 7 |

Newly recovered original annotations: `GJ0KYZ RK9AX MO05`, `TK4LS YC1MRF 73`, `CQ DX Z33Z KN11`, `YO7CGS A41ZZ -11`, `R2ATW IZ0VLL -16`, and `CQ EA1HTF IN52`. Recovery uses generic reliability reprocessing, cancellation of decoded signals, and a 10 ms final timing grid. Expected messages and fixture-specific frequencies are absent from production code.

The busy recording's seven additional outputs are `CQ LZ532PSO`, `R7FE IK4ISR -12`, `CQ IU8DMZ JN70`, `EY8MM YB1BML 73`, `EY8MM EA3NW -15`, `CQ YP4XMAS`, and `CQ F5JQQ JN08`. All seven are independently reproduced by the official standalone **WSJT-X 3.0.2** decoder. Its binary archive is checksum-verified. The reference decodes the original captures and an additional busy-band variant with the first second removed and one second of silence appended, allowing its slot-oriented search to cover later signals. These seven are kept separate from the 17 original-annotation matches.

**Unresolved:** `LZ1CWK DC8VA RR73`, originally annotated near 598 Hz, remains absent. It was also absent in WSJT-X 3.0.2 runs on the original and six shifted recordings and in an independent MIT-licensed ft8mon comparison. That does not prove the annotation is wrong. The original TXT is retained unchanged and the gap is explicit in the tests. Resolving it is a software/corpus investigation; a physical device is not inherently required.

This is not full WSJT-X parity. The reference also produces `SQ5FBI UA9CJM MO09` in the busy recording and `DO2JHE LZ1JZ -13` in the five-annotation recording; these were not recovered by the app. No minimum-SNR or universal false-decode claim follows from this corpus.

Additional isolated experiments with 2,048 candidates, six cancellation/search passes, amplitude-domain likelihoods, and order-three recovery across the least reliable 40 basis bits did not recover those reference differences. The amplitude and order-three variants also lost existing matches. Lowering the synchronization threshold from 10 to 3 with 2,048 candidates also failed to recover the missing reference messages, added two unconfirmed outputs across the corpus, and took 6.37–6.89 seconds per host window in that run. None of those experimental changes is included in production. Their outputs remain in ignored `SDRApp/build/ft8-{candidate,more-passes,likelihood,order-three,low-score}-experiment/results.json`.

Reference outputs are retained in `SDRApp/Tests/DecoderTests/Fixtures/wsjtx-3.0.2-reference.txt`; full logs are in ignored `SDRApp/build/ft8-reference-3.0.2/`. Reference binaries and the experimental ft8mon/FFTW comparison are not linked or copied into the application.

## Automated coverage

Host suite: 26 tests covering arbitrary I/Q and FIR partitions, exact clean CW text at 5/10/20/35/50/60 WPM, startup acquisition above a steady weak receiver carrier, CW automatic tracking near its speed hint with deterministic noise/fading, silence/noise rejection, CW adjacent-channel attenuation and pitch invariance, fixed-rate audio clock/reset/alias rejection, USB image rejection, real recordings through production resampling, FT8 time/frequency offsets, simultaneous messages in noise, supported/unsupported message formats, overlapping-window deduplication, later repeats, oversize-input recovery, stale-configuration rejection, cancellation and stream changes. New regressions require the recovered recordings, reject a truncated frame, exercise two unequal-strength adjacent signals at −100/0/+100 ppm sample-clock offsets, and verify continuity/deduplication across a one-hour system-clock jump.

The optimized, Address Sanitizer and Thread Sanitizer host suites each pass all 26 tests. The C harness passes Address Sanitizer and Undefined Behavior Sanitizer over 200,000 arbitrary 77-bit payloads, invalid pointer/length/capacity cases, silence, nonfinite input, maximum finite float input and 100 noise windows at multiple levels (27.5 minutes of generated input), plus steady tones, a chirp and impulses. Those interference-only inputs produce zero messages.

Synthetic CW is generated independently from Morse durations; FT8 synthetic fixtures reuse the pinned upstream encoder and waveform generator, so round trips alone would not be independent evidence. Recorded fixtures supplement them. These tests do not establish a field false-decode probability, hand-keyed CW error curve or minimum FT8 SNR.

The iPhone 16 simulator (iOS 27.2, build 24B8117) passes all 122 app unit tests, including the existing DSP/audio/network/model regressions and the new decoder controls tests. Both new full-pipeline tests pass: independently generated Morse I/Q through the running CW pipeline, and a recorded FT8 waveform converted to quantized I/Q through the running USB pipeline. The CW test exposed and now guards the initial steady-carrier acquisition issue. Both use the real worker threads, filters, resampler and decoder service.

Release preparation for **1.1.0 (build 9)** reran all 26 optimized host tests (12.524 s) and all 122 app unit tests on the iPhone 16 simulator (11.035 s), with zero failures. The production changes since the sanitizer and interface evidence below are trailing-whitespace/EOF normalization and version metadata only; no decoder behavior changed during release preparation. The three pinned WAV checksums were verified again.

The signed arm64 iOS Release archive and local App Store export for **1.1.0 (9)** succeed. The exported IPA passes `codesign --verify --deep --strict` with access to the Mac's certificate trust store, has an Apple Distribution signature, has `get-task-allow=false`, and is not device-restricted. The initial restricted signature check could not establish certificate trust; the check with trust-store access passed. Export used `-allowProvisioningUpdates` and `manageAppVersionAndBuildNumber=false`, and the embedded version/build were verified. All 69 entries in `release-1.1.0-source-manifest.json` match the release sources/configuration. The local package is `SDRApp/build/Release-1.1.0/CoronaSDR.ipa`, with SHA-256 `4dbb671adbfda188bce488933b552d30298951d6bbfed1c1b18886e27c1876e7`. The same archive was subsequently uploaded to App Store Connect on 2026-11-06 using Xcode with build-number management disabled; Xcode reported upload success and App Store Connect displayed 1.1.0 (9) as Processing. The upload log is `release-1.1.0-upload.log`. This is distribution evidence, not physical-device qualification.

The two interface tests cover FT8/CW/Off selection, disconnected status, help, control reachability, freeze/clear, and a recorded rtl_tcp replay through the actual app network and DSP paths. The test-only server supplies quantized I/Q in paced, deliberately odd-sized chunks and verifies receiver commands. Populated-message details, the system share sheet's Copy action, muted reception stopping after background entry, and clearing/disabling sharing have passed on iPhone 16 and iPad mini (6th generation), including largest-text runs. This does not verify clipboard bytes, physical networking or audio routes.

Screenshot review found unreadable spectrum labels at the largest text size; these now become a readable edge-frequency legend, the span/center summary adapts to the available width, and decoder actions and receiver control rows stack vertically. Fixed-width receiver labels and values expand at accessibility sizes. A new slider-reachability check also exposed the spectrum's drag gesture blocking vertical page scrolling. A directional pan recognizer now rejects vertical movement before taking control. The iPhone test confirms horizontal dragging changes the frequency and vertical scrolling leaves it unchanged while reaching the Range slider. The final iPhone receiver-controls test passes, including reaching the PPM slider. Its final replay also explicitly checks that mute is on before validating background stop. The final iPad controls test and recorded replay also pass, in separate runs. Control test durations were 69.336 s on iPhone and 88.958 s on iPad; final labelled-toggle replay durations were 93.372 s and 93.285 s respectively.

Local evidence is retained in the ignored `SDRApp/build` directory:

| Evidence | File |
|---|---|
| Fresh 1.1.0 optimized host tests, 26 passing | `release-1.1.0-host.log` |
| Address / Thread Sanitizer host tests, 26 passing each | `decoder-host-address.log`, `decoder-host-thread.log` |
| C Address / Undefined Behavior Sanitizer harness | `cft8-safety.log` |
| Fresh 1.1.0 app unit tests, 122 passing | `release-1.1.0-simulator.log` |
| Final iPhone interface methods, both passing in separate runs at largest text | `decoder-ui-iphone-verified.log` (controls), `decoder-ui-iphone-replay-labelled.log` (replay) |
| Final iPad interface methods, both passing in separate runs at largest text | `decoder-ui-ipad-verified.log` (controls), `decoder-ui-ipad-replay-labelled.log` (replay) |
| Signed 1.1.0 Release archive and local App Store package export | `release-1.1.0-archive.log`, `release-1.1.0-export.log` |
| 1.1.0 package signature, profile and SHA-256 | `release-1.1.0-distribution-verification.json`, `release-1.1.0-source-manifest.json` |
| Repeated recorded-window soak | `ft8-soak.json` |
| Inspected final iPhone screenshots | `decoder-iphone-mute-check-screens/` (controls), `decoder-iphone-labelled-final-screens/` (successful replay) |
| Inspected final iPad screenshots | `decoder-ipad-mute-check-screens/` (controls), `decoder-ipad-replay-verified-screens/` (successful replay) |

Both controls logs also contain a failed replay setup. Earlier attempts targeted the mute control at a scroll edge or its unnamed nested switch; the captured value stayed off. Those attempts are not counted as successful background-stop evidence. The final test positions the control visibly, activates the labelled toggle, and explicitly asserts mute is on before proceeding. Direct nested-switch taps did not reliably activate the control in automation; this is retained as a touch-validation limitation, not declared fixed. Physical touch qualification must include the switch thumb as well as its label.

The earlier large-text waterfall Range label wrapping is fixed by allowing the labels their intrinsic width. The decoder's C DSP is optimized in debug builds as well as Release so simulator reception remains usable. Host sanitizers exercise that same optimized C path; the separate C address/undefined harness uses `-O1`.

The final repeated-recording run processes 90 windows after warm-up (30 cycles through all three recordings), with identical decoded output on every cycle. Peak resident memory of the standalone host process was 30,130,176 bytes both after warm-up and at completion. This is a bounded host soak, not a device-memory or energy qualification. The run overlapped other validation work: busy-recording median wall time was 2.405 s, maximum 8.479 s, and median process CPU time 1.782 s. Those measurements must not be presented as a guaranteed three-second processing budget on iPhone.

## Release decision and work that remains

**Do not call this hardware-qualified or claim WSJT-X-equivalent sensitivity.** The original corpus is 23/24 annotated matches, with seven additional independently reproduced messages. One original annotation remains unresolved, and two additional WSJT-X outputs remain missed. These are disclosed software/corpus limits, not checks that require hardware.

### Requires a physical iPhone/iPad

- Sustained operation on the oldest supported device and a representative iPad, with the actual DSP, network, display, and decoder active at the supported sample profiles. Measure decode deadlines, skipped windows, I/Q loss, responsiveness, peak memory, thermal throttling, and battery drain. Host/simulator timings cannot certify this.
- Speaker, wired/USB audio and Bluetooth route changes; phone/Siri/audio interruptions; screen lock, backgrounding and return; silent-session stop behavior under the real OS lifecycle. The simulator replay verifies the app's foreground/background logic only. The existing Bluetooth A2DP failure documented in the 1.0.8 changelog (#15) remains unresolved; this work does not close it.
- Actual local-network permission prompts and denial/recovery, Wi-Fi loss/rejoin and changing networks. Loopback replay and deterministic buffer tests do not measure a real phone/network combination.
- VoiceOver interaction and touch usability on the supported device sizes. Large-text screenshots and automated control activation are narrower evidence than operator accessibility testing.

### Requires a physical receiver/server and RF or controlled RF injection

- Supported tuner and server combinations, real HF/direct-sampling/offset-tuning behavior, gain/AGC/clipping, DC and image interference, oscillator and sample-clock errors. The test server implements the wire protocol; it is not a receiver compatibility result.
- Calibrated end-to-end sensitivity/selectivity measurements and comparison from the same captured input. Recorded and synthetic fixtures can test decoding under crowded signals, fading and drift, but cannot establish the RF performance of a receiver/antenna combination.

### Does not inherently require hardware

- Resolve the remaining corpus/reference differences and broaden independent signal/noise coverage, including recorded hand-keyed/Farnsworth CW, before making stronger decoder-quality claims. Such recordings can be tested on the host; this is not inherently a device requirement.
- Runtime-test the iOS 18 minimum. The installed simulator is iOS 27.2. Attempts to download iOS 18.0 (arm64/universal) and 18.5 (universal) through this Xcode returned “not available.” A compatible simulator runtime/toolchain would satisfy this check; a physical older-OS device is an alternative.
- Complete App Store metadata/privacy declarations and review. Build 1.1.0 (9) has been uploaded successfully; that does not constitute App Store approval or public availability. App Store Connect also reports an updated Apple Developer Program License Agreement that the Account Holder must accept before app submission.

### Intrinsic protocol limits

The receiver stream contains no RF capture timestamps. Local reception time remains an estimate and cannot separate sender clock error, server/network delay or DSP group delay. SNR and transmitter DT remain absent. Callsign hashes can remain unresolved or ambiguous and do not authenticate senders. These limitations are explained in the interface, not silently filled with guessed values.
