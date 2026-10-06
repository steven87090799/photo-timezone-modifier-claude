#include "PhotoJXL.h"

#include <jxl/color_encoding.h>
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/thread_parallel_runner.h>
#include <lcms2.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <vector>

namespace {

constexpr size_t kMaximumOutputBytes = 512ULL * 1024 * 1024;

struct FrameData {
  const uint8_t *rgba;
  size_t width;
  size_t height;
  int bits;
  pt_jxl_cancel_callback cancelled;
  void *cancel_context;
};

bool validRegion(const FrameData *frame, size_t x, size_t y, size_t width,
                 size_t height) {
  return frame != nullptr && frame->rgba != nullptr &&
         !(frame->cancelled && frame->cancelled(frame->cancel_context)) && width > 0 && height > 0 &&
         x <= frame->width && y <= frame->height &&
         width <= frame->width - x && height <= frame->height - y;
}

void getColorFormat(void *opaque, JxlPixelFormat *format) {
  format->num_channels = 3;
  format->data_type = static_cast<FrameData *>(opaque)->bits == 16 ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8;
  format->endianness = JXL_NATIVE_ENDIAN;
  format->align = 0;
}

const void *getColorData(void *opaque, size_t x, size_t y, size_t width,
                         size_t height, size_t *row_offset) {
  auto *frame = static_cast<FrameData *>(opaque);
  if (!validRegion(frame, x, y, width, height) ||
      width > std::numeric_limits<size_t>::max() / 3 ||
      height > std::numeric_limits<size_t>::max() / (width * 3)) {
    return nullptr;
  }
  const size_t bytes = frame->bits / 8;
  const size_t stride = width * 3 * bytes;
  auto *tile = new (std::nothrow) uint8_t[stride * height];
  if (tile == nullptr) return nullptr;
  for (size_t row = 0; row < height; ++row) {
    const uint8_t *source = frame->rgba + ((y + row) * frame->width + x) * 4 * bytes;
    uint8_t *destination = tile + row * stride;
    for (size_t column = 0; column < width; ++column) {
      std::memcpy(destination + column * 3 * bytes, source + column * 4 * bytes, 3 * bytes);
    }
  }
  *row_offset = stride;
  return tile;
}

void getAlphaFormat(void *opaque, size_t, JxlPixelFormat *format) {
  format->num_channels = 1;
  format->data_type = static_cast<FrameData *>(opaque)->bits == 16 ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8;
  format->endianness = JXL_NATIVE_ENDIAN;
  format->align = 0;
}

const void *getAlphaData(void *opaque, size_t, size_t x, size_t y,
                         size_t width, size_t height, size_t *row_offset) {
  auto *frame = static_cast<FrameData *>(opaque);
  if (!validRegion(frame, x, y, width, height) ||
      height > std::numeric_limits<size_t>::max() / width) {
    return nullptr;
  }
  const size_t bytes = frame->bits / 8;
  auto *tile = new (std::nothrow) uint8_t[width * height * bytes];
  if (tile == nullptr) return nullptr;
  for (size_t row = 0; row < height; ++row) {
    const uint8_t *source = frame->rgba + ((y + row) * frame->width + x) * 4 * bytes + 3 * bytes;
    uint8_t *destination = tile + row * width * bytes;
    for (size_t column = 0; column < width; ++column) {
      std::memcpy(destination + column * bytes, source + column * 4 * bytes, bytes);
    }
  }
  *row_offset = width * bytes;
  return tile;
}

void releaseTile(void *, const void *tile) {
  delete[] static_cast<const uint8_t *>(tile);
}

void setError(char *buffer, size_t capacity, const char *message) {
  if (buffer == nullptr || capacity == 0) return;
  std::snprintf(buffer, capacity, "%s", message);
}

struct DecoderDeleter {
  void operator()(JxlDecoder *decoder) const {
    if (decoder != nullptr) JxlDecoderDestroy(decoder);
  }
};

bool profilesAreColorimetricallyEquivalent(const uint8_t *first,
                                           size_t first_size,
                                           const uint8_t *second,
                                           size_t second_size,
                                           double maximum_xyz_difference) {
  if (first == nullptr || second == nullptr || first_size == 0 ||
      second_size == 0 ||
      first_size > std::numeric_limits<cmsUInt32Number>::max() ||
      second_size > std::numeric_limits<cmsUInt32Number>::max() ||
      maximum_xyz_difference <= 0.0) {
    return false;
  }
  cmsHPROFILE first_profile = cmsOpenProfileFromMem(
      first, static_cast<cmsUInt32Number>(first_size));
  cmsHPROFILE second_profile = cmsOpenProfileFromMem(
      second, static_cast<cmsUInt32Number>(second_size));
  cmsHPROFILE xyz_profile = cmsCreateXYZProfile();
  if (first_profile == nullptr || second_profile == nullptr ||
      xyz_profile == nullptr) {
    if (first_profile != nullptr) cmsCloseProfile(first_profile);
    if (second_profile != nullptr) cmsCloseProfile(second_profile);
    if (xyz_profile != nullptr) cmsCloseProfile(xyz_profile);
    return false;
  }
  const bool is_rgb = cmsGetColorSpace(first_profile) == cmsSigRgbData &&
                      cmsGetColorSpace(second_profile) == cmsSigRgbData;
  cmsHTRANSFORM first_transform =
      is_rgb ? cmsCreateTransform(first_profile, TYPE_RGB_16, xyz_profile,
                                  TYPE_XYZ_DBL, INTENT_RELATIVE_COLORIMETRIC,
                                  cmsFLAGS_NOCACHE)
             : nullptr;
  cmsHTRANSFORM second_transform =
      is_rgb ? cmsCreateTransform(second_profile, TYPE_RGB_16, xyz_profile,
                                  TYPE_XYZ_DBL, INTENT_RELATIVE_COLORIMETRIC,
                                  cmsFLAGS_NOCACHE)
             : nullptr;
  bool equivalent = false;
  if (first_transform != nullptr && second_transform != nullptr) {
    constexpr cmsUInt32Number kGridSteps = 16;
    constexpr cmsUInt32Number kSamples =
        (kGridSteps + 1) * (kGridSteps + 1) * (kGridSteps + 1);
    std::vector<cmsUInt16Number> rgb(static_cast<size_t>(kSamples) * 3);
    std::vector<cmsCIEXYZ> first_xyz(kSamples);
    std::vector<cmsCIEXYZ> second_xyz(kSamples);
    size_t offset = 0;
    for (cmsUInt32Number red = 0; red <= kGridSteps; ++red) {
      for (cmsUInt32Number green = 0; green <= kGridSteps; ++green) {
        for (cmsUInt32Number blue = 0; blue <= kGridSteps; ++blue) {
          rgb[offset++] = static_cast<cmsUInt16Number>(red * 65535 / kGridSteps);
          rgb[offset++] = static_cast<cmsUInt16Number>(green * 65535 / kGridSteps);
          rgb[offset++] = static_cast<cmsUInt16Number>(blue * 65535 / kGridSteps);
        }
      }
    }
    cmsDoTransform(first_transform, rgb.data(), first_xyz.data(), kSamples);
    cmsDoTransform(second_transform, rgb.data(), second_xyz.data(), kSamples);
    equivalent = true;
    for (cmsUInt32Number index = 0; index < kSamples; ++index) {
      const double dx = first_xyz[index].X - second_xyz[index].X;
      const double dy = first_xyz[index].Y - second_xyz[index].Y;
      const double dz = first_xyz[index].Z - second_xyz[index].Z;
      if (dx * dx + dy * dy + dz * dz >
          maximum_xyz_difference * maximum_xyz_difference) {
        equivalent = false;
        break;
      }
    }
  }
  if (first_transform != nullptr) cmsDeleteTransform(first_transform);
  if (second_transform != nullptr) cmsDeleteTransform(second_transform);
  cmsCloseProfile(first_profile);
  cmsCloseProfile(second_profile);
  cmsCloseProfile(xyz_profile);
  return equivalent;
}

struct EncoderDeleter {
  void operator()(JxlEncoder *encoder) const {
    if (encoder != nullptr) JxlEncoderDestroy(encoder);
  }
};

struct RunnerDeleter {
  void operator()(void *runner) const {
    if (runner != nullptr) JxlThreadParallelRunnerDestroy(runner);
  }
};

}  // namespace

extern "C" int pt_jxl_encode_rgba(
    const uint8_t *rgba, size_t rgba_size, uint32_t width, uint32_t height,
    int quality, int effort, int bits_per_sample, const uint8_t *icc_profile,
    size_t icc_profile_size, pt_jxl_cancel_callback is_cancelled,
    void *cancel_context, uint8_t **output, size_t *output_size, char *error,
    size_t error_capacity) {
  if (output != nullptr) *output = nullptr;
  if (output_size != nullptr) *output_size = 0;
  if (error != nullptr && error_capacity > 0) error[0] = '\0';
  if (rgba == nullptr || output == nullptr || output_size == nullptr || width == 0 ||
      height == 0 || width > 20000 || height > 20000 || quality < 1 ||
      quality > 100 || effort < 1 || effort > 10 ||
      (bits_per_sample != 8 && bits_per_sample != 16) ||
      ((icc_profile == nullptr) != (icc_profile_size == 0)) ||
      static_cast<size_t>(width) >
          std::numeric_limits<size_t>::max() / 8 / static_cast<size_t>(height) ||
      rgba_size != static_cast<size_t>(width) * height * 4 * (bits_per_sample / 8)) {
    setError(error, error_capacity, "JPEG XL 輸入參數無效。\n");
    return 1;
  }
  if (is_cancelled != nullptr && is_cancelled(cancel_context)) return 2;

  try {
    // Use libjxl's host-dependent worker count without an app-level CPU cap.
    // The scoped runner releases its workers when this encode finishes.
    std::unique_ptr<void, RunnerDeleter> runner(
        JxlThreadParallelRunnerCreate(
            nullptr, JxlThreadParallelRunnerDefaultNumWorkerThreads()));
    if (!runner) {
      setError(error, error_capacity, "無法建立 JPEG XL 工作執行緒。\n");
      return 1;
    }
    std::unique_ptr<JxlEncoder, EncoderDeleter> encoder(JxlEncoderCreate(nullptr));
    if (!encoder || JxlEncoderSetParallelRunner(encoder.get(),
                                                JxlThreadParallelRunner,
                                                runner.get()) != JXL_ENC_SUCCESS ||
        JxlEncoderUseContainer(encoder.get(), JXL_TRUE) != JXL_ENC_SUCCESS) {
      setError(error, error_capacity, "無法初始化 JPEG XL 編碼器。\n");
      return 1;
    }

    JxlBasicInfo info;
    JxlEncoderInitBasicInfo(&info);
    info.xsize = width;
    info.ysize = height;
    info.bits_per_sample = bits_per_sample;
    info.exponent_bits_per_sample = 0;
    info.num_color_channels = 3;
    info.num_extra_channels = 1;
    info.alpha_bits = bits_per_sample;
    info.alpha_exponent_bits = 0;
    info.alpha_premultiplied = JXL_FALSE;
    // In lossless mode libjxl requires pixel samples to remain in the declared
    // profile; lossy mode uses its internal perceptual color space instead.
    info.uses_original_profile = quality == 100 ? JXL_TRUE : JXL_FALSE;
    info.orientation = JXL_ORIENT_IDENTITY;
    if (JxlEncoderSetBasicInfo(encoder.get(), &info) != JXL_ENC_SUCCESS) {
      setError(error, error_capacity, "JPEG XL 無法設定影像尺寸。\n");
      return 1;
    }

    JxlExtraChannelInfo alpha;
    JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &alpha);
    alpha.bits_per_sample = bits_per_sample;
    alpha.exponent_bits_per_sample = 0;
    alpha.alpha_premultiplied = JXL_FALSE;
    if (JxlEncoderSetExtraChannelInfo(encoder.get(), 0, &alpha) !=
        JXL_ENC_SUCCESS) {
      setError(error, error_capacity, "JPEG XL 無法設定透明通道。\n");
      return 1;
    }

    JxlColorEncoding color;
    JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
    const JxlEncoderStatus color_status =
        icc_profile_size > 0
            ? JxlEncoderSetICCProfile(encoder.get(), icc_profile, icc_profile_size)
            : JxlEncoderSetColorEncoding(encoder.get(), &color);
    if (color_status != JXL_ENC_SUCCESS) {
      setError(error, error_capacity, "JPEG XL 無法設定 sRGB 色彩空間。\n");
      return 1;
    }

    JxlEncoderFrameSettings *settings =
        JxlEncoderFrameSettingsCreate(encoder.get(), nullptr);
    if (settings == nullptr) {
      setError(error, error_capacity, "JPEG XL 無法建立影格設定。\n");
      return 1;
    }
    if (quality == 100) {
      if (JxlEncoderSetFrameLossless(settings, JXL_TRUE) != JXL_ENC_SUCCESS) {
        setError(error, error_capacity, "JPEG XL 無法設定無損模式。\n");
        return 1;
      }
    } else {
      if (JxlEncoderSetFrameDistance(settings,
              JxlEncoderDistanceFromQuality(static_cast<float>(quality))) !=
          JXL_ENC_SUCCESS) {
        setError(error, error_capacity, "JPEG XL 無法設定品質。\n");
        return 1;
      }
      if (JxlEncoderSetFrameLossless(settings, JXL_FALSE) != JXL_ENC_SUCCESS) {
        setError(error, error_capacity, "JPEG XL 無法設定有損模式。\n");
        return 1;
      }
    }
    if (JxlEncoderSetExtraChannelDistance(settings, 0, 0.0f) != JXL_ENC_SUCCESS) {
      setError(error, error_capacity, "JPEG XL 無法保留透明通道。\n");
      return 1;
    }
    if (JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT,
                                         effort) != JXL_ENC_SUCCESS) {
      setError(error, error_capacity, "JPEG XL 無法設定編碼速度。\n");
      return 1;
    }
    if (JxlEncoderFrameSettingsSetOption(
            settings, JXL_ENC_FRAME_SETTING_BUFFERING, 1) != JXL_ENC_SUCCESS) {
      setError(error, error_capacity, "JPEG XL 無法設定串流記憶體模式。\n");
      return 1;
    }

    FrameData frame{rgba, width, height, bits_per_sample, is_cancelled, cancel_context};
    JxlChunkedFrameInputSource input{};
    input.opaque = &frame;
    input.get_color_channels_pixel_format = getColorFormat;
    input.get_color_channel_data_at = getColorData;
    input.get_extra_channel_pixel_format = getAlphaFormat;
    input.get_extra_channel_data_at = getAlphaData;
    input.release_buffer = releaseTile;
    if (JxlEncoderAddChunkedFrame(settings, JXL_TRUE, input) != JXL_ENC_SUCCESS) {
      if (is_cancelled != nullptr && is_cancelled(cancel_context)) return 2;
      setError(error, error_capacity, "JPEG XL 讀取影像區塊失敗。\n");
      return 1;
    }
    JxlEncoderCloseInput(encoder.get());

    std::vector<uint8_t> encoded(1024 * 1024);
    uint8_t *next = encoded.data();
    size_t available = encoded.size();
    while (true) {
      if (is_cancelled != nullptr && is_cancelled(cancel_context)) return 2;
      const JxlEncoderStatus status =
          JxlEncoderProcessOutput(encoder.get(), &next, &available);
      const size_t used = encoded.size() - available;
      if (status == JXL_ENC_SUCCESS) {
        encoded.resize(used);
        break;
      }
      if (is_cancelled != nullptr && is_cancelled(cancel_context)) return 2;
      if (status != JXL_ENC_NEED_MORE_OUTPUT ||
          encoded.size() >= kMaximumOutputBytes) {
        setError(error, error_capacity,
                 "JPEG XL 編碼失敗或輸出超過安全容量。\n");
        return 1;
      }
      const size_t next_size =
          std::min(kMaximumOutputBytes, encoded.size() * static_cast<size_t>(2));
      encoded.resize(next_size);
      next = encoded.data() + used;
      available = encoded.size() - used;
    }
    if (encoded.empty()) {
      setError(error, error_capacity, "JPEG XL 編碼器產生空白輸出。\n");
      return 1;
    }
    auto *result = static_cast<uint8_t *>(std::malloc(encoded.size()));
    if (result == nullptr) {
      setError(error, error_capacity, "JPEG XL 輸出記憶體不足。\n");
      return 1;
    }
    std::memcpy(result, encoded.data(), encoded.size());
    *output = result;
    *output_size = encoded.size();
    return 0;
  } catch (const std::bad_alloc &) {
    setError(error, error_capacity, "JPEG XL 編碼時記憶體不足。\n");
    return 1;
  } catch (...) {
    setError(error, error_capacity, "JPEG XL 編碼發生未預期錯誤。\n");
    return 1;
  }
}

extern "C" int pt_jxl_profile_matches(const uint8_t *jxl, size_t jxl_size,
                                      const uint8_t *icc_profile,
                                      size_t icc_profile_size,
                                      double maximum_xyz_difference) {
  if (jxl == nullptr || jxl_size == 0 || icc_profile == nullptr ||
      icc_profile_size == 0 || maximum_xyz_difference <= 0.0) {
    return 0;
  }
  std::unique_ptr<JxlDecoder, DecoderDeleter> decoder(JxlDecoderCreate(nullptr));
  if (!decoder ||
      JxlDecoderSubscribeEvents(decoder.get(),
                                JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) !=
          JXL_DEC_SUCCESS ||
      JxlDecoderSetInput(decoder.get(), jxl, jxl_size) != JXL_DEC_SUCCESS) {
    return 0;
  }
  JxlDecoderCloseInput(decoder.get());
  while (true) {
    const JxlDecoderStatus status = JxlDecoderProcessInput(decoder.get());
    if (status == JXL_DEC_COLOR_ENCODING) {
      size_t profile_size = 0;
      if (JxlDecoderGetICCProfileSize(decoder.get(),
                                      JXL_COLOR_PROFILE_TARGET_ORIGINAL,
                                      &profile_size) != JXL_DEC_SUCCESS ||
          profile_size == 0 || profile_size > 16 * 1024 * 1024) {
        return 0;
      }
      std::vector<uint8_t> decoded_profile(profile_size);
      if (JxlDecoderGetColorAsICCProfile(
              decoder.get(), JXL_COLOR_PROFILE_TARGET_ORIGINAL,
              decoded_profile.data(), decoded_profile.size()) !=
          JXL_DEC_SUCCESS) {
        return 0;
      }
      return profilesAreColorimetricallyEquivalent(
                 icc_profile, icc_profile_size, decoded_profile.data(),
                 decoded_profile.size(), maximum_xyz_difference)
                 ? 1
                 : 0;
    }
    if (status == JXL_DEC_SUCCESS || status == JXL_DEC_ERROR ||
        status == JXL_DEC_NEED_MORE_INPUT) {
      return 0;
    }
  }
}

extern "C" void pt_jxl_free(void *pointer) { std::free(pointer); }
