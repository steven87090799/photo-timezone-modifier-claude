// Portable compatibility check. Windows CI opens these files with its system
// decoder; macOS integration additionally verifies ICC/EXIF/XMP through ImageIO.
#include "PhotoJpegli.h"
#include <cstdio>
#include <cstring>
#include <vector>
static int cancel(void *) { return 1; }
static int cancelAfterRows(void *context) { return ++(*static_cast<int *>(context)) >= 4; }
int main(int argc, char **argv) {
  if (argc != 2) return 1;
  constexpr int width = 128, height = 96;
  std::vector<uint8_t> rgba(width * height * 4, 255);
  for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
    size_t i = size_t(y * width + x) * 4;
    rgba[i] = x * 2; rgba[i+1] = y * 2; rgba[i+2] = (x + y) % 256;
  }
  for (int quality : {1, 49, 82, 95, 100}) {
    uint8_t *output = nullptr; size_t length = 0; char error[512];
    int status = pt_jpegli_encode(rgba.data(), rgba.size(), width, height,
      quality, nullptr, nullptr, &output, &length, error, sizeof(error));
    if (status || !length) { std::fprintf(stderr, "%s\n", error); return 2; }
    char path[4096]; std::snprintf(path, sizeof(path), "%s/quality-%d.jpg", argv[1], quality);
    FILE *file = std::fopen(path, "wb");
    if (!file) { pt_jpegli_free(output); return 3; }
    bool wrote = std::fwrite(output, 1, length, file) == length;
    bool closed = std::fclose(file) == 0;
    pt_jpegli_free(output);
    if (!wrote || !closed) return 4;
  }
  uint8_t *output = nullptr; size_t length = 0; char error[512];
  if (pt_jpegli_encode(rgba.data(), rgba.size(), width, height, 82,
      cancel, nullptr, &output, &length, error, sizeof(error)) != 2 || output || length) return 5;
  int callbacks = 0;
  if (pt_jpegli_encode(rgba.data(), rgba.size(), width, height, 82,
      cancelAfterRows, &callbacks, &output, &length, error, sizeof(error)) != 2 || output || length) return 7;
  if (pt_jpegli_encode(rgba.data(), 1, width, height, 82, nullptr, nullptr,
      &output, &length, error, sizeof(error)) != 1 || output || length) return 6;
  std::puts("Jpegli standard JPEG / cancellation / input limits OK");
  return 0;
}
