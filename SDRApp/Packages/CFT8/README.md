# FT8 receiver integration

Source: [kgoba/ft8_lib](https://github.com/kgoba/ft8_lib/tree/9fec6ca39886edbf96f4f5e71edc76da5074e871), pinned at `9fec6ca39886edbf96f4f5e71edc76da5074e871`.

`vendor/ft8` contains the upstream C sources and headers; `vendor/fft` contains upstream's KISS FFT copy. The former is MIT; the latter is BSD-3-Clause. Full notices are retained alongside sources and included in the application under Settings → Decoder acknowledgements.

Local upstream edits:

- Removed trailing whitespace and redundant blank lines at end of files; source logic and license wording are unchanged by this formatting normalization.

- `ft8/decode.c`: search complete frames over the supplied window, beginning at nonnegative offsets. This avoids forming pointers before the waterfall buffer and permits rolling acquisition without depending on receiver UTC.
- `ft8/decode.c`, `ft8/ldpc.c/.h`: bounded likelihood retries and best-iteration posterior reliability for order-two ordered-statistics recovery; guard zero-variance likelihoods. The nearest codeword is selected by channel-weighted distance before CRC validation. CRC is not used to search for a convenient payload.
- `ft8/debug.h`: `CORONA_FT8_NO_LOG` disables received-text logging in every build configuration.
- `ft8/message.c`: initialize temporary message fields and do not concatenate fields when unpacking fails.
- `fft/COPYING`: restore the BSD-3-Clause license text referenced by the upstream headers, from KISS FFT's LICENSES/BSD-3-Clause.

`CFT8.c` is CoronaSDR's wrapper: checked allocation, bounded 18-second input and candidate search, cancellation, finite-input validation, FFT overflow protection, CRC/parity validation through upstream, exact payload extraction and collision-aware bounded callsign hashing. Decoder and reset run serially; only cancel may run concurrently. Callsign hashes are forgotten on a stream/configuration discontinuity. Hash matches are not sender authentication.

The FFT uses 7,680 points, four frequency substeps and four time substeps in the first two passes. The final residual pass uses sixteen time substeps (10 ms). Each pass examines at most 512 candidates; there are at most three passes and 160 results. BP uses 25 initial iterations, then two scaled 50-iteration retries. Order-two recovery examines a fixed 4,187 codewords per invocation. All output still requires valid parity and CRC. Search covers 200–3000 Hz, including the entire eight-tone footprint, and checks that the candidate's 12.64-second frame fits in the input.

`recovery.c` implements the bounded reliability search. `subtraction.c` reconstructs only already-decoded payloads using FT8 GFSK shaping, fits their timing and complex amplitude envelope, and subtracts them from an owned working copy before the next pass. Input samples are never modified. FFT, cancellation and waveform workspaces have fixed allocation bounds; there is no per-candidate heap allocation. Cancellation is checked during analysis, between candidates, and during subtraction fitting.

Standard types 1/2, type 4 nonstandard calls, type 0.0 free text and 0.5 telemetry are unpacked. Other payload types remain visible as unsupported; no guessed text, SNR or transmitter DT is emitted. No expected callsign, message text, frequency, or fixture identifier is embedded in the decoder.

This is not a WSJT-X sensitivity claim. See [validation](../../../docs/DECODER-VALIDATION.md) for annotated recording misses and exact test scope. `encode.c` is used for reconstruction of decoded receive signals and deterministic fixtures; there is no application transmit path.
