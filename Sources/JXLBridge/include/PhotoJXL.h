#ifndef PHOTO_JXL_H
#define PHOTO_JXL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*pt_jxl_cancel_callback)(void *context);

int pt_jxl_encode_rgba(const uint8_t *rgba, size_t rgba_size,
                       uint32_t width, uint32_t height, int quality, int effort, int bits_per_sample,
                       const uint8_t *icc_profile, size_t icc_profile_size,
                       pt_jxl_cancel_callback is_cancelled, void *cancel_context,
                       uint8_t **output, size_t *output_size,
                       char *error, size_t error_capacity);
int pt_jxl_profile_matches(const uint8_t *jxl, size_t jxl_size,
                           const uint8_t *icc_profile, size_t icc_profile_size,
                           double maximum_xyz_difference);
void pt_jxl_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
