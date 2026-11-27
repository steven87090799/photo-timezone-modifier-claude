#include "PhotoWebP.h"
#include <stdio.h>
#include <webp/encode.h>

typedef struct {
    FILE *file;
    size_t remaining;
    PhotoWebPCancel should_cancel;
    void *context;
} EncoderOutput;

static int write_output(const uint8_t *bytes, size_t size, const WebPPicture *picture) {
    EncoderOutput *output = picture->custom_ptr;
    if (size > output->remaining || output->should_cancel(output->context)) return 0;
    if (fwrite(bytes, 1, size, output->file) != size) return 0;
    output->remaining -= size;
    return 1;
}

static int report_progress(int percentage, const WebPPicture *picture) {
    (void)percentage;
    EncoderOutput *output = picture->custom_ptr;
    return !output->should_cancel(output->context);
}

int photo_webp_encode(const uint8_t *pixels, int width, int height, int quality,
                      int preview, const char *path, size_t limit,
                      PhotoWebPCancel should_cancel, void *context) {
    if (width <= 0 || width > WEBP_MAX_DIMENSION || height <= 0 || height > WEBP_MAX_DIMENSION ||
        should_cancel(context)) return 0;

    WebPConfig config;
    WebPPicture picture;
    if (!WebPConfigInit(&config) || !WebPPictureInit(&picture)) return 0;
    config.quality = (float)quality;
    config.method = preview ? 2 : 6;
    config.sns_strength = 50;
    config.use_sharp_yuv = 1;
    if (!WebPValidateConfig(&config)) return 0;

    FILE *file = fopen(path, "wbx");
    if (file == NULL) return 0;
    EncoderOutput output = { file, limit, should_cancel, context };
    picture.width = width;
    picture.height = height;
    picture.use_argb = 1;
    picture.custom_ptr = &output;
    picture.writer = write_output;
    picture.progress_hook = report_progress;
    int success = WebPPictureImportRGBA(&picture, pixels, width * 4) && WebPEncode(&config, &picture);
    WebPPictureFree(&picture);
    if (fclose(file) != 0) success = 0;
    return success;
}
