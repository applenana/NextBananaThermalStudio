#pragma once

#include "cb360/settings.h"
#include "cb360/temperature.h"

namespace cb360 {
// V5 stores only NUC-corrected visible Y16 and its temperature-curve index.
// Legacy V1-V4 files remain readable; their saved render settings are ignored.
constexpr size_t kLegacyPhotoHeaderBytes = 128;
constexpr size_t kLegacyPhotoV4HeaderBytes = 160;
constexpr size_t kLegacyPhotoFileBytes = kLegacyPhotoHeaderBytes + kVisiblePixelCount * 2 + 4;
constexpr size_t kLegacyPhotoV4FileBytes = kLegacyPhotoV4HeaderBytes + kVisiblePixelCount * 2 + 4;
constexpr size_t kPhotoHeaderBytes = 32;
constexpr size_t kPhotoFileBytes = kPhotoHeaderBytes + kVisiblePixelCount * 2 + 4;
enum class PhotoResult : uint8_t {
  Ok, InvalidArgument, NotReady, NotFound, NoSpace, IoError,
  Corrupt, UnsupportedVersion, IdExhausted, Canceled, CalibrationMismatch
};
const char* photoResultText(PhotoResult result);

struct PhotoInfo {
  uint32_t id = 0;
  uint64_t capturedAtUnixMs = 0; // 0 = no wall clock; never interpret uptime as UTC.
  uint32_t sequence = 0;
  uint8_t curveIndex = 0;
};

struct PhotoRenderConfig {
  Settings settings{};
  Parameters parameters{};
  int32_t averageReference = 0;
  PointMeasurements measurements{};
};

PhotoInfo describePhoto(const DisplayFrame& displayed, const Settings& settings,
                        const Parameters& parameters, const TemperatureCurves& curves,
                        uint64_t capturedAtUnixMs = 0);
bool validPhotoInfo(const PhotoInfo& info);
bool validPhotoCurve(const uint16_t* curve);
// y16 is NUC-corrected and pre-stripe. Render configuration is always current.
bool photoTemperature(const PhotoInfo& info, const PhotoRenderConfig& config,
                      const TemperatureCurves& curves,
                      int16_t y16, int16_t& centiC);
// In-place restoration using current settings and calibration. Uses bounded
// local scratch only; the persisted Y16 plane is consumed by this call.
PhotoResult restorePhotoFrame(const PhotoInfo& info, const PhotoRenderConfig& config,
                              const TemperatureCurves& curves,
                              DisplayFrame& workspace);
} // namespace cb360
