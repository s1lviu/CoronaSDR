#include "subtraction.h"
#include "vendor/ft8/encode.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { N = 216000, LOW = N / 10, SYMBOL = 1920, WAVE = 79 * SYMBOL, TAPS = 101 };
struct corona_ft8_subtractor {
    float filter[TAPS], pulse[3 * SYMBOL], phase[WAVE + 2 * SYMBOL];
    float mixed_r[N], mixed_i[N], low_r[LOW], low_i[LOW];
    float ref_r[WAVE / 10], ref_i[WAVE / 10];
    float a_r[LOW], a_i[LOW], b_r[LOW], b_i[LOW];
};
corona_ft8_subtractor *corona_ft8_subtractor_create(void) {
    corona_ft8_subtractor *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    double sum = 0;
    for (int i = 0; i < TAPS; ++i) {
        double x = i - TAPS / 2, f = 120.0 / 12000;
        double sinc = x == 0 ? 2 * f : sin(2 * M_PI * f * x) / (M_PI * x);
        s->filter[i] = sinc * (0.42 - 0.5 * cos(2 * M_PI * i / (TAPS - 1)) + 0.08 * cos(4 * M_PI * i / (TAPS - 1)));
        sum += s->filter[i];
    }
    for (int i = 0; i < TAPS; ++i) s->filter[i] /= sum;
    // FT8 BT=2 GFSK pulse; same protocol shaping as the pinned MIT waveform generator.
    for (int i = 0; i < 3 * SYMBOL; ++i) {
        double t = (double)i / SYMBOL - 1.5;
        s->pulse[i] = (erf(10.672892 * (t + 0.5)) - erf(10.672892 * (t - 0.5))) * 0.5;
    }
    return s;
}
void corona_ft8_subtractor_destroy(corona_ft8_subtractor *s) { free(s); }

static void box(const float *in, float *out, int n, int radius) {
    double sum = 0;
    for (int i = 0; i < n + radius; ++i) {
        if (i < n) sum += in[i];
        if (i > 2 * radius) sum -= in[i - 2 * radius - 1];
        if (i >= radius) out[i - radius] = sum / (2 * radius + 1);
    }
}
static double envelope(corona_ft8_subtractor *s, int n, int start, int radius) {
    for (int i = 0; i < n; ++i) {
        int k = i - start;
        if (k < 0 || k >= WAVE / 10) { s->a_r[i] = s->a_i[i] = 0; continue; }
        s->a_r[i] = s->low_r[i] * s->ref_r[k] + s->low_i[i] * s->ref_i[k];
        s->a_i[i] = s->low_i[i] * s->ref_r[k] - s->low_r[i] * s->ref_i[k];
    }
    for (int pass = 0; pass < 3; ++pass) {
        box(s->a_r, s->b_r, n, radius); box(s->a_i, s->b_i, n, radius);
        memcpy(s->a_r, s->b_r, n * sizeof(float)); memcpy(s->a_i, s->b_i, n * sizeof(float));
    }
    double power = 0;
    for (int i = 0; i < n; ++i) power += s->a_r[i] * s->a_r[i] + s->a_i[i] * s->a_i[i];
    return power;
}
void corona_ft8_subtract(corona_ft8_subtractor *s, float *samples, int count,
                        const uint8_t payload[10], float hz, float start_seconds, const atomic_bool *cancelled) {
    if (!s || count < 180000 || count > N) return;
    uint8_t tones[79]; ft8_encode(payload, tones);
    memset(s->phase, 0, sizeof(s->phase));
    for (int symbol = 0; symbol < 79; ++symbol)
        for (int j = 0; j < 3 * SYMBOL; ++j) s->phase[symbol * SYMBOL + j] += tones[symbol] * s->pulse[j];
    for (int j = 0; j < 2 * SYMBOL; ++j) {
        s->phase[j] += tones[0] * s->pulse[j + SYMBOL];
        s->phase[WAVE + j] += tones[78] * s->pulse[j];
    }
    double phase = 0;
    for (int i = 0; i < WAVE; ++i) {
        double step = 2 * M_PI / SYMBOL * s->phase[i + SYMBOL];
        s->phase[i] = phase;
        phase += step;
        if (i % 10 == 0) { s->ref_r[i / 10] = cos(s->phase[i]); s->ref_i[i / 10] = sin(s->phase[i]); }
    }
    for (int i = 0; i < count; ++i) {
        double angle = 2 * M_PI * hz * i / 12000;
        s->mixed_r[i] = samples[i] * cos(angle); s->mixed_i[i] = -samples[i] * sin(angle);
    }
    int low_count = count / 10;
    for (int i = 0; i < low_count; ++i) {
        double real = 0, imag = 0;
        for (int j = 0; j < TAPS; ++j) {
            int k = i * 10 + j - TAPS / 2;
            if (k >= 0 && k < count) { real += s->filter[j] * s->mixed_r[k]; imag += s->filter[j] * s->mixed_i[k]; }
        }
        s->low_r[i] = real; s->low_i[i] = imag;
    }
    int initial = (int)lroundf(start_seconds * 1200), best = initial;
    double score = -1;
    for (int delta = -96; delta <= 96; delta += 12) {
        if (atomic_load(cancelled)) return;
        int start = initial + delta;
        if (start < 0 || start + WAVE / 10 > low_count) continue;
        double candidate = envelope(s, low_count, start, 72);
        if (candidate > score) { score = candidate; best = start; }
    }
    int coarse = best;
    for (int delta = -12; delta <= 12; delta += 2) {
        int start = coarse + delta;
        if (start < 0 || start + WAVE / 10 > low_count) continue;
        double candidate = envelope(s, low_count, start, 72);
        if (candidate > score) { score = candidate; best = start; }
    }
    envelope(s, low_count, best, 48);
    for (int i = best * 10; i < best * 10 + WAVE && i < count; ++i) {
        int low = i / 10, next = low + 1 < low_count ? low + 1 : low;
        float fraction = (i % 10) * 0.1f;
        double real = s->a_r[low] + fraction * (s->a_r[next] - s->a_r[low]);
        double imag = s->a_i[low] + fraction * (s->a_i[next] - s->a_i[low]);
        double angle = s->phase[i - best * 10] + 2 * M_PI * hz * i / 12000;
        samples[i] -= 2 * (real * cos(angle) - imag * sin(angle));
    }
}
