#include "cb360/thermal_overlay.h"
#include "cb360/overlay_font.h"
#include "cb360/view.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace cb360 {
namespace {
bool overlaps(int x, int y, int w, int h, int bx, int by, int bw, int bh) {
  return x < bx + bw && x + w > bx && y < by + bh && y + h > by;
}
constexpr int kScreenWidth = 320;
constexpr int kFontHeight = 16;
constexpr int kStatsTop = 6;
constexpr int kStatsWidth = 106;
constexpr int kStatsHeight = 52;
// Legend group (labels + bar) sits slightly below the screen center so it
// stays visually centered under the live album button and photo counter.
constexpr int kLegendTop = 89;
constexpr int kLegendBottom = 162;
constexpr int kLegendBoxTop = 64;
constexpr int kLegendBoxBottom = 166;
constexpr int kLegendBoxHeight = 22;
constexpr int kStatsLeft = 6;
constexpr int kGearCenterX = 300;
constexpr int kGearCenterY = 220;
constexpr int kGearButtonRadius = 13;
constexpr int kAlbumCenterX = 300;
constexpr int kAlbumCenterY = 20;
constexpr int kAlbumButtonRadius = 13;
// Live photo counter under the album button and the transient toast card.
constexpr int kAlbumCountTop = kAlbumCenterY + 16;
constexpr int kToastTop = 164;
constexpr int kToastHeight = kFontHeight + 12;
constexpr uint16_t kToastSurface = 0x18A4;
constexpr uint16_t kToastBorder = 0x5DDB;
constexpr int kInfoLeft = 6;
constexpr int kInfoTop = 207;
constexpr int kInfoWidth = 112;
constexpr int kInfoHeight = 27;
constexpr int kDebugLeft = 6;
constexpr int kDebugTop = 64;
constexpr int kDebugWidth = 140;
constexpr int kDebugHeight = 136;
constexpr uint32_t kDebugStaleMs = 1000;
constexpr int kBatteryLeft = 14;
constexpr int kBatteryRight = 33;
constexpr int kBatteryTop = 215;
constexpr int kBatteryBottom = 225;
constexpr uint32_t kTrackingTransitionMs = 500;
constexpr int32_t kEasingScale = 256;
constexpr int32_t kPositionScale = 256;

struct MotionSample {
  int32_t positionQ8;
  int32_t velocityQ8PerSecond;
};

MotionSample sampleMotion(int32_t fromQ8, int32_t targetQ8,
                          int32_t velocityQ8PerSecond, uint32_t elapsedMs) {
  if (elapsedMs >= kTrackingTransitionMs) return {targetQ8, 0};
  const int32_t u = static_cast<int32_t>(elapsedMs * kEasingScale /
                                         kTrackingTransitionMs);
  const int32_t u2 = (u * u + kEasingScale / 2) / kEasingScale;
  const int32_t u3 = (u2 * u + kEasingScale / 2) / kEasingScale;
  const int32_t h00 = 2 * u3 - 3 * u2 + kEasingScale;
  const int32_t h10 = u3 - 2 * u2 + u;
  const int32_t h01 = -2 * u3 + 3 * u2;
  const int32_t velocityTermQ8 = velocityQ8PerSecond / 2;
  const int32_t positionQ8 = static_cast<int32_t>((
      int64_t(h00) * fromQ8 + int64_t(h10) * velocityTermQ8 +
      int64_t(h01) * targetQ8) / kEasingScale);

  const int32_t dh00 = 6 * u2 - 6 * u;
  const int32_t dh10 = 3 * u2 - 4 * u + kEasingScale;
  const int32_t dh01 = -dh00;
  const int32_t derivativeQ8 = static_cast<int32_t>((
      int64_t(dh00) * fromQ8 + int64_t(dh10) * velocityTermQ8 +
      int64_t(dh01) * targetQ8) / kEasingScale);
  return {positionQ8, derivativeQ8 * 2};
}

int16_t roundedPixel(int32_t positionQ8) {
  return static_cast<int16_t>((positionQ8 + kPositionScale / 2) / kPositionScale);
}
constexpr int kBatteryFillLeft = 16;
constexpr int kBatteryFillWidth = 16;
constexpr int kCalibrationDialogX = 55;
constexpr int kCalibrationDialogY = 90;
constexpr int kCalibrationDialogWidth = 210;
constexpr int kCalibrationDialogHeight = 60;
constexpr int kCalibrationSpinnerX = 90;
constexpr int kCalibrationSpinnerY = 120;
constexpr int kCalibrationMessageX = 117;
constexpr uint16_t kCalibrationAccent = 0x5DDB;
constexpr uint16_t kCalibrationTrack = 0x4D99;
constexpr uint16_t kCalibrationSurface = 0x18A4;

uint32_t nextCodepoint(const char*& text) {
  uint32_t code = static_cast<uint8_t>(*text++);
  if (code < 0x80) return code;
  unsigned count = code < 0xE0 ? 1 : 2;
  code &= count == 1 ? 0x1F : 0x0F;
  while (count-- && *text) code = (code << 6) | (static_cast<uint8_t>(*text++) & 0x3F);
  return code;
}
const OverlayGlyph* glyph(uint32_t cp) {
  for (unsigned i = 0; i < overlayFont12.count; ++i)
    if (overlayFont12.glyphs[i].codepoint == cp) return &overlayFont12.glyphs[i];
  return nullptr;
}
int textWidth(const char* text) {
  int width = 0;
  while (*text) {
    const auto* g = glyph(nextCodepoint(text));
    if (g) width += g->width;
  }
  return width;
}
uint16_t whiteBlend(uint16_t background, unsigned alpha) {
  const unsigned r = ((background >> 11) * (15-alpha) + 31*alpha + 7) / 15;
  const unsigned g = (((background >> 5) & 63) * (15-alpha) + 63*alpha + 7) / 15;
  const unsigned b = ((background & 31) * (15-alpha) + 31*alpha + 7) / 15;
  return static_cast<uint16_t>((r << 11) | (g << 5) | b);
}
void drawTextRow(const char* text, int x, unsigned row, uint16_t* pixels) {
  while (*text) {
    const auto* g = glyph(nextCodepoint(text));
    if (!g) continue;
    for (unsigned col = 0; col < g->width; ++col) {
      const int screenX = x + col;
      if (screenX < 0 || screenX >= kScreenWidth) continue;
      const unsigned index = row * g->width + col;
      const uint8_t packed = overlayFont12.bitmap[g->offset + index / 2];
      const unsigned alpha = index & 1 ? packed & 15 : packed >> 4;
      if (alpha) pixels[screenX] = whiteBlend(pixels[screenX], alpha);
    }
    x += g->width;
  }
}
const OverlayGlyph* popupGlyph(uint32_t cp) {
  for (unsigned i = 0; i < overlayCalibrationFont12.count; ++i)
    if (overlayCalibrationFont12.glyphs[i].codepoint == cp)
      return &overlayCalibrationFont12.glyphs[i];
  return nullptr;
}
void drawPopupTextRow(const char* text, int x, unsigned row, uint16_t* pixels) {
  while (*text) {
    const auto* g = popupGlyph(nextCodepoint(text));
    if (!g) continue;
    for (unsigned col = 0; col < g->width; ++col) {
      const int screenX = x + col;
      if (screenX < 0 || screenX >= kScreenWidth) continue;
      const unsigned index = row * g->width + col;
      const uint8_t packed = overlayCalibrationFont12.bitmap[g->offset + index / 2];
      const unsigned alpha = index & 1 ? packed & 15 : packed >> 4;
      if (alpha) pixels[screenX] = whiteBlend(pixels[screenX], alpha);
    }
    x += g->width;
  }
}
void temperature(char* output, size_t size, int16_t value, bool valid,
                 bool includeUnit, TemperatureUnit unit) {
  formatTemperatureText(output, size, unit, value, valid, includeUnit);
}
void panelRow(int y, int x, int top, int width, int height, uint16_t* pixels) {
  if (y < top || y >= top + height) return;
  // Small clipped corners; all interior pixels use the shared gray mask.
  const int inset = y == top || y == top + height - 1 ? 3 :
                    y == top + 1 || y == top + height - 2 ? 1 : 0;
  const int first = std::max(0, x + inset);
  const int last = std::min(kScreenWidth, x + width - inset);
  for (int col = first; col < last; ++col)
    pixels[col] = ThermalOverlay::grayMask(pixels[col]);
}
void circleRow(int y, int cx, int cy, int radius, uint16_t* pixels) {
  const int dy = y - cy;
  if (dy < -radius || dy > radius) return;
  int dx = 0;
  while ((dx + 1) * (dx + 1) + dy * dy <= radius * radius) ++dx;
  for (int x = cx - dx; x <= cx + dx; ++x)
    if (x >= 0 && x < kScreenWidth) pixels[x] = ThermalOverlay::grayMask(pixels[x]);
}
bool reticle(int x, int y) {
  const int distance = x*x + y*y;
  const int ax = std::abs(x), ay = std::abs(y);
  // Keep the outer ring and diagonal ticks unchanged; move the inner wall in
  // by one pixel so the hollow centre shrinks without growing the reticle.
  return (distance >= 9 && distance <= 25) ||
         (ax >= 4 && ax <= 5 && ax == ay);
}
bool gearOutline(int x, int y) {
  const float radius = std::sqrt(static_cast<float>(x*x + y*y));
  if (radius < 2.6f) return false;
  const float angle = std::atan2(static_cast<float>(y), static_cast<float>(x));
  // Eight teeth rotated by 22.5 degrees: the phase keeps the pixel silhouette
  // symmetric instead of growing two oversized side teeth.
  const float outer =
      std::cos(8.0f * (angle + 0.39269908f)) > 0.0f ? 8.2f : 6.2f;
  return radius <= outer;
}
// The icon never changes; rasterize it once instead of evaluating trig per pixel.
std::array<uint32_t, 17>& gearRows() {
  static std::array<uint32_t, 17> rows{};
  static bool ready = false;
  if (!ready) {
    for (int y = -8; y <= 8; ++y)
      for (int x = -8; x <= 8; ++x)
        if (gearOutline(x, y)) rows[y + 8] |= 1UL << (x + 8);
    ready = true;
  }
  return rows;
}
// Album/photo glyph: framed picture with a sun and a mountain.
bool albumOutline(int x, int y) {
  if ((std::abs(x) == 7 && std::abs(y) <= 5) ||
      (std::abs(y) == 5 && std::abs(x) <= 7)) return true;
  const int sunX = x + 4;
  const int sunY = y + 2;
  if (sunX * sunX + sunY * sunY <= 2) return true;
  if (y >= 1 && y <= 4) {
    const int half = y + 1;
    if (x >= 2 - half && x <= 2 + half) return true;
  }
  return false;
}
std::array<uint32_t, 17>& albumRows() {
  static std::array<uint32_t, 17> rows{};
  static bool ready = false;
  if (!ready) {
    for (int y = -8; y <= 8; ++y)
      for (int x = -8; x <= 8; ++x)
        if (albumOutline(x, y)) rows[y + 8] |= 1UL << (x + 8);
    ready = true;
  }
  return rows;
}
uint16_t batteryColor(uint8_t percent) {
  if (percent <= 20) return 0xF800;
  if (percent <= 50) return 0xFD20;
  return 0x07E0;
}
void batteryRow(int y, bool valid, uint8_t percent, uint16_t* pixels) {
  // Compact rounded body with a short terminal nub.
  if (y == kBatteryTop || y == kBatteryBottom) {
    for (int x = kBatteryLeft + 2; x <= kBatteryRight - 2; ++x)
      pixels[x] = 0xFFFF;
  } else if (y == kBatteryTop + 1 || y == kBatteryBottom - 1) {
    for (int x = kBatteryLeft + 1; x <= kBatteryRight - 1; ++x)
      pixels[x] = 0xFFFF;
  } else if (y > kBatteryTop + 1 && y < kBatteryBottom - 1) {
    pixels[kBatteryLeft] = pixels[kBatteryRight] = 0xFFFF;
  }
  if (y >= 218 && y <= 222) {
    if (y == 218 || y == 222) {
      for (int x = 34; x <= 35; ++x) pixels[x] = 0xFFFF;
    } else {
      pixels[35] = 0xFFFF;
    }
  }
  if (!valid || y < kBatteryTop + 2 || y > kBatteryBottom - 2) return;
  const int fill = (kBatteryFillWidth * static_cast<int>(percent) + 50) / 100;
  const uint16_t color = batteryColor(percent);
  for (int i = 0; i < fill; ++i) pixels[kBatteryFillLeft + i] = color;
}
void calibrationDialogRow(uint16_t y, uint16_t* pixels, uint8_t phase) {
  if (y < kCalibrationDialogY || y >= kCalibrationDialogY + kCalibrationDialogHeight) return;
  const int row = y - kCalibrationDialogY;
  const int inset = row < 5 ? 5 - row :
      row >= kCalibrationDialogHeight - 5 ? row - (kCalibrationDialogHeight - 6) : 0;
  for (int x = kCalibrationDialogX + inset;
       x < kCalibrationDialogX + kCalibrationDialogWidth - inset; ++x) {
    const bool edge = row == 0 || row == kCalibrationDialogHeight - 1 ||
                      x == kCalibrationDialogX + inset ||
                      x == kCalibrationDialogX + kCalibrationDialogWidth - inset - 1;
    pixels[x] = edge ? kCalibrationTrack : kCalibrationSurface;
  }
  if (row == 3)
    for (int x = kCalibrationDialogX + 8; x < kCalibrationDialogX + kCalibrationDialogWidth - 8; ++x)
      pixels[x] = kCalibrationAccent;
  static constexpr int8_t points[12][2] = {
      {0,-11},{6,-10},{10,-6},{11,0},{10,6},{6,10},
      {0,11},{-6,10},{-10,6},{-11,0},{-10,-6},{-6,-10}};
  for (unsigned i = 0; i < 12; ++i) {
    if (points[i][1] != row - (kCalibrationSpinnerY - kCalibrationDialogY)) continue;
    const int x = kCalibrationSpinnerX + points[i][0];
    const unsigned distance = (i + 12 - phase) % 12;
    pixels[x] = distance < 5 ? kCalibrationAccent : kCalibrationTrack;
    pixels[x + 1] = distance < 5 ? kCalibrationAccent : kCalibrationTrack;
  }
  if (row >= 27 && row < 45) {
    drawPopupTextRow("快门校准中，请稍后",
                kCalibrationMessageX,
                static_cast<unsigned>(row - 27), pixels);
  }
}
uint16_t dimThermalBackdrop(uint16_t color) {
  const unsigned r = ((color >> 11) & 31) * 9 / 15;
  const unsigned g = ((color >> 5) & 63) * 9 / 15;
  const unsigned b = (color & 31) * 9 / 15;
  return static_cast<uint16_t>((r << 11) | (g << 5) | b);
}
}  // namespace
void ThermalOverlay::showToast(const char* text, uint32_t nowMs,
                               uint32_t durationMs) {
  toastText_ = text;
  toastUntilMs_ = nowMs + durationMs;
}
void ThermalOverlay::beginFrame(const DisplayFrame& frame, Palette palette,
                                OverlayMode mode, TrackingOptions tracking,
                                bool calibrationBusy, uint32_t animationTimeMs,
                                uint16_t photoCount, OsdMode osdMode,
                                TemperatureUnit temperatureUnit,
                                CenterOverlayOptions center) {
  liveStatus_ = mode == OverlayMode::Live;
  temperatureUnit_ = temperatureUnit;
  showDebug_ = liveStatus_ && osdMode == OsdMode::Debug;
  // The debug mode retains all normal HUD elements, including in photos.
  osdMode_ = osdMode == OsdMode::Debug ? OsdMode::Full : osdMode;
  showStats_ = osdMode_ != OsdMode::Off;
  // OSD eligibility is the master gate. Like hot/cold tracking, disabling the
  // cursor also hides its label, without discarding the label preference.
  showCenterReticle_ = showStats_ && center.reticle;
  showCenterTemperature_ = showCenterReticle_ && center.temperature;
  showLegend_ = osdMode_ == OsdMode::Medium || osdMode_ == OsdMode::Full;
  showInfo_ = liveStatus_ && osdMode_ == OsdMode::Full;
  calibrationBusy_ = calibrationBusy && liveStatus_ &&
                     osdMode_ != OsdMode::Off;
  const uint32_t phaseTime = animationTimeMs ? animationTimeMs : frame.receivedAtMs;
  if (showDebug_) {
    const auto& debug = frame.debug;
    const uint32_t ageMs = phaseTime - frame.receivedAtMs;
    const bool fresh = debug.parametersValid && ageMs <= kDebugStaleMs &&
                       !calibrationBusy;
    const bool kValid = fresh && frame.nucActive && debug.curveCount > 0 &&
                        debug.curveCount <= kMaximumCurveCount &&
                        frame.kIndex < debug.curveCount;
    const bool curveValid = kValid && debug.curveValid &&
                            debug.curveIndex < debug.curveCount;
    char value[24];
    formatTemperatureText(value, sizeof(value), TemperatureUnit::Celsius,
                          frame.fpaCentiC, fresh, true);
    snprintf(debugText_[0].value, sizeof(debugText_[0].value), "FPA %s", value);
    formatTemperatureText(value, sizeof(value), TemperatureUnit::Celsius,
                          debug.shutterCentiC, fresh, true);
    snprintf(debugText_[1].value, sizeof(debugText_[1].value), "SHUT %s", value);
    if (kValid) {
      formatTemperatureText(value, sizeof(value), TemperatureUnit::Celsius,
                            debug.kKnotCentiC, true, true);
      snprintf(debugText_[2].value, sizeof(debugText_[2].value), "K %c%u/%u %s",
               debug.kManual ? 'M' : 'A', unsigned(frame.kIndex) + 1,
               unsigned(debug.curveCount), value);
    } else {
      snprintf(debugText_[2].value, sizeof(debugText_[2].value), "K --");
    }
    if (curveValid) {
      snprintf(debugText_[3].value, sizeof(debugText_[3].value), "CUR %c%u/%u %s",
               debug.curveManual ? 'M' : 'A', unsigned(debug.curveIndex) + 1, unsigned(debug.curveCount),
               debug.farDistance ? "FAR" : "NEAR");
      snprintf(debugText_[5].value, sizeof(debugText_[5].value), "B %.4f",
               debug.b / 10000.0);
      snprintf(debugText_[6].value, sizeof(debugText_[6].value), "KF %.4f",
               debug.kf / 10000.0);
    } else {
      snprintf(debugText_[3].value, sizeof(debugText_[3].value), "CUR --");
      snprintf(debugText_[5].value, sizeof(debugText_[5].value), "B --");
      snprintf(debugText_[6].value, sizeof(debugText_[6].value), "KF --");
    }
    snprintf(debugText_[4].value, sizeof(debugText_[4].value), "NUC %s",
             calibrationBusy ? "CAL" : !debug.parametersValid ? "--" :
             !fresh ? "STALE" : frame.nucActive ? "ON" : "OFF");
    snprintf(debugText_[7].value, sizeof(debugText_[7].value), "AGE %lums",
             static_cast<unsigned long>(ageMs));
    for (unsigned i = 0; i < debugText_.size(); ++i) {
      debugText_[i].x = kDebugLeft + 6;
      debugText_[i].y = kDebugTop + 4 + i * kFontHeight;
    }
  }
  calibrationSpinnerPhase_ = static_cast<uint8_t>((phaseTime / 100) % 12);
  photoCount_ = photoCount;
  if (liveStatus_) {
    snprintf(countText_, sizeof(countText_), "%u张",
             static_cast<unsigned>(photoCount_));
    countTextX_ = static_cast<int16_t>(kAlbumCenterX - textWidth(countText_) / 2);
  } else {
    countText_[0] = '\0';
  }
  toastVisible_ = toastText_ != nullptr &&
      static_cast<int32_t>(toastUntilMs_ - phaseTime) > 0;
  const auto& summary = frame.temperatures;
  const bool valid = frame.nucActive && summary.valid;
  const char* names[] = {"最高", "中位", "最低"};
  const int16_t values[] = {summary.maximumCentiC, summary.medianCentiC,
                            summary.minimumCentiC};
  const bool valueValid[] = {valid, valid, valid};
  const int panelX = kStatsLeft;
  for (int i = 0; i < 3; ++i) {
    // Label left, value right: the decimal points line up in one column.
    snprintf(text_[i].value, sizeof(text_[i].value), "%s", names[i]);
    text_[i].x = static_cast<int16_t>(panelX + 6);
    text_[i].y = static_cast<int16_t>(8 + i*16);
    temperature(text_[3+i].value, sizeof(text_[3+i].value), values[i], valueValid[i],
                true, temperatureUnit_);
    text_[3+i].x = static_cast<int16_t>(panelX + 100 - textWidth(text_[3+i].value));
    text_[3+i].y = text_[i].y;
  }
  text_[6].value[0] = 0; // Point labels replace the formerly fixed center label.
  PointMeasurements readings = frame.measurements;
  if (!readings.count && readings.mode == MeasurementMode::Single && liveStatus_) {
    readings.count = 1;
    readings.points[0] = {160, 120, frame.centerTemperatureCentiC,
                          frame.centerTemperatureValid};
  }
  measurementCount_ = std::min<size_t>(readings.count, kMaximumMeasurementPoints);
  for (size_t i = 0; i < measurementCount_; ++i) {
    auto& label = measurementLabels_[i];
    const auto& point = readings.points[i];
    label.x = std::min<uint16_t>(point.x, 319);
    label.y = std::min<uint16_t>(point.y, 239);
    char value[24];
    temperature(value, sizeof(value), point.centiC, frame.nucActive && point.valid,
                true, temperatureUnit_);
    if (readings.mode == MeasurementMode::Multiple)
      snprintf(label.text.value, sizeof(label.text.value), "%u: %s", unsigned(i + 1), value);
    else snprintf(label.text.value, sizeof(label.text.value), "%s", value);
    label.width = static_cast<uint8_t>(textWidth(label.text.value) + 8);
    const int xs[] = {label.x + 13, label.x - label.width - 13,
                      label.x - label.width / 2, label.x - label.width / 2};
    const int ys[] = {label.y - 8, label.y - 8, label.y + 12, label.y - 30};
    for (size_t candidate = 0; candidate < 4; ++candidate) {
      label.text.x = std::clamp(xs[candidate], 0, 320 - int(label.width));
      label.text.y = std::clamp(ys[candidate], 0, 222);
      bool blocked = (showStats_ && overlaps(label.text.x, label.text.y, label.width, 18, 6, 6, 106, 52)) ||
          (showLegend_ && overlaps(label.text.x, label.text.y, label.width, 18, 288, 64, 32, 124)) ||
          (showDebug_ && overlaps(label.text.x, label.text.y, label.width, 18,
                                 kDebugLeft, kDebugTop, kDebugWidth, kDebugHeight));
      for (size_t pointIndex = 0; pointIndex < measurementCount_; ++pointIndex) {
        const auto& marker = readings.points[pointIndex];
        blocked |= overlaps(label.text.x, label.text.y, label.width, 18,
                            int(marker.x) - 9, int(marker.y) - 9, 18, 18);
      }
      for (size_t previous = 0; previous < i; ++previous) {
        const auto& other = measurementLabels_[previous];
        blocked |= overlaps(label.text.x, label.text.y, label.width, 18,
                            other.text.x, other.text.y, other.width, 18);
      }
      if (!blocked) break;
    }
  }
  for (int i = 0; i < 2; ++i) {
    Text& label = text_[7+i];
    temperature(label.value, sizeof(label.value), summary.legendCentiC[i == 0 ? 0 : 2],
                valid && (summary.legendValidMask & (1U << (i == 0 ? 0 : 2))), false,
                temperatureUnit_);
    const int width = textWidth(label.value);
    const int boxWidth = width + 4;
    int boxX = 304 - boxWidth / 2;
    if (boxX + boxWidth > kScreenWidth - 1) boxX = kScreenWidth - 1 - boxWidth;
    if (boxX < 0) boxX = 0;
    legendBoxWidth_[i] = static_cast<uint8_t>(boxWidth);
    legendBoxX_[i] = static_cast<int16_t>(boxX);
    label.x = static_cast<int16_t>(boxX + (boxWidth - width) / 2);
    label.y = static_cast<int16_t>((i == 0 ? kLegendBoxTop : kLegendBoxBottom) + 3);
  }
  if (frame.batteryValid) {
    snprintf(text_[9].value, sizeof(text_[9].value), "%u%%",
             static_cast<unsigned>(frame.batteryPercent));
  } else {
    snprintf(text_[9].value, sizeof(text_[9].value), "--%%");
  }
  text_[9].x = 42;
  text_[9].y = 211;
  const unsigned fps = frame.fps > 999 ? 999 : frame.fps;
  snprintf(text_[10].value, sizeof(text_[10].value), "%uFPS", fps);
  text_[10].x = 72;
  text_[10].y = 211;
  if (!liveStatus_) text_[9].value[0] = text_[10].value[0] = '\0';
  batteryPercent_ = frame.batteryValid ? frame.batteryPercent : 0;
  batteryValid_ = frame.batteryValid;
  for (int level = 0; level < 256; ++level)
    legend_[level] = paletteColor(palette, static_cast<uint8_t>(level));

  trackingEnabled_ = false;
  const ThermalSpot candidates[] = {summary.extrema.hot, summary.extrema.cold};
  const bool enabled[] = {tracking.hot, tracking.cold};
  const bool labels[] = {tracking.hotTemperature, tracking.coldTemperature};
  const bool animate = mode == OverlayMode::Live;
  for (unsigned i = 0; i < spots_.size(); ++i) {
    auto& spot = spots_[i];
    const bool wasEnabled = spot.enabled;
    spot.enabled = frame.nucActive && summary.extrema.valid && enabled[i] &&
                   candidates[i].index < kVisiblePixelCount;
    spot.width = 0;
    if (!spot.enabled) {
      spot.lockInitialized = false;
      spot.candidateFrames = 0;
      continue;
    }
    if (!wasEnabled || !spot.lockInitialized) {
      spot.acceptedIndex = spot.candidateIndex = candidates[i].index;
      spot.acceptedTemperature = candidates[i].centiC;
      spot.candidateFrames = 0;
      spot.lockInitialized = true;
      spot.x = static_cast<int16_t>(((spot.acceptedIndex % kSensorWidth) * 8 + 4) / 3);
      spot.y = static_cast<int16_t>(((spot.acceptedIndex / kSensorWidth) * 8 + 4) / 3);
      spot.positionXQ8 = int32_t(spot.x) * kPositionScale;
      spot.positionYQ8 = int32_t(spot.y) * kPositionScale;
      spot.transitionTargetXQ8 = spot.positionXQ8;
      spot.transitionTargetYQ8 = spot.positionYQ8;
      spot.velocityXQ8PerSecond = spot.velocityYQ8PerSecond = 0;
      spot.transitionActive = false;
    } else {
      if (spot.transitionActive) {
        const uint32_t elapsed = frame.receivedAtMs - spot.transitionStartedAtMs;
        const MotionSample x = sampleMotion(spot.transitionFromXQ8,
            spot.transitionTargetXQ8, spot.transitionVelocityXQ8PerSecond, elapsed);
        const MotionSample y = sampleMotion(spot.transitionFromYQ8,
            spot.transitionTargetYQ8, spot.transitionVelocityYQ8PerSecond, elapsed);
        spot.positionXQ8 = x.positionQ8;
        spot.positionYQ8 = y.positionQ8;
        spot.velocityXQ8PerSecond = x.velocityQ8PerSecond;
        spot.velocityYQ8PerSecond = y.velocityQ8PerSecond;
        spot.x = roundedPixel(spot.positionXQ8);
        spot.y = roundedPixel(spot.positionYQ8);
        if (elapsed >= kTrackingTransitionMs) spot.transitionActive = false;
      }
      const uint16_t previousTarget = spot.acceptedIndex;
      if (candidates[i].index == spot.acceptedIndex) {
        // Keep the cursor stable while allowing the displayed temperature to
        // follow the same physical pixel without temporal lag.
        spot.acceptedTemperature = candidates[i].centiC;
        spot.candidateFrames = 0;
      } else if (candidates[i].index == spot.candidateIndex) {
        if (spot.candidateFrames < 2) ++spot.candidateFrames;
        if (spot.candidateFrames >= 2) {
          spot.acceptedIndex = candidates[i].index;
          spot.acceptedTemperature = candidates[i].centiC;
          spot.candidateFrames = 0;
        }
      } else {
        spot.candidateIndex = candidates[i].index;
        spot.candidateFrames = 1;
      }
      if (spot.acceptedIndex != previousTarget) {
        const int targetX = ((spot.acceptedIndex % kSensorWidth) * 8 + 4) / 3;
        const int targetY = ((spot.acceptedIndex / kSensorWidth) * 8 + 4) / 3;
        if (animate) {
          const int32_t targetXQ8 = targetX * kPositionScale;
          const int32_t targetYQ8 = targetY * kPositionScale;
          if (targetXQ8 != spot.transitionTargetXQ8 ||
              targetYQ8 != spot.transitionTargetYQ8) {
            spot.transitionFromXQ8 = spot.positionXQ8;
            spot.transitionFromYQ8 = spot.positionYQ8;
            spot.transitionTargetXQ8 = targetXQ8;
            spot.transitionTargetYQ8 = targetYQ8;
            spot.transitionVelocityXQ8PerSecond = spot.velocityXQ8PerSecond;
            spot.transitionVelocityYQ8PerSecond = spot.velocityYQ8PerSecond;
            spot.transitionStartedAtMs = frame.receivedAtMs;
            spot.transitionActive = spot.positionXQ8 != targetXQ8 ||
                spot.positionYQ8 != targetYQ8 ||
                spot.velocityXQ8PerSecond != 0 || spot.velocityYQ8PerSecond != 0;
          }
        } else {
          spot.x = static_cast<int16_t>(targetX);
          spot.y = static_cast<int16_t>(targetY);
          spot.positionXQ8 = targetX * kPositionScale;
          spot.positionYQ8 = targetY * kPositionScale;
          spot.transitionTargetXQ8 = spot.positionXQ8;
          spot.transitionTargetYQ8 = spot.positionYQ8;
          spot.velocityXQ8PerSecond = spot.velocityYQ8PerSecond = 0;
          spot.transitionActive = false;
        }
      }
    }
    const ThermalSpot point{spot.acceptedIndex, spot.acceptedTemperature};
    trackingEnabled_ = true;
    const int targetX = ((point.index % kSensorWidth) * 8 + 4) / 3;
    const int targetY = ((point.index / kSensorWidth) * 8 + 4) / 3;
    if (!animate) {
      spot.x = static_cast<int16_t>(targetX);
      spot.y = static_cast<int16_t>(targetY);
      spot.positionXQ8 = targetX * kPositionScale;
      spot.positionYQ8 = targetY * kPositionScale;
      spot.transitionTargetXQ8 = spot.positionXQ8;
      spot.transitionTargetYQ8 = spot.positionYQ8;
      spot.velocityXQ8PerSecond = spot.velocityYQ8PerSecond = 0;
      spot.transitionActive = false;
    }
    spot.color = i == 0 ? 0xF800 : 0x001F;
    if (!labels[i]) continue;
    temperature(spot.label.value, sizeof(spot.label.value), point.centiC, true, true,
                temperatureUnit_);
    spot.width = static_cast<uint8_t>(textWidth(spot.label.value) + 8);
    // Bounded candidate search once per frame; avoid stats, center label, legend,
    // the other label and the bottom live/album controls. Never search pixels.
    const int xs[] = {spot.x + 9, spot.x - spot.width - 9, spot.x - spot.width / 2,
                      spot.x - spot.width / 2, spot.x + 9, spot.x - spot.width - 9,
                      spot.x - spot.width / 2, spot.x - spot.width / 2,
                      kDebugLeft + kDebugWidth + 2, kDebugLeft + kDebugWidth + 2};
    const int ys[] = {spot.y - 9, spot.y - 9, spot.y + 9, spot.y - 27,
                      spot.y + 27, spot.y - 45, 64, 174, 64, 174};
    // A spot under the diagnostics can place its label immediately to the
    // right of the panel instead of exhausting candidates behind the text.
    for (unsigned candidate = 0; candidate < (showDebug_ ? 10U : 8U); ++candidate) {
      const int x = std::clamp(xs[candidate], 2, 318 - int(spot.width));
      const int y = std::clamp(ys[candidate], 2, 178);
      spot.label.x = x; spot.label.y = y;
      if (overlaps(x,y,spot.width,18,kStatsLeft,6,106,52) ||
          (showDebug_ && overlaps(x,y,spot.width,18,kDebugLeft,kDebugTop,
                                 kDebugWidth,kDebugHeight)) ||
          measurementLabelOverlaps(x,y,spot.width,18) ||
          overlaps(x,y,spot.width,18,288,kLegendBoxTop,32,
                   kLegendBoxBottom + kLegendBoxHeight - kLegendBoxTop)) continue;
      if (i && spots_[0].enabled && spots_[0].width &&
          overlaps(x,y,spot.width,18,spots_[0].label.x,spots_[0].label.y,spots_[0].width,18)) continue;
      break;
    }
  }
  // Cold/hot cursors and their temperatures belong to the full OSD.
  if (osdMode_ != OsdMode::Full) trackingEnabled_ = false;
}
void ThermalOverlay::renderRow(uint16_t y, uint16_t* pixels) const {
  if (showStats_) panelRow(y, kStatsLeft, kStatsTop, kStatsWidth, kStatsHeight, pixels);
  if (showLegend_) {
    panelRow(y, legendBoxX_[0], kLegendBoxTop, legendBoxWidth_[0], kLegendBoxHeight, pixels);
    panelRow(y, legendBoxX_[1], kLegendBoxBottom, legendBoxWidth_[1], kLegendBoxHeight, pixels);
  }
  if (showCenterTemperature_) {
    for (size_t i = 0; i < measurementCount_; ++i) {
      const auto& label = measurementLabels_[i];
      panelRow(y, label.text.x, label.text.y, label.width, 18, pixels);
      const int row = int(y) - label.text.y - 1;
      if (row >= 0 && row < kFontHeight)
        drawTextRow(label.text.value, label.text.x + 4, row, pixels);
    }
  }
  if (showInfo_) {
    panelRow(y, kInfoLeft, kInfoTop, kInfoWidth, kInfoHeight, pixels);
    batteryRow(y, batteryValid_, batteryPercent_, pixels);
    circleRow(y, kGearCenterX, kGearCenterY, kGearButtonRadius, pixels);
    circleRow(y, kAlbumCenterX, kAlbumCenterY, kAlbumButtonRadius, pixels);
  }
  if (showLegend_ && y >= kLegendTop - 1 && y <= kLegendBottom + 1) {
    if (y == kLegendTop - 1 || y == kLegendBottom + 1) {
      for (int x = 299; x <= 308; ++x) pixels[x] = 0xFFFF;
    } else {
      const unsigned level = 255 - (y - kLegendTop) * 255 /
                             (kLegendBottom - kLegendTop);
      for (int x = 300; x < 308; ++x) pixels[x] = legend_[level];
      pixels[299] = pixels[308] = 0xFFFF;
    }
  }
  for (unsigned index = 0; index < text_.size(); ++index) {
    const auto& text = text_[index];
    if (text.value[0] == '\0') continue;
    if (index < 6 && !showStats_) continue;
    if (index == 6 && !showCenterTemperature_) continue;
    if ((index == 7 || index == 8) && !showLegend_) continue;
    if ((index == 9 || index == 10) && !showInfo_) continue;
    const int row = static_cast<int>(y) - text.y;
    if (row < 0 || row >= kFontHeight) continue;
    drawTextRow(text.value, text.x, static_cast<unsigned>(row), pixels);
  }
  if (showCenterReticle_) {
    for (size_t i = 0; i < measurementCount_; ++i) {
      const auto& point = measurementLabels_[i];
      const int dy = int(y) - point.y;
      if (dy < -7 || dy > 7) continue;
      for (int dx = -7; dx <= 7; ++dx) {
      const int x = point.x + dx;
      if (x < 0 || x >= 320) continue;
      if (reticle(dx, dy)) {
        pixels[x] = 0xFFFF;
      } else if (reticle(dx - 1, dy) || reticle(dx + 1, dy) ||
                 reticle(dx, dy - 1) || reticle(dx, dy + 1)) {
        pixels[x] = ThermalOverlay::grayMask(pixels[x]);
      }
      }
    }
  }
  if (showInfo_ && y >= kGearCenterY - 8 && y <= kGearCenterY + 8) {
    const uint32_t bits = gearRows()[y - (kGearCenterY - 8)];
    for (int dx = -8; dx <= 8; ++dx)
      if (bits & (1UL << (dx + 8))) pixels[kGearCenterX + dx] = 0xFFFF;
  }
  if (showInfo_ && y >= kAlbumCenterY - 8 && y <= kAlbumCenterY + 8) {
    const uint32_t bits = albumRows()[y - (kAlbumCenterY - 8)];
    for (int dx = -8; dx <= 8; ++dx)
      if (bits & (1UL << (dx + 8))) pixels[kAlbumCenterX + dx] = 0xFFFF;
  }
  if (showInfo_ && countText_[0] != '\0' && y >= kAlbumCountTop &&
      y < kAlbumCountTop + kFontHeight) {
    drawTextRow(countText_, countTextX_, y - kAlbumCountTop, pixels);
  }
  renderTrackingRow(y, pixels);
  if (showDebug_) {
    panelRow(y, kDebugLeft, kDebugTop, kDebugWidth, kDebugHeight, pixels);
    for (const auto& text : debugText_) {
      const int row = static_cast<int>(y) - text.y;
      if (row >= 0 && row < kFontHeight)
        drawTextRow(text.value, text.x, static_cast<unsigned>(row), pixels);
    }
  }
  if (toastVisible_) renderToastRow(toastText_, y, pixels);
  if (calibrationBusy_) {
    for (int x = 0; x < kScreenWidth; ++x)
      pixels[x] = dimThermalBackdrop(pixels[x]);
    calibrationDialogRow(y, pixels, calibrationSpinnerPhase_);
  }
}
bool ThermalOverlay::measurementLabelOverlaps(int x, int y, int width, int height) const {
  if (!showCenterTemperature_) return false;
  for (size_t i = 0; i < measurementCount_; ++i) {
    const auto& label = measurementLabels_[i];
    if (overlaps(x, y, width, height, label.text.x, label.text.y, label.width, 18)) return true;
  }
  return false;
}
ThermalOverlay::ToastSpan ThermalOverlay::renderToastRow(
    const char* text, uint16_t y, uint16_t* pixels) {
  if (!text || !text[0] || !pixels || y < kToastTop || y >= kToastTop + kToastHeight)
    return {};
  const int width = textWidth(text) + 16;
  const int toastLeft = (kScreenWidth - width) / 2;
  const int row = static_cast<int>(y) - kToastTop;
  const int inset = row < 3 ? 3 - row :
      row >= kToastHeight - 3 ? row - (kToastHeight - 4) : 0;
  const int left = std::max(0, toastLeft + inset);
  const int right = std::min(kScreenWidth, toastLeft + width - inset);
  for (int x = left; x < right; ++x) {
    const bool edge = row == 0 || row == kToastHeight - 1 ||
                      x == left || x == right - 1;
    pixels[x] = edge ? kToastBorder : kToastSurface;
  }
  if (row >= 6 && row < 6 + kFontHeight)
    drawTextRow(text, toastLeft + 8, row - 6, pixels);
  return {static_cast<int16_t>(left), static_cast<int16_t>(right - left)};
}
void ThermalOverlay::renderTrackingRow(uint16_t y, uint16_t* pixels) const {
  if (!trackingEnabled_) return;
  for (const auto& spot : spots_) {
    if (!spot.enabled) continue;
    if (spot.width && y >= spot.label.y && y < spot.label.y + 18) {
      panelRow(y, spot.label.x, spot.label.y, spot.width, 18, pixels);
      const int row = int(y) - spot.label.y - 1;
      if (row >= 0 && row < kFontHeight)
        drawTextRow(spot.label.value, spot.label.x + 4, row, pixels);
      pixels[spot.label.x] = spot.color; // Match label to cursor without extra glyphs.
    }
  }
  // Draw cursors last so labels never cover them. White halo keeps blue/red
  // readable on every palette. At identical coordinates each owns half a cross.
  const bool coincident = spots_[0].enabled && spots_[1].enabled &&
      spots_[0].x == spots_[1].x && spots_[0].y == spots_[1].y;
  for (unsigned i = 0; i < spots_.size(); ++i) {
    const auto& spot = spots_[i];
    const int dy = int(y) - spot.y;
    if (!spot.enabled || dy < -7 || dy > 7) continue;
    for (int dx = -7; dx <= 7; ++dx) {
      const int x = spot.x + dx;
      if (x < 0 || x >= 320) continue;
      const int ax = std::abs(dx), ay = std::abs(dy);
      const bool ink = (ax <= 1 && ay >= 3 && ay <= 6) ||
                       (ay <= 1 && ax >= 3 && ax <= 6);
      const bool halo = (ax <= 2 && ay >= 2 && ay <= 7) ||
                        (ay <= 2 && ax >= 2 && ax <= 7);
      if (coincident && ((i == 0 && (dx > 0 || dy > 0)) ||
                         (i == 1 && (dx <= 0 && dy <= 0)))) continue;
      if (ink) pixels[x] = spot.color;
      else if (halo) pixels[x] = 0xFFFF;
    }
  }
}
}  // namespace cb360
