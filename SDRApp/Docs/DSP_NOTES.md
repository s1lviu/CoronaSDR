# DSP Implementation Notes

## Pipeline Overview

```
Network → IQ Ring Buffer → [DSP Thread] → Audio Ring Buffer → [Audio Callback]
                                ↓
                          FFT → Spectrum/Waterfall → [Render Thread]
```

## IQ Conversion

Input from rtl_tcp: 8-bit unsigned interleaved IQ.

```
I_float = (byte_I - 127.5) / 127.5
Q_float = (byte_Q - 127.5) / 127.5
```

## DC Blocker

IIR high-pass filter to remove DC offset:
```
y[n] = x[n] - x[n-1] + α * y[n-1]
α = 0.998 (typical)
```

## Channelization

1. **NCO mixing**: Shift signal to baseband using complex multiplication with exp(-j*2π*f*t)
2. **FIR low-pass filter**: Windowed-sinc design with Hamming window
3. **Decimation**: Reduce sample rate to intermediate rate

## Demodulation

### AM (Envelope Detection)
```
output = sqrt(I² + Q²)
```
Followed by DC removal and AGC.

### FM (Quadrature Discriminator)
```
output = atan2(Q[n]*I[n-1] - I[n]*Q[n-1], I[n]*I[n-1] + Q[n]*Q[n-1])
```
Followed by de-emphasis filter (50µs or 75µs).

### SSB (USB/LSB)
Take real part of analytic signal after BFO mixing.
USB: positive BFO offset; LSB: negative BFO offset.

### CW
Same as SSB with narrow filter (200-800 Hz) and BFO offset for sidetone.

## De-emphasis Filter

Single-pole IIR:
```
τ = deemphasis_µs × 10⁻⁶
α = 1 - exp(-1 / (sampleRate × τ))
y[n] = y[n-1] + α × (x[n] - y[n-1])
```

- 75 µs: Americas, South Korea
- 50 µs: Europe, Australia, Japan

## AGC (Automatic Gain Control)

Adaptive gain with fast attack (reduces gain quickly on loud signals) and slow decay (increases gain slowly when signal drops):
```
error = target_level - |sample| × gain
if error < 0: gain += error × attack_rate   (fast)
else:          gain += error × decay_rate    (slow)
```

## Resampling

Linear interpolation resampler with fractional ratio support.
Output is always 48,000 Hz Float32 mono.

## Clock Drift Compensation

PI controller adjusts resampler ratio to maintain audio ring buffer at 50% fill:
```
error = buffer_fill - 0.5
integral += error
correction = Kp × error + Ki × integral
new_ratio = base_ratio × (1 + correction)
```
Clamped to ±150 PPM adjustment range.

## FFT

- vDSP DFT (forward complex-to-complex)
- Hann window applied before transform
- Power spectrum: 10 × log10(|X[k]|² / N²) in dBFS
- FFT shift: swap halves for DC-center display
- EMA smoothing with optional peak hold

## Filter Design

FIR low-pass using windowed-sinc method:
```
h[n] = sin(ωc × (n - M/2)) / (π × (n - M/2))  × hamming(n)
```
Where ωc = π × (cutoff / nyquist), normalized after windowing.

## Typical Rates

| Sample Rate | NFM Decimation | Intermediate Rate | Final Resample Ratio |
|------------|----------------|-------------------|---------------------|
| 1,024,000  | ÷21            | 48,762 Hz         | 48000/48762 ≈ 0.984 |
| 2,048,000  | ÷42            | 48,762 Hz         | 48000/48762 ≈ 0.984 |
| 2,400,000  | ÷50            | 48,000 Hz         | 1.0                 |
