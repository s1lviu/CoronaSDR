#include "CFT8.h"
#include "ft8/message.h"
#include <assert.h>
#include <math.h>
#include <float.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t seed = 1;
static uint32_t random_word(void) {
    seed = seed * UINT64_C(6364136223846793005) + 1;
    return (uint32_t)(seed >> 32);
}
static bool lookup(ftx_callsign_hash_type_t type, uint32_t hash, char *call) { return false; }
static void save(const char *call, uint32_t hash) {}

int main(void) {
    // Every possible 77-bit payload is network-controlled, including invalid message fields.
    ftx_callsign_hash_interface_t hashes = { lookup, save };
    for (int i = 0; i < 200000; ++i) {
        ftx_message_t message = {0};
        for (int j = 0; j < 10; ++j) message.payload[j] = (uint8_t)random_word();
        message.payload[9] &= 0xf8;
        char text[FTX_MAX_MESSAGE_LENGTH];
        memset(text, 0xa5, sizeof(text));
        ftx_message_offsets_t offsets;
        ftx_message_decode(&message, &hashes, text, &offsets);
        assert(memchr(text, 0, sizeof(text)) != NULL);
    }
    corona_ft8 *decoder = corona_ft8_create();
    assert(decoder != NULL);
    float *samples = calloc(216000, sizeof(float));
    assert(samples != NULL);
    corona_ft8_result results[160];
    assert(corona_ft8_decode(NULL,samples,216000,results,160) < 0);
    assert(corona_ft8_decode(decoder,NULL,216000,results,160) < 0);
    assert(corona_ft8_decode(decoder,samples,216000,NULL,160) < 0);
    for (int n = -1; n <= 216001; n += 18000) {
        if (n < 180000 || n > 216000) assert(corona_ft8_decode(decoder,samples,n,results,160) < 0);
    }
    assert(corona_ft8_decode(decoder,samples,216000,results,0) < 0);
    assert(corona_ft8_decode(decoder,samples,216000,results,161) < 0);
    assert(corona_ft8_decode(decoder,samples,216000,results,160) == 0);
    samples[1000] = NAN;
    assert(corona_ft8_decode(decoder,samples,216000,results,160) == -2);
    samples[1000] = INFINITY;
    assert(corona_ft8_decode(decoder,samples,216000,results,160) == -2);
    samples[1000] = FLT_MAX;
    assert(corona_ft8_decode(decoder,samples,216000,results,160) == 0);
    for (int pass = 0; pass < 100; ++pass) {
        for (int i = 0; i < 216000; ++i) samples[i] = ((int32_t)random_word() / 2147483648.0f) * powf(10,(pass % 10)-5);
        int count = corona_ft8_decode(decoder,samples,180000+(pass % 10)*4000,results,160);
        assert(count == 0);
        corona_ft8_reset(decoder);
    }
    for (int kind = 0; kind < 5; ++kind) {
        double phase = 0;
        for (int i = 0; i < 216000; ++i) {
            double hz = kind == 0 ? 200 : kind == 1 ? 700 : kind == 2 ? 2950 : 200 + 2800.0*i/216000;
            phase += 2*M_PI*hz/12000;
            samples[i] = kind == 4 ? (i % 1000 == 0 ? 1 : 0) : sin(phase)*0.5;
        }
        assert(corona_ft8_decode(decoder,samples,216000,results,160) == 0);
    }
    free(samples); corona_ft8_destroy(decoder);
    puts("CFT8 safety passed: 200000 payloads, invalid boundaries and 100 noise windows, tones/chirp/impulses with zero false decodes.");
    return 0;
}
