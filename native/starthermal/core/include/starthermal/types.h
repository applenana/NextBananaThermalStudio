#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include "starthermal/config.h"
#include "starthermal/thermal_extrema.h"

namespace starthermal {
constexpr uint16_t kSensorWidth = config::kSensorWidth;
constexpr uint16_t kSensorHeight = config::kSensorHeight;
constexpr uint16_t kVisibleFirstRow = config::kVisibleFirstRow;
constexpr uint16_t kVisibleHeight = config::kVisibleHeight;
constexpr size_t kPixelCount = kSensorWidth * kSensorHeight;
constexpr size_t kVisiblePixelCount = kSensorWidth * kVisibleHeight;
constexpr size_t kParameterBytes = 240;
constexpr size_t kFrameBytes = kParameterBytes + kPixelCount * 2;
constexpr size_t kDefaultCurveCount = 5;
constexpr size_t kMaximumCurveCount = 10;
constexpr size_t kCurveCount = kDefaultCurveCount;
constexpr size_t kDistanceCurveCount = 2;
constexpr size_t kCurvePoints = 600;
constexpr size_t kMaximumMeasurementPoints = 5;
enum class MeasurementMode : uint8_t { Single, Multiple };
struct MeasurementPoint {
  uint16_t x = 160, y = 120; // Logical 320x240 display coordinates.
  int16_t centiC = 0;
  bool valid = false;
};
struct PointMeasurements {
  std::array<MeasurementPoint, kMaximumMeasurementPoints> points{};
  MeasurementMode mode = MeasurementMode::Single;
  uint8_t count = 0; // Single+0 is the legacy fixed-center representation.
};
constexpr bool manualTableAvailable(uint8_t selection, uint8_t count) {
  return count > 0 && count <= kMaximumCurveCount &&
         selection > 0 && selection <= count;
}

struct Parameters {
  int16_t shutterRaw = 0;
  int16_t lensRaw = 0;
  int16_t fpaRaw = 0;
  int16_t shutterFlag = 0;
  int16_t fpaCentiC = 0;
  int16_t shutterCentiC = 0;
  int16_t nearB = 0;
  int16_t nearKf = 10000;
  int16_t farB = 0;
  int16_t farKf = 10000;
  int16_t nearB2 = 0;
  int16_t nearKf2 = 10000;
  int16_t farB2 = 0;
  int16_t farKf2 = 10000;
};

struct Frame {
  uint32_t sequence = 0;
  uint32_t receivedAtMs = 0;
  Parameters parameters{};
  std::array<int16_t, kPixelCount> pixels{};
};

struct TemperatureSummary {
  ThermalExtrema extrema{};
  bool valid = false;
  int16_t minimumCentiC = 0;
  int16_t maximumCentiC = 0;
  int16_t medianCentiC = 0;
  int16_t centerCentiC = 0; // Visible center pixel.
  // Top, midpoint, bottom labels shown beside the current color mapping.
  std::array<int16_t, 3> legendCentiC{};
  uint8_t legendValidMask = 0;
};

struct DisplayFrame {
  // Captured with the pixels and transferred through the frame mailbox, so
  // diagnostics never combine parameters from different sensor frames.
  struct DebugData {
    int16_t shutterCentiC = 0;
    int16_t kKnotCentiC = 0;
    int16_t b = 0, kf = 0;
    uint8_t curveIndex = 0, curveCount = 0;
    bool parametersValid = false;
    bool curveValid = false;
    bool farDistance = false;
    bool kManual = false, curveManual = false;
  } debug{};
  uint32_t sequence = 0;
  uint32_t receivedAtMs = 0;
  int16_t centerTemperatureCentiC = 0;
  int16_t fpaCentiC = 0;
  uint16_t fps = 0;
  uint8_t batteryPercent = 0;
  bool batteryValid = false;
  uint8_t kIndex = 0;
  bool nucActive = false;
  bool centerTemperatureValid = false;
  TemperatureSummary temperatures{};
  PointMeasurements measurements{};
  enum class PixelDomain : uint8_t { Y16, TemperatureCentiC };
  PixelDomain pixelDomain = PixelDomain::Y16;
  int16_t rangeLow = 0;
  int16_t rangeHigh = 1;
  // Optional display-only correction; pixels remain pre-stripe Y16.
  bool deferredStripes = false;
  std::array<int16_t, kSensorWidth> stripeColumns{};
  std::array<int16_t, kVisibleHeight> stripeRows{};
  std::array<int16_t, kVisiblePixelCount> pixels{};
};

}  // namespace starthermal
