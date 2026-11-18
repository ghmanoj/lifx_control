#ifndef LIFX_MICROPHONE_H
#define LIFX_MICROPHONE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

int capture_microphone(void);
double microphone_rms(const int16_t *samples, size_t count);
// Called by the capture thread at 10 Hz. False means the output pipe closed.
bool emit_microphone_level(double rms);

#endif
