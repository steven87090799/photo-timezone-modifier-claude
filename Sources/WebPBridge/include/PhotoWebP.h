#ifndef PHOTO_WEBP_H
#define PHOTO_WEBP_H

#include <stddef.h>
#include <stdint.h>

typedef int (*PhotoWebPCancel)(void *context);

int photo_webp_encode(const uint8_t *pixels, int width, int height, int quality,
                      int preview, const char *output, size_t limit,
                      PhotoWebPCancel should_cancel, void *context);

#endif
