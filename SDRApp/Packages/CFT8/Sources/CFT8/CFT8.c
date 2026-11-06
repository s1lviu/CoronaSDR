#include "CFT8.h"
#include "vendor/ft8/decode.h"
#include "vendor/fft/kiss_fftr.h"
#include "subtraction.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

enum { FFT_SIZE = 7680, SYMBOL = 1920, OSR = 4, TIME_OSR = 16, BINS = 449,
       MAX_BLOCKS = 112, MAX_CANDIDATES = 512, MAX_RESULTS = 160, CALLS = 256 };
struct corona_ft8 {
    kiss_fftr_cfg fft;
    corona_ft8_subtractor *subtractor;
    float samples[216000];
    float window[2 * SYMBOL];
    float time[FFT_SIZE];
    kiss_fft_cpx frequency[FFT_SIZE / 2 + 1];
    uint8_t magnitude[MAX_BLOCKS * TIME_OSR * OSR * BINS];
    struct { char call[12]; uint32_t hash; } calls[CALLS];
    int next_call;
    atomic_bool cancelled;
};
static _Thread_local corona_ft8 *active;

static void save_call(const char *call, uint32_t hash) {
    if (!active || !call || strlen(call) > 11) return;
    for (int i = 0; i < CALLS; ++i)
        if (active->calls[i].hash == hash && strcmp(active->calls[i].call, call) == 0) return;
    int i = active->next_call++ % CALLS;
    strncpy(active->calls[i].call, call, 11);
    active->calls[i].call[11] = 0;
    active->calls[i].hash = hash;
    if (active->next_call == CALLS) active->next_call = 0;
}
static bool lookup_call(ftx_callsign_hash_type_t type, uint32_t hash, char *call) {
    if (!active) return false;
    int shift = type == FTX_CALLSIGN_HASH_10_BITS ? 12 : type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 0;
    const char *found = NULL;
    for (int i = 0; i < CALLS; ++i) {
        if (!active->calls[i].call[0] || (active->calls[i].hash >> shift) != hash) continue;
        if (found && strcmp(found, active->calls[i].call)) return false; // Hash collision stays unresolved.
        found = active->calls[i].call;
    }
    if (!found) return false;
    strcpy(call, found);
    return true;
}
corona_ft8 *corona_ft8_create(void) {
    corona_ft8 *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->fft = kiss_fftr_alloc(FFT_SIZE, 0, NULL, NULL);
    d->subtractor = corona_ft8_subtractor_create();
    if (!d->fft || !d->subtractor) { corona_ft8_destroy(d); return NULL; }
    atomic_init(&d->cancelled, false);
    for (int j = 0; j < 2 * SYMBOL; ++j) {
        float s = sinf((float)M_PI * j / (2 * SYMBOL));
        d->window[j] = s * s / SYMBOL;
    }
    return d;
}
void corona_ft8_destroy(corona_ft8 *d) { if (d) { free(d->fft); corona_ft8_subtractor_destroy(d->subtractor); free(d); } }
void corona_ft8_reset(corona_ft8 *d) {
    if (d) { memset(d->calls, 0, sizeof(d->calls)); d->next_call = 0; }
}
void corona_ft8_cancel(corona_ft8 *d) { if (d) atomic_store(&d->cancelled, true); }

int corona_ft8_decode(corona_ft8 *d, const float *samples, int count,
                     corona_ft8_result *results, int capacity) {
    if (!d || !samples || !results || capacity < 1 || capacity > MAX_RESULTS ||
        count < 180000 || count > 216000) return -1;
    atomic_store(&d->cancelled, false);
    float peak = 0;
    for (int i = 0; i < count; ++i) {
        if (!isfinite(samples[i])) return -2;
        peak = fmaxf(peak, fabsf(samples[i]));
    }
    if (peak == 0) return 0;
    // Bound FFT arithmetic even for finite but out-of-range float input.
    float scale = peak > 1 ? 1 / peak : 1;
    for (int i = 0; i < count; ++i) d->samples[i] = samples[i] * scale;
    int blocks = count / SYMBOL;
    if (blocks > MAX_BLOCKS) blocks = MAX_BLOCKS;
    ftx_waterfall_t wf = { .max_blocks = MAX_BLOCKS, .num_blocks = blocks,
        .num_bins = BINS, .time_osr = TIME_OSR, .freq_osr = OSR, .mag = d->magnitude,
        .block_stride = TIME_OSR * OSR * BINS, .protocol = FTX_PROTOCOL_FT8 };
    int out = 0;
    ftx_callsign_hash_interface_t hashes = { lookup_call, save_call };
    active = d;
    for (int pass = 0; pass < 3 && out < capacity; ++pass) {
        int previous = out;
        int time_osr = pass == 2 ? TIME_OSR : OSR;
        wf.time_osr = time_osr; wf.block_stride = time_osr * OSR * BINS;
        int length = pass == 1 ? SYMBOL : 2 * SYMBOL;
        for (int b = 0; b < blocks; ++b) {
            if (atomic_load(&d->cancelled)) { active = NULL; return -3; }
            for (int t = 0; t < time_osr; ++t) {
                // Center the analysis window on the middle of each symbol.
                int start = b * SYMBOL + t * (SYMBOL / time_osr) + (SYMBOL - length) / 2;
                for (int j = 0; j < FFT_SIZE; ++j) {
                    int pos = start + j;
                    d->time[j] = j < length && pos >= 0 && pos < count ?
                        d->samples[pos] * (pass == 1 ? 1.0f / SYMBOL : d->window[j]) : 0;
                }
                kiss_fftr(d->fft, d->time, d->frequency);
                for (int f = 0; f < OSR; ++f) for (int bin = 0; bin < BINS; ++bin) {
                    kiss_fft_cpx z = d->frequency[(bin + 32) * OSR + f];
                    float db = 10 * log10f(1e-12f + z.r * z.r + z.i * z.i);
                    int scaled = (int)(2 * db + 240);
                    d->magnitude[((b * time_osr + t) * OSR + f) * BINS + bin] = scaled < 0 ? 0 : scaled > 255 ? 255 : scaled;
                }
            }
        }
        ftx_candidate_t candidates[MAX_CANDIDATES];
        int n = ftx_find_candidates(&wf, MAX_CANDIDATES, candidates, 10);
        for (int i = 0; i < n && out < capacity; ++i) {
            if (atomic_load(&d->cancelled)) { active = NULL; return -3; }
            int first_sample = candidates[i].time_offset * SYMBOL + candidates[i].time_sub * (SYMBOL / time_osr);
            if (first_sample + 79 * SYMBOL > count) continue;
            ftx_message_t message;
            ftx_decode_status_t status;
            if (!ftx_decode_candidate(&wf, &candidates[i], 25, &message, &status)) continue;
            float hz = (32 + candidates[i].freq_offset + candidates[i].freq_sub / (float)OSR) * 6.25f;
            float seconds = (candidates[i].time_offset + candidates[i].time_sub / (float)time_osr) * 0.16f;
            bool duplicate = false;
            for (int j = 0; j < out; ++j) {
                if (memcmp(results[j].payload, message.payload, 10) == 0 &&
                    fabsf(results[j].audio_hz - hz) < 6.25f && fabsf(results[j].start_seconds - seconds) < 0.24f) {
                    duplicate = true; break;
                }
            }
            if (duplicate) continue;
            corona_ft8_result *r = &results[out++];
            memset(r, 0, sizeof(*r));
            memcpy(r->payload, message.payload, 10);
            r->audio_hz = hz; r->start_seconds = seconds;
            r->message_type = ftx_message_get_type(&message);
            ftx_message_offsets_t offsets;
            r->supported = ftx_message_decode(&message, &hashes, r->text, &offsets) == FTX_MESSAGE_RC_OK;
            if (!r->supported) strcpy(r->text, "Unsupported FT8 message type");
        }
        if (pass < 2) for (int i = previous; i < out; ++i) {
            if (atomic_load(&d->cancelled)) { active = NULL; return -3; }
            corona_ft8_subtract(d->subtractor, d->samples, count, results[i].payload,
                               results[i].audio_hz, results[i].start_seconds, &d->cancelled);
        }
    }
    active = NULL;
    return out;
}
