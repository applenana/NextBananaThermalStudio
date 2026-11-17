#pragma once
#include "cb360/types.h"
#include "cb360/settings.h"

namespace cb360 {
enum class OverlayMode : uint8_t { Live, Photo };
// Composited directly into the existing four-row RGB565 DMA stripes.
class ThermalOverlay {
 public:
  // The statistics panel is always fixed to the top-left corner. osdMode
  // selects how much of the overlay is composed into the thermal image.
  void beginFrame(const DisplayFrame& frame, Palette palette,
                  OverlayMode mode = OverlayMode::Live,
                  TrackingOptions tracking = {},
                  bool calibrationBusy = false,
                  uint32_t animationTimeMs = 0,
                  uint16_t photoCount = 0,
                  OsdMode osdMode = OsdMode::Full,
                  TemperatureUnit temperatureUnit = TemperatureUnit::Celsius,
                  CenterOverlayOptions center = {});
  // Transient bottom-center notification (e.g. capture saved). The text
  // must stay valid while visible; the overlay keeps only the pointer.
  void showToast(const char* text, uint32_t nowMs, uint32_t durationMs);
  struct ToastSpan { int16_t left = 0, width = 0; };
  // Paint only the opaque toast pixels, without a frame or OSD dependency.
  // Returns the modified span so the panel can preserve the surrounding image.
  static ToastSpan renderToastRow(const char* text, uint16_t y, uint16_t* pixels);
  void renderRow(uint16_t y, uint16_t* pixels) const;
  // Shared by photo thumbnails: tracking only, without the rest of the HUD.
  void renderTrackingRow(uint16_t y, uint16_t* pixels) const;
  // Translucent neutral gray shared by every HUD mask.
  static constexpr uint16_t grayMask(uint16_t color) {
    const unsigned r = (((color >> 11) & 0x1F) * 4 + 6 * 11 + 7) / 15;
    const unsigned g = (((color >> 5) & 0x3F) * 4 + 12 * 11 + 7) / 15;
    const unsigned b = ((color & 0x1F) * 4 + 6 * 11 + 7) / 15;
    return static_cast<uint16_t>((r << 11) | (g << 5) | b);
  }

 private:
  struct Text { char value[48]{}; int16_t x = 0, y = 0; };
  struct Spot {
    Text label{};
    int16_t x = 0, y = 0;
    uint16_t color = 0;
    uint8_t width = 0;
    bool enabled = false;
    uint16_t acceptedIndex = 0;
    uint16_t candidateIndex = 0;
    uint8_t candidateFrames = 0;
    bool lockInitialized = false;
    int16_t acceptedTemperature = 0;
    int32_t positionXQ8 = 0, positionYQ8 = 0;
    int32_t transitionFromXQ8 = 0, transitionFromYQ8 = 0;
    int32_t transitionTargetXQ8 = 0, transitionTargetYQ8 = 0;
    int32_t velocityXQ8PerSecond = 0, velocityYQ8PerSecond = 0;
    int32_t transitionVelocityXQ8PerSecond = 0;
    int32_t transitionVelocityYQ8PerSecond = 0;
    uint32_t transitionStartedAtMs = 0;
    bool transitionActive = false;
  };
  std::array<Spot, 2> spots_{};
  bool trackingEnabled_ = false;
  std::array<Text, 11> text_{};
  std::array<Text, 8> debugText_{};
  std::array<uint16_t, 256> legend_{};
  struct MeasurementLabel {
    Text text{};
    int16_t x = 160, y = 120;
    uint8_t width = 0;
  };
  std::array<MeasurementLabel, kMaximumMeasurementPoints> measurementLabels_{};
  uint8_t measurementCount_ = 0;
  bool measurementLabelOverlaps(int x, int y, int width, int height) const;
  int16_t legendBoxX_[2] = {0, 0};
  uint8_t legendBoxWidth_[2] = {0, 0};
  uint8_t batteryPercent_ = 0;
  bool batteryValid_ = false;
  bool liveStatus_ = true;
  bool calibrationBusy_ = false;
  uint8_t calibrationSpinnerPhase_ = 0;
  OsdMode osdMode_ = OsdMode::Full;
  TemperatureUnit temperatureUnit_ = TemperatureUnit::Celsius;
  bool showStats_ = true;
  bool showCenterReticle_ = true;
  bool showCenterTemperature_ = true;
  bool showLegend_ = true;
  bool showInfo_ = true;
  bool showDebug_ = false;
  uint16_t photoCount_ = 0;
  char countText_[8]{};
  int16_t countTextX_ = 0;
  const char* toastText_ = nullptr;
  uint32_t toastUntilMs_ = 0;
  bool toastVisible_ = false;
};
}
