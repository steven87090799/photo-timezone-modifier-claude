#ifndef PHOTO_JPEGLI_H
#define PHOTO_JPEGLI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Straight RGBA in the caller's RGB profile. Transparent pixels become white.
 * Ordinary 8-bit YCbCr JPEG, no XYB. Returns 0 success, 1 error, 2 cancellation.
 * The output is owned by the caller and must be released with pt_jpegli_free.
 * Independent calls are thread safe; cancellation callback must be thread safe. */
typedef int (*PTJpegliCancelled)(void *context);
int pt_jpegli_encode(const uint8_t *rgba, size_t length, int width, int height,
                    int quality, PTJpegliCancelled cancelled, void *context,
                    uint8_t **output, size_t *output_length,
                    char *error, size_t error_capacity);
void pt_jpegli_free(void *buffer);
#ifdef __cplusplus
}
#endif
#endif
