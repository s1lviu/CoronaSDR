#include "recovery.h"
#include "vendor/ft8/constants.h"
#include <math.h>
#include <string.h>

typedef struct { uint64_t word[3]; } codeword;
static bool bit(codeword a, int index) { return (a.word[index / 64] >> (index % 64)) & 1; }
static codeword add(codeword a, codeword b) {
    for (int i = 0; i < 3; ++i) a.word[i] ^= b.word[i];
    return a;
}
static float distance(codeword a, codeword hard, const float costs[22][256]) {
    float cost = 0;
    a = add(a, hard);
    for (int byte = 0; byte < 22; ++byte)
        cost += costs[byte][(a.word[byte / 8] >> ((byte % 8) * 8)) & 255];
    return cost;
}
bool corona_ft8_osd(const float channel[174], const float reliability[174], uint8_t bits[174]) {
    codeword rows[91] = {0}, hard = {0}, base = {0};
    float costs[22][256];
    int order[174], pivot[91];
    for (int i = 0; i < 174; ++i) {
        if (!isfinite(channel[i]) || !isfinite(reliability[i])) return false;
        order[i] = i;
        if (channel[i] > 0) hard.word[i / 64] |= UINT64_C(1) << (i % 64);
        int j = i;
        while (j > 0 && fabsf(reliability[order[j]]) > fabsf(reliability[order[j - 1]])) {
            int tmp = order[j]; order[j] = order[j - 1]; order[--j] = tmp;
        }
    }
    // Reuse the same weighted-distance sums across all 4,187 candidates.
    // This changes only how the channel metric is evaluated, not the search space.
    for (int byte = 0; byte < 22; ++byte) {
        costs[byte][0] = 0;
        for (unsigned value = 1; value < 256; ++value) {
            int index = byte * 8 + __builtin_ctz(value);
            costs[byte][value] = costs[byte][value & (value - 1)] + (index < 174 ? fabsf(channel[index]) : 0);
        }
    }
    for (int row = 0; row < 91; ++row) {
        rows[row].word[row / 64] |= UINT64_C(1) << (row % 64);
        for (int parity = 0; parity < 83; ++parity) {
            if (kFTX_LDPC_generator[parity][row / 8] & (0x80 >> (row % 8))) {
                int index = 91 + parity;
                rows[row].word[index / 64] |= UINT64_C(1) << (index % 64);
            }
        }
    }
    int rank = 0;
    for (int col = 0; col < 174 && rank < 91; ++col) {
        int index = order[col], found = rank;
        while (found < 91 && !bit(rows[found], index)) ++found;
        if (found == 91) continue;
        codeword tmp = rows[rank]; rows[rank] = rows[found]; rows[found] = tmp;
        for (int row = 0; row < 91; ++row)
            if (row != rank && bit(rows[row], index)) rows[row] = add(rows[row], rows[rank]);
        pivot[rank++] = index;
    }
    if (rank != 91) return false;
    for (int row = 0; row < 91; ++row)
        if (reliability[pivot[row]] > 0) base = add(base, rows[row]);
    codeword best = base;
    float best_cost = distance(best, hard, costs);
    for (int i = 0; i < 91; ++i) {
        codeword one = add(base, rows[i]);
        float cost = distance(one, hard, costs);
        if (cost < best_cost) { best = one; best_cost = cost; }
        for (int j = i + 1; j < 91; ++j) {
            codeword two = add(one, rows[j]);
            cost = distance(two, hard, costs);
            if (cost < best_cost) { best = two; best_cost = cost; }
        }
    }
    // CRC is checked by the caller after selecting the closest codeword, never used to pick one.
    if (!(best.word[0] | best.word[1] | best.word[2])) return false;
    for (int i = 0; i < 174; ++i) bits[i] = bit(best, i);
    return true;
}
