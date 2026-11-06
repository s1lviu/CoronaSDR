#ifndef CORONA_FT8_SUBTRACTION_H
#define CORONA_FT8_SUBTRACTION_H
#include <stdatomic.h>
#include <stdint.h>
typedef struct corona_ft8_subtractor corona_ft8_subtractor;
corona_ft8_subtractor *corona_ft8_subtractor_create(void);
void corona_ft8_subtractor_destroy(corona_ft8_subtractor *s);
void corona_ft8_subtract(corona_ft8_subtractor *s, float *samples, int count,
                        const uint8_t payload[10], float hz, float start_seconds, const atomic_bool *cancelled);
#endif
