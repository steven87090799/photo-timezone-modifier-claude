#include "PhotoJpegli.h"
#include "lib/jpegli/encode.h"
#include <csetjmp>
#include <cstdlib>
#include <cstring>

// All state modified after setjmp lives on the heap. No C++ object destructor
// is crossed by libjpeg's error longjmp, and each call owns its entire state.
struct EncodeState {
  jpeg_compress_struct codec;
  jpeg_error_mgr errors;
  jmp_buf jump;
  unsigned char *output;
  unsigned long length;
  unsigned char *row;
  char *message;
  size_t capacity;
};
static void fail(j_common_ptr common) {
  auto *state = static_cast<EncodeState *>(common->client_data);
  char message[JMSG_LENGTH_MAX];
  common->err->format_message(common, message);
  if (state->message && state->capacity) {
    std::snprintf(state->message, state->capacity, "%s", message);
  }
  longjmp(state->jump, 1);
}
static void cleanup(EncodeState *state) {
  jpegli_destroy_compress(&state->codec);
  std::free(state->output);
  std::free(state->row);
  std::free(state);
}
extern "C" int pt_jpegli_encode(const uint8_t *rgba, size_t length,
    int width, int height, int quality, PTJpegliCancelled cancelled, void *context,
    uint8_t **output, size_t *output_length, char *error, size_t capacity) {
  if (output) *output = nullptr;
  if (output_length) *output_length = 0;
  if (error && capacity) error[0] = '\0';
  if (!output || !output_length || !rgba || width <= 0 || height <= 0 ||
      width > 20000 || height > 20000 || quality < 1 || quality > 100 ||
      size_t(width) > (256u * 1024u * 1024u) / 4u / size_t(height) ||
      length != size_t(width) * size_t(height) * 4u) {
    if (error && capacity) std::snprintf(error, capacity, "Invalid RGBA dimensions, size or quality");
    return 1;
  }
  if (cancelled && cancelled(context)) return 2;
  auto *state = static_cast<EncodeState *>(std::calloc(1, sizeof(EncodeState)));
  if (!state) return 1;
  state->message = error;
  state->capacity = capacity;
  state->codec.err = jpegli_std_error(&state->errors);
  state->codec.client_data = state;
  state->errors.error_exit = fail;
  if (setjmp(state->jump)) { cleanup(state); return 1; }
  jpegli_create_compress(&state->codec);
  state->codec.client_data = state;
  jpegli_mem_dest(&state->codec, &state->output, &state->length);
  state->codec.image_width = width;
  state->codec.image_height = height;
  state->codec.input_components = 3;
  state->codec.in_color_space = JCS_RGB;
  jpegli_set_defaults(&state->codec);
  jpegli_set_colorspace(&state->codec, JCS_YCbCr);
  jpegli_set_quality(&state->codec, quality, TRUE);
  // Keep conventional 4:2:0 below 90 and full chroma at high quality.
  state->codec.comp_info[0].h_samp_factor = quality >= 90 ? 1 : 2;
  state->codec.comp_info[0].v_samp_factor = quality >= 90 ? 1 : 2;
  state->codec.comp_info[1].h_samp_factor = state->codec.comp_info[1].v_samp_factor = 1;
  state->codec.comp_info[2].h_samp_factor = state->codec.comp_info[2].v_samp_factor = 1;
  state->codec.optimize_coding = TRUE;
  jpegli_set_progressive_level(&state->codec, 2);
  jpegli_enable_adaptive_quantization(&state->codec, TRUE);
  state->row = static_cast<unsigned char *>(std::malloc(size_t(width) * 3u));
  if (!state->row) { cleanup(state); return 1; }
  jpegli_start_compress(&state->codec, TRUE);
  while (state->codec.next_scanline < state->codec.image_height) {
    if (cancelled && cancelled(context)) { cleanup(state); return 2; }
    const auto *pixels = rgba + size_t(state->codec.next_scanline) * size_t(width) * 4u;
    for (int x = 0; x < width; ++x) {
      const unsigned alpha = pixels[x * 4 + 3];
      for (int channel = 0; channel < 3; ++channel) {
        state->row[x * 3 + channel] = static_cast<unsigned char>(
          (unsigned(pixels[x * 4 + channel]) * alpha + 255u * (255u - alpha) + 127u) / 255u);
      }
    }
    JSAMPROW row = state->row;
    jpegli_write_scanlines(&state->codec, &row, 1);
  }
  jpegli_finish_compress(&state->codec);
  if (cancelled && cancelled(context)) { cleanup(state); return 2; }
  // Never accept JPEG XL or another container from the JPEG route.
  if (!state->output || state->length < 4 || state->output[0] != 0xff ||
      state->output[1] != 0xd8 || state->output[state->length - 2] != 0xff ||
      state->output[state->length - 1] != 0xd9) {
    if (error && capacity) std::snprintf(error, capacity, "Encoder did not produce ordinary JPEG");
    cleanup(state); return 1;
  }
  *output = state->output;
  *output_length = state->length;
  state->output = nullptr;
  cleanup(state);
  return 0;
}
extern "C" void pt_jpegli_free(void *buffer) { std::free(buffer); }
