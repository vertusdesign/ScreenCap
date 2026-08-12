#ifndef SCREENCAP_RNNOISE_H
#define SCREENCAP_RNNOISE_H

#ifdef __cplusplus
extern "C" {
#endif

/* A small C ABI wrapper keeps the vendored RNNoise types out of Swift. */
void *screencap_rnnoise_create(void);
void screencap_rnnoise_destroy(void *state);
int screencap_rnnoise_frame_size(void);
float screencap_rnnoise_process_frame(void *state, float *out, const float *in);

#ifdef __cplusplus
}
#endif

#endif
