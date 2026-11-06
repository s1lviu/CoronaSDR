# Changelog

All notable user-facing changes are documented here.

## [1.1.0] - Release candidate

### Added and fixed

- Added foreground CW text decoding and FT8 receive decoding, monitoring mute, result details, freeze-on-scroll and text sharing.
- Added CW channel filtering with listening pitch independent of the selected carrier.
- Preserved I/Q alignment across arbitrary network chunks, overruns and settling windows, and fixed decimation timing across block boundaries.
- Added fixed-rate decoder audio independent of speaker drift correction and audio effects, with bounded worker queues and interruption recovery.
- Added recorded and synthetic decoder tests, C memory-safety checks and decoder controls tests. FT8 sensitivity and physical-device limits are documented in `docs/DECODER-VALIDATION.md`.
- Improved FT8 recovery with bounded reliability reprocessing, decoded-signal cancellation and finer residual timing. Original annotated recording coverage improved from 17/24 to 23/24; the unresolved annotation and additional reference differences are documented.
- Fixed large-text spectrum frequency labels, receiver controls and decoder actions, and optimized the decoder's debug-build processing path.
- Allowed vertical page scrolling over the spectrum while retaining horizontal drag tuning.
- Added recorded rtl_tcp replay UI coverage and repeated-decoding measurements without a physical receiver.

### Known limits

- FT8 recovers 23 of 24 original corpus annotations; one annotation and two additional WSJT-X reference outputs remain unresolved. This is not WSJT-X sensitivity parity.
- Physical-device performance, audio routes, accessibility and receiver/RF qualification remain pending. The existing Bluetooth A2DP issue (#15) remains open.
- Runtime testing at the iOS 18 minimum and App Store Connect validation remain pending. The release candidate has not been published or submitted to the App Store.

## [1.0.8] - 2026-10-20

### Fixed

- Corrected waterfall frequency alignment on Medium and High processing profiles and at fractional zoom levels, preserving narrow signal peaks across the full span.
- Corrected remote Play and Pause commands so repeated commands no longer toggle playback.

### Added

- Added audio output diagnostics for routes, session and graph formats, engine state, buffer demand, and underruns, with logs for playback commands, interruptions, and route changes.
- Added regression tests for waterfall resampling, playback controls, and audio buffer statistics.

### Known issues

- The Bluetooth A2DP playback failure reported in #15 remains under investigation. This release adds diagnostics to collect evidence from affected devices.

## [1.0.7] - 2026-08-29

### Fixed

- Corrected WFM stereo pilot phase recovery.
- Expanded WFM stereo decoder regression coverage.

### Changed

- Published the complete source code under GPL-3.0-only.
- Combined the application and Cloudflare Pages website in one repository.
- Added contributor, security, licensing, and release documentation.

## [1.0.6] - 2026-06-12

### Fixed

- Corrected WFM stereo AGC image collapse.

## [1.0.5] - 2026-06-11

### Fixed

- Prevented the audio engine from crashing during stereo startup.

## [1.0.4] - 2026-06-10

### Added

- Added WFM stereo demodulation.
- Added a frequency input clear button.

### Fixed

- Corrected the station CSV export dialog.
