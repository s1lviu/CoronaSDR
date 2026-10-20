# Changelog

All notable user-facing changes are documented here.

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
