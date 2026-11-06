#include <math.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "ft8/message.h"
#include "ft8/encode.h"
#include "DecoderFixtures.h"
#define LOG(...) ((void)0)
// Waveform synthesis from kgoba/ft8_lib demo/gen_ft8.c, MIT, pinned in THIRD_PARTY_NOTICES.
#define FT8_SYMBOL_BT 2.0f ///< symbol smoothing filter bandwidth factor (BT)
#define FT4_SYMBOL_BT 1.0f ///< symbol smoothing filter bandwidth factor (BT)

#define GFSK_CONST_K 5.336446f ///< == pi * sqrt(2 / log(2))

/// Computes a GFSK smoothing pulse.
/// The pulse is theoretically infinitely long, however, here it's truncated at 3 times the symbol length.
/// This means the pulse array has to have space for 3*n_spsym elements.
/// @param[in] n_spsym Number of samples per symbol
/// @param[in] b Shape parameter (values defined for FT8/FT4)
/// @param[out] pulse Output array of pulse samples
///
void gfsk_pulse(int n_spsym, float symbol_bt, float* pulse)
{
    for (int i = 0; i < 3 * n_spsym; ++i)
    {
        float t = i / (float)n_spsym - 1.5f;
        float arg1 = GFSK_CONST_K * symbol_bt * (t + 0.5f);
        float arg2 = GFSK_CONST_K * symbol_bt * (t - 0.5f);
        pulse[i] = (erff(arg1) - erff(arg2)) / 2;
    }
}

/// Synthesize waveform data using GFSK phase shaping.
/// The output waveform will contain n_sym symbols.
/// @param[in] symbols Array of symbols (tones) (0-7 for FT8)
/// @param[in] n_sym Number of symbols in the symbol array
/// @param[in] f0 Audio frequency in Hertz for the symbol 0 (base frequency)
/// @param[in] symbol_bt Symbol smoothing filter bandwidth (2 for FT8, 1 for FT4)
/// @param[in] symbol_period Symbol period (duration), seconds
/// @param[in] signal_rate Sample rate of synthesized signal, Hertz
/// @param[out] signal Output array of signal waveform samples (should have space for n_sym*n_spsym samples)
///
void synth_gfsk(const uint8_t* symbols, int n_sym, float f0, float symbol_bt, float symbol_period, int signal_rate, float* signal)
{
    int n_spsym = (int)(0.5f + signal_rate * symbol_period); // Samples per symbol
    int n_wave = n_sym * n_spsym;                            // Number of output samples
    float hmod = 1.0f;

    LOG(LOG_DEBUG, "n_spsym = %d\n", n_spsym);
    // Compute the smoothed frequency waveform.
    // Length = (nsym+2)*n_spsym samples, first and last symbols extended
    float dphi_peak = 2 * M_PI * hmod / n_spsym;
    float dphi[n_wave + 2 * n_spsym];

    // Shift frequency up by f0
    for (int i = 0; i < n_wave + 2 * n_spsym; ++i)
    {
        dphi[i] = 2 * M_PI * f0 / signal_rate;
    }

    float pulse[3 * n_spsym];
    gfsk_pulse(n_spsym, symbol_bt, pulse);

    for (int i = 0; i < n_sym; ++i)
    {
        int ib = i * n_spsym;
        for (int j = 0; j < 3 * n_spsym; ++j)
        {
            dphi[j + ib] += dphi_peak * symbols[i] * pulse[j];
        }
    }

    // Add dummy symbols at beginning and end with tone values equal to 1st and last symbol, respectively
    for (int j = 0; j < 2 * n_spsym; ++j)
    {
        dphi[j] += dphi_peak * pulse[j + n_spsym] * symbols[0];
        dphi[j + n_sym * n_spsym] += dphi_peak * pulse[j] * symbols[n_sym - 1];
    }

    // Calculate and insert the audio waveform
    float phi = 0;
    for (int k = 0; k < n_wave; ++k)
    { // Don't include dummy symbols
        signal[k] = sinf(phi);
        phi = fmodf(phi + dphi[k + n_spsym], 2 * M_PI);
    }

    // Apply envelope shaping to the first and last symbols
    int n_ramp = n_spsym / 8;
    for (int i = 0; i < n_ramp; ++i)
    {
        float env = (1 - cosf(2 * M_PI * i / (2 * n_ramp))) / 2;
        signal[i] *= env;
        signal[n_wave - 1 - i] *= env;
    }
}


static int render(const ftx_message_t *message, float hz, float start_seconds, float *out, int count) {
    const int n = 79 * 1920;
    int start = (int)roundf(start_seconds * 12000);
    if (start < 0 || start + n > count) return -2;
    memset(out, 0, sizeof(float) * count);
    uint8_t tones[79]; ft8_encode(message->payload, tones);
    synth_gfsk(tones, 79, hz, 2.0f, 0.16f, 12000, out + start);
    return 0;
}

int fixture_ft8(const char *text, float hz, float start_seconds, float *out, int count) {
    ftx_message_t message = {0};
    if (ftx_message_encode(&message, NULL, text) != FTX_MESSAGE_RC_OK) return -1;
    return render(&message,hz,start_seconds,out,count);
}

int fixture_ft8_kind(int kind, float *out, int count) {
    ftx_message_t message = {0};
    if (kind == 0) {
        if (ftx_message_encode_free(&message,"HELLO WORLD") != FTX_MESSAGE_RC_OK) return -1;
    } else if (kind == 1) {
        const uint8_t data[9] = {0x12,0x34,0x56,0x78,0x9a,0xbc,0xde,0xf0,0x12};
        if (ftx_message_encode_telemetry(&message,data) != FTX_MESSAGE_RC_OK) return -1;
        message.payload[8] |= 1; message.payload[9] = 1 << 6; // n3=5, i3=0; upstream leaves type to caller.
    } else if (kind == 2) {
        if (ftx_message_encode_nonstd(&message,NULL,"CQ","PJ4/K1ABC","") != FTX_MESSAGE_RC_OK) return -1;
    } else {
        message.payload[9] = 3 << 3; // Unsupported i3=3, still valid parity/CRC after encoding.
    }
    return render(&message,1200,1,out,count);
}
