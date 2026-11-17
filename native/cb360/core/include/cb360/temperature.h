#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include "cb360/types.h"

namespace cb360 {
#if defined(ARDUINO)
constexpr size_t kResidentCurveCount = 1;
#else
constexpr size_t kResidentCurveCount = kMaximumCurveCount;
#endif

// Per-frame measurement corrections. Reflection and pixel offset are applied
// after the emissivity polynomial; farDistance selects the second factory
// distance curve and the far B/Kf sensor coefficients.
struct TemperatureAdjustments {
  float emissivity = 0.98f;
  float reflectedC = 25.0f;
  int16_t offsetCentiC = 0;
  bool farDistance = false;
};

struct TemperatureCurves {
  uint8_t count = kDefaultCurveCount;
  std::array<int16_t, kMaximumCurveCount> knotsCentiC{};
  uint8_t loadedIndex = 0;
  uint8_t selection = 0; // 0 automatic, otherwise a 1-based manual node.
  std::array<std::array<std::array<uint16_t, kCurvePoints>,
                        kDistanceCurveCount>, kResidentCurveCount> values{};
};

uint8_t selectTemperatureCurveIndex(const Parameters& parameters,
                                    const TemperatureCurves& curves);
const uint16_t* temperatureCurveAt(const TemperatureCurves& curves,
                                   uint8_t index, uint8_t distance = 0);

class TemperatureMapper {
 public:
  bool prepare(const Parameters& parameters, const TemperatureCurves& curves,
               float emissivity);
  bool prepare(const Parameters& parameters, const TemperatureCurves& curves,
               const TemperatureAdjustments& adjustments);
  bool convert(int16_t centeredY16, int16_t& temperatureCentiC) const;
  bool invert(int16_t temperatureCentiC, int16_t& centeredY16) const;

 private:
  const uint16_t* curve_ = nullptr;
  uint8_t loadedCurveIndex_ = 0xFF;
  std::array<int16_t, kCurvePoints> correctedTemperatures_{};
  std::array<uint16_t, 257> curveBucketStarts_{};
  TemperatureAdjustments adjustments_{};
  float nearBias_ = 0;
  float nearGain_ = 0;
  float emissivity_ = -1;
  float shutterCode_ = 0;
  bool curveReady_ = false;
  bool temperaturesReady_ = false;
};

float emissivityCorrection(float temperatureC, float emissivity,
                           float reflectedTemperatureC);
bool estimateCenterTemperature(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference,
                               float emissivity,
                               int16_t& temperatureCentiC);
bool estimatePixelTemperature(int16_t centeredY16,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              float emissivity,
                              int16_t& temperatureCentiC);
bool estimatePixelTemperature(int16_t centeredY16,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              const TemperatureAdjustments& adjustments,
                              int16_t& temperatureCentiC);
bool estimatePixelTemperature(int16_t centeredY16, const uint16_t* curve,
                              const Parameters& parameters, float emissivity,
                              int16_t& temperatureCentiC);
bool estimatePixelTemperature(int16_t centeredY16, const uint16_t* curve,
                              const Parameters& parameters,
                              const TemperatureAdjustments& adjustments,
                              int16_t& temperatureCentiC);
const uint16_t* selectTemperatureCurve(const Parameters& parameters,
                                      const TemperatureCurves& curves);
const uint16_t* selectTemperatureCurve(const Parameters& parameters,
                                      const TemperatureCurves& curves,
                                      bool farDistance);
// True when a stored curve is monotonic and non-degenerate; used to reject an
// empty far-distance slot before it reaches the temperature output.
bool temperatureCurveUsable(const uint16_t* curve);
}  // namespace cb360
