#ifndef CORONA_FT8_H
#define CORONA_FT8_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct corona_ft8 corona_ft8;
typedef struct {
    char text[35];
    uint8_t payload[10];
    float audio_hz;
    float start_seconds;
    int message_type;
    int supported;
} corona_ft8_result;
corona_ft8 *corona_ft8_create(void);
void corona_ft8_destroy(corona_ft8 *decoder);
void corona_ft8_reset(corona_ft8 *decoder);
void corona_ft8_cancel(corona_ft8 *decoder);
// 12 kHz mono, 15-18 seconds; negative return means invalid input/allocation/cancellation.
int corona_ft8_decode(corona_ft8 *decoder, const float *samples, int count,
                     corona_ft8_result *results, int capacity);
#ifdef __cplusplus
}
#endif
#endif
