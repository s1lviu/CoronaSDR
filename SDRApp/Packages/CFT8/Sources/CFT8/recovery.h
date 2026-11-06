#ifndef CORONA_FT8_RECOVERY_H
#define CORONA_FT8_RECOVERY_H
#include <stdbool.h>
#include <stdint.h>
// Order-two reprocessing of the most reliable independent basis of the (174,91) code.
bool corona_ft8_osd(const float channel[174], const float reliability[174], uint8_t bits[174]);
#endif
