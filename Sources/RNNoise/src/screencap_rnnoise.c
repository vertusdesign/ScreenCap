#include "screencap_rnnoise.h"

#include <stdlib.h>

#include "rnnoise.h"

void *screencap_rnnoise_create(void)
{
    return rnnoise_create(NULL);
}

void screencap_rnnoise_destroy(void *state)
{
    if (state != NULL) {
        rnnoise_destroy((DenoiseState *)state);
    }
}

int screencap_rnnoise_frame_size(void)
{
    return rnnoise_get_frame_size();
}

float screencap_rnnoise_process_frame(void *state, float *out, const float *in)
{
    if (state == NULL || out == NULL || in == NULL) {
        return 0.0f;
    }
    return rnnoise_process_frame((DenoiseState *)state, out, in);
}
