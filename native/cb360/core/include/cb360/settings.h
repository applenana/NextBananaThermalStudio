#pragma once

#include <cstddef>
#include <cstdio>
#include <cstdint>
#include "cb360/config.h"
#include "cb360/types.h"

namespace cb360 {
enum class Setting : uint8_t {
  Palette, Emissivity, Brightness, MinimumMappedRange, AutoCalibrationInterval,
  OsdMode, HotTracking, ColdTracking, ScreenInversion,
  ReflectedTemperature, TemperatureOffset, TemperatureUnit, DistanceMode,
  CenterRegion, ReadoutStability, RangeMode, ManualRangeLow, ManualRangeHigh,
  RangeResponse, KMapSelection, TemperatureCurveSelection, CenterOverlay,
  MeasurementMode, Count
};
// Live/photo OSD content level. Off hides every overlay element (toast and
// calibration prompts excepted); Full restores the complete HUD. The HUD
// statistics panel is always fixed to the top-left corner.
enum class OsdMode : uint8_t { Off, Minimal, Medium, Full, Debug };
enum class TemperatureUnit : uint8_t { Celsius, Fahrenheit };
enum class ReadoutStability : uint8_t { Fast, Standard, Stable };
// Median window used for the centre readout; Single keeps the original pixel.
enum class CenterRegion : uint8_t { Single, Median3x3, Median5x5 };
enum class RangeResponse : uint8_t { Fast, Standard, Stable };
// Factory resources contain two distance curve slots; only near/far modes are
// exposed until the slots are validated against a known target distance.
enum class DistanceMode : uint8_t { Near, Far };

struct CenterOverlayOptions {
  bool reticle = true;
  bool temperature = true;
};

struct Settings {
  TrackingOptions tracking{};
  CenterOverlayOptions centerOverlay{};
  MeasurementMode measurementMode = MeasurementMode::Single;
  Palette palette = config::kDefaultPalette;
  uint8_t emissivityPercent = config::kDefaultEmissivityPercent;
  uint8_t brightness = config::kDefaultBrightness;
  int16_t minimumMappedRangeCentiC = config::kDefaultMinimumMappedRangeCentiC;
  uint16_t autoCalibrationIntervalSeconds =
      config::kDefaultAutoCalibrationIntervalSeconds;
  OsdMode osdMode = OsdMode::Full;
  int8_t reflectedTemperatureC = config::kDefaultReflectedTemperatureC;
  int16_t temperatureOffsetCentiC = config::kDefaultTemperatureOffsetCentiC;
  TemperatureUnit temperatureUnit = TemperatureUnit::Celsius;
  ReadoutStability readoutStability = ReadoutStability::Standard;
  CenterRegion centerRegion = CenterRegion::Single;
  RangeResponse rangeResponse = RangeResponse::Standard;
  DistanceMode distanceMode = DistanceMode::Near;
  // 0 = automatic; 1..kMaximumCurveCount = manually selected table number.
  uint8_t kMapSelection = 0;
  uint8_t temperatureCurveSelection = 0;
  bool manualRangeEnabled = false;
  int16_t manualRangeLowCentiC = config::kDefaultManualRangeLowCentiC;
  int16_t manualRangeHighCentiC = config::kDefaultManualRangeHighCentiC;
  bool screenInverted = true;
  Setting selected = Setting::Palette;
  bool settingsVisible = false;
};

enum class UiAction : uint8_t {
  None, ToggleSettings, SelectPrevious, SelectNext, Decrease, Increase,
  Calibrate, PaletteNext, CapturePhoto, OpenAlbum, Activate, Back,
  CycleOsdMode, MeasurePoint
};

const char* osdModeLabel(OsdMode mode);
const char* temperatureUnitLabel(TemperatureUnit unit);
const char* readoutStabilityLabel(ReadoutStability level);
const char* centerRegionLabel(CenterRegion region);
const char* rangeResponseLabel(RangeResponse level);
const char* distanceModeLabel(DistanceMode mode);
const char* rangeModeLabel(bool manual);
// Header-inline so every display/test target can format temperatures without
// pulling in the settings persistence module.
inline int16_t formatTemperatureValue(TemperatureUnit unit, int16_t centiC) {
  if (unit == TemperatureUnit::Fahrenheit) {
    const int32_t f = static_cast<int32_t>(centiC) * 9 / 5 + 3200;
    if (f > INT16_MAX) return INT16_MAX;
    if (f < INT16_MIN) return INT16_MIN;
    return static_cast<int16_t>(f);
  }
  return centiC;
}
// Read-only sensor/curve diagnostics for the maintenance page. Written by
// core 0, read by core 1; each field is atomic so no lock is needed.
struct TemperatureDiagnostics {
  std::atomic<int16_t> fpaCentiC{0};
  std::atomic<int16_t> shutterCentiC{0};
  std::atomic<int16_t> nearB{0};
  std::atomic<int16_t> nearKf{10000};
  std::atomic<int16_t> farB{0};
  std::atomic<int16_t> farKf{10000};
  std::atomic<uint8_t> curveIndex{0};
  std::atomic<uint8_t> curveCount{0};
  std::atomic<bool> valid{false};
};
extern TemperatureDiagnostics gTemperatureDiagnostics;
void publishTemperatureDiagnostics(const TemperatureDiagnostics& source);
// Renders a centi-degree value into text (unit suffix included).
inline void formatTemperatureText(char* out, size_t size, TemperatureUnit unit,
                                  int16_t centiC, bool valid,
                                  bool includeUnit) {
  if (!out || size == 0) return;
  const char* suffix = !includeUnit ? ""
      : unit == TemperatureUnit::Fahrenheit ? "°F" : "°C";
  if (!valid) {
    snprintf(out, size, "--.-%s", suffix);
    return;
  }
  const int32_t value = formatTemperatureValue(unit, centiC);
  const int32_t tenths = (value >= 0 ? value + 5 : 5 - value) / 10;
  snprintf(out, size, "%s%d.%d%s", value < 0 && tenths != 0 ? "-" : "",
           static_cast<int>(tenths / 10), static_cast<int>(tenths % 10), suffix);
}
// Settings can select every mode; the live shortcut skips Debug and exits it
// to Full on its first press.
OsdMode cycleOsdMode(OsdMode mode, int delta, bool fromButton = false);
void applyUiAction(Settings& settings, UiAction action);
bool settingsEqual(const Settings& left, const Settings& right);
}  // namespace cb360
