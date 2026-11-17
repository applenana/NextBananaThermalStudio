#include "cb360/photo.h"
#include "cb360/nuc.h"
#include "cb360/parameter_line.h"
#include "cb360/stripe_suppression.h"
#include "cb360/temperature.h"
#include "cb360/view.h"
#include <algorithm>

namespace cb360 {
namespace {
TemperatureAdjustments photoAdjustments(const Settings& settings) {
  TemperatureAdjustments adjustments{};
  adjustments.emissivity = settings.emissivityPercent / 100.0f;
  adjustments.reflectedC = settings.reflectedTemperatureC;
  adjustments.offsetCentiC = settings.temperatureOffsetCentiC;
  adjustments.farDistance = settings.distanceMode == DistanceMode::Far;
  return adjustments;
}
constexpr uint8_t distanceSlot(const Settings& settings) {
  return settings.distanceMode == DistanceMode::Far ? 1 : 0;
}
int16_t pointY16(const DisplayFrame& frame, uint16_t x, uint16_t y,
                 CenterRegion region) {
  x = static_cast<uint16_t>((uint32_t(x) * 2 + 1) * kSensorWidth / 640);
  y = static_cast<uint16_t>((uint32_t(y) * 2 + 1) * kVisibleHeight / 480);
  const int radius = region == CenterRegion::Median5x5 ? 2
      : region == CenterRegion::Median3x3 ? 1 : 0;
  int16_t samples[25]; size_t count = 0;
  for (int dy = -radius; dy <= radius; ++dy) {
    const int py = std::clamp<int>(int(y) + dy, 0, kVisibleHeight - 1);
    for (int dx = -radius; dx <= radius; ++dx) {
      const int px = std::clamp<int>(int(x) + dx, 0, kSensorWidth - 1);
      samples[count++] = frame.pixels[size_t(py) * kSensorWidth + px];
    }
  }
  std::nth_element(samples, samples + count / 2, samples + count);
  return samples[count / 2];
}
int16_t selectCenteredY16(const DisplayFrame& frame, int32_t averageReference,
                          size_t rank) {
  uint16_t counts[256]{};
  for (int16_t value : frame.pixels) {
    const uint16_t ordered = static_cast<uint16_t>(
        wrapSigned16(int32_t(value) - averageReference)) ^ 0x8000;
    ++counts[ordered >> 8];
  }
  size_t before = 0;
  uint16_t bucket = 0;
  for (; bucket < 256; ++bucket) {
    if (rank < before + counts[bucket]) break;
    before += counts[bucket];
  }
  std::fill(counts, counts + 256, 0);
  for (int16_t value : frame.pixels) {
    const uint16_t ordered = static_cast<uint16_t>(
        wrapSigned16(int32_t(value) - averageReference)) ^ 0x8000;
    if ((ordered >> 8) == bucket) ++counts[ordered & 0xFF];
  }
  size_t lowRank = rank - before;
  uint16_t low = 0;
  for (; low < 256; ++low) {
    if (lowRank < counts[low]) break;
    lowRank -= counts[low];
  }
  const uint16_t ordered = static_cast<uint16_t>((bucket << 8) | low) ^ 0x8000;
  return static_cast<int16_t>(ordered);
}
bool invertPhotoTemperature(int16_t target, const uint16_t* curve,
                            const Parameters& parameters,
                            const TemperatureAdjustments& adjustments,
                            int16_t& centered) {
  int16_t lowTemperature = 0, highTemperature = 0;
  if (!estimatePixelTemperature(INT16_MIN, curve, parameters, adjustments, lowTemperature) ||
      !estimatePixelTemperature(INT16_MAX, curve, parameters, adjustments, highTemperature) ||
      highTemperature < lowTemperature) return false;
  int32_t low = INT16_MIN, high = INT16_MAX;
  if (target <= lowTemperature) { centered = INT16_MIN; return true; }
  if (target > highTemperature) { centered = INT16_MAX; return true; }
  while (low < high) {
    const int32_t middle = low + (high - low) / 2;
    int16_t temperature = 0;
    if (!estimatePixelTemperature(static_cast<int16_t>(middle), curve, parameters,
                                  adjustments, temperature)) return false;
    if (temperature < target) low = middle + 1;
    else high = middle;
  }
  centered = static_cast<int16_t>(low);
  return true;
}
bool mapTemperatureRange(int16_t lowTemperature, int16_t highTemperature,
                        const uint16_t* curve, const Parameters& parameters,
                        const TemperatureAdjustments& adjustments,
                        int32_t averageReference, int16_t& lowY16,
                        int16_t& highY16) {
  int16_t lowCentered = 0, highCentered = 0;
  if (!invertPhotoTemperature(lowTemperature, curve, parameters, adjustments, lowCentered) ||
      !invertPhotoTemperature(highTemperature, curve, parameters, adjustments, highCentered))
    return false;
  const int32_t lowRaw = int32_t(lowCentered) + averageReference;
  const int32_t highRaw = int32_t(highCentered) + averageReference;
  if (lowRaw < INT16_MIN || lowRaw > INT16_MAX || highRaw < INT16_MIN ||
      highRaw > INT16_MAX || lowRaw == highRaw) return false;
  lowY16 = static_cast<int16_t>(std::min(lowRaw, highRaw));
  highY16 = static_cast<int16_t>(std::max(lowRaw, highRaw));
  return true;
}
} // namespace

const char* photoResultText(PhotoResult result) {
  switch (result) {
    case PhotoResult::Ok: return "OK";
    case PhotoResult::InvalidArgument: return "Invalid capture";
    case PhotoResult::NotReady: return "Storage unavailable";
    case PhotoResult::NotFound: return "Photo not found";
    case PhotoResult::NoSpace: return "Storage full";
    case PhotoResult::IoError: return "Storage error";
    case PhotoResult::Corrupt: return "Damaged photo";
    case PhotoResult::UnsupportedVersion: return "Unsupported photo";
    case PhotoResult::IdExhausted: return "Photo ID limit";
    case PhotoResult::Canceled: return "Canceled";
    case PhotoResult::CalibrationMismatch: return "Current curve is unavailable";
  }
  return "Unknown error";
}

PhotoInfo describePhoto(const DisplayFrame& f, const Settings&,
                        const Parameters& parameters, const TemperatureCurves& curves,
                        uint64_t timestamp) {
  PhotoInfo p;
  p.capturedAtUnixMs = timestamp;
  p.sequence = f.sequence;
  p.curveIndex = selectTemperatureCurveIndex(parameters, curves);
  return p;
}

bool validPhotoInfo(const PhotoInfo& p) {
  return p.curveIndex < kMaximumCurveCount;
}

bool validPhotoCurve(const uint16_t* curve) {
  if (!curve || curve[0] >= curve[kCurvePoints - 1]) return false;
  for (size_t i = 1; i < kCurvePoints; ++i)
    if (curve[i] < curve[i - 1]) return false;
  return true;
}

bool photoTemperature(const PhotoInfo& p, const PhotoRenderConfig& config,
                      const TemperatureCurves& curves, int16_t y16,
                      int16_t& centiC) {
  if (!validPhotoInfo(p) || config.settings.emissivityPercent < 10 ||
      config.settings.emissivityPercent > 100) return false;
  const uint16_t* curve = temperatureCurveAt(curves, p.curveIndex,
                                              distanceSlot(config.settings));
  if (!validPhotoCurve(curve)) return false;
  return estimatePixelTemperature(wrapSigned16(int32_t(y16) - config.averageReference),
      curve, config.parameters, photoAdjustments(config.settings), centiC);
}

PhotoResult restorePhotoFrame(const PhotoInfo& p, const PhotoRenderConfig& config,
                              const TemperatureCurves& curves, DisplayFrame& f) {
  if (!validPhotoInfo(p) || config.settings.emissivityPercent < 10 ||
      config.settings.emissivityPercent > 100 ||
      config.measurements.count > kMaximumMeasurementPoints)
    return PhotoResult::InvalidArgument;
  const uint16_t* curve = temperatureCurveAt(curves, p.curveIndex,
                                              distanceSlot(config.settings));
  if (!validPhotoCurve(curve)) return PhotoResult::CalibrationMismatch;
  const TemperatureAdjustments adjustments = photoAdjustments(config.settings);
  ExtremaAccumulator extrema;
  for (size_t i = 0; i < f.pixels.size(); ++i) {
    const int16_t centered = wrapSigned16(int32_t(f.pixels[i]) - config.averageReference);
    extrema.observe(centered, static_cast<uint16_t>(i));
  }
  int16_t lowTemperature = 0, highTemperature = 0;
  if (!estimatePixelTemperature(extrema.low, curve, config.parameters, adjustments, lowTemperature) ||
      !estimatePixelTemperature(extrema.high, curve, config.parameters, adjustments, highTemperature))
    return PhotoResult::InvalidArgument;
  f.sequence = p.sequence;
  f.receivedAtMs = 0;
  f.fpaCentiC = config.parameters.fpaCentiC;
  f.fps = 0; f.batteryPercent = 0; f.batteryValid = false; f.kIndex = 0;
  f.nucActive = true; f.pixelDomain = DisplayFrame::PixelDomain::Y16;
  f.temperatures = {};
  f.temperatures.valid = true;
  f.temperatures.extrema = extrema.temperatures(lowTemperature, highTemperature);
  f.temperatures.minimumCentiC = std::min(lowTemperature, highTemperature);
  f.temperatures.maximumCentiC = std::max(lowTemperature, highTemperature);
  int16_t lowerMedian = 0, upperMedian = 0;
  if (!estimatePixelTemperature(selectCenteredY16(f, config.averageReference,
          (kVisiblePixelCount - 1) / 2), curve, config.parameters, adjustments, lowerMedian) ||
      !estimatePixelTemperature(selectCenteredY16(f, config.averageReference,
          kVisiblePixelCount / 2), curve, config.parameters, adjustments, upperMedian))
    return PhotoResult::InvalidArgument;
  f.temperatures.centerCentiC = 0;
  f.temperatures.medianCentiC = static_cast<int16_t>(
      (int32_t(lowerMedian) + upperMedian) / 2);
  f.temperatures.legendCentiC = {f.temperatures.maximumCentiC,
      static_cast<int16_t>((int32_t(f.temperatures.minimumCentiC) +
                            f.temperatures.maximumCentiC) / 2),
      f.temperatures.minimumCentiC};
  f.temperatures.legendValidMask = 7;
  f.measurements = config.measurements;
  if (f.measurements.count > kMaximumMeasurementPoints) return PhotoResult::InvalidArgument;
  for (size_t i = 0; i < f.measurements.count; ++i) {
    auto& point = f.measurements.points[i];
    if (point.x >= 320 || point.y >= 240) return PhotoResult::InvalidArgument;
    point.valid = estimatePixelTemperature(
        wrapSigned16(int32_t(pointY16(f, point.x, point.y, config.settings.centerRegion)) -
                     config.averageReference), curve, config.parameters, adjustments,
        point.centiC);
  }
  f.centerTemperatureValid = estimatePixelTemperature(
      wrapSigned16(int32_t(pointY16(f, 160, 120, config.settings.centerRegion)) -
                   config.averageReference), curve, config.parameters, adjustments,
      f.centerTemperatureCentiC);
  if (!f.centerTemperatureValid) f.centerTemperatureCentiC = 0;
  f.temperatures.centerCentiC = f.centerTemperatureCentiC;
  if (config.settings.manualRangeEnabled &&
      config.settings.manualRangeHighCentiC > config.settings.manualRangeLowCentiC) {
    if (!mapTemperatureRange(config.settings.manualRangeLowCentiC,
        config.settings.manualRangeHighCentiC, curve, config.parameters, adjustments,
        config.averageReference, f.rangeLow, f.rangeHigh))
      return PhotoResult::InvalidArgument;
  } else {
    bool lowContrast = false, initialized = false;
    int16_t mappedLow = 0, mappedHigh = 0;
    if (updateLowContrastRange(lowContrast, initialized,
        f.temperatures.minimumCentiC, f.temperatures.maximumCentiC,
        config.settings.minimumMappedRangeCentiC, config.settings.rangeResponse,
        mappedLow, mappedHigh) && lowContrast) {
      if (!mapTemperatureRange(mappedLow, mappedHigh, curve, config.parameters,
          adjustments, config.averageReference, f.rangeLow, f.rangeHigh))
        return PhotoResult::InvalidArgument;
    } else {
      calculateDisplayRange(f.pixels.data(), f.rangeLow, f.rangeHigh);
    }
  }
  f.deferredStripes = false;
  StripeSuppressor stripes;
  stripes.apply(f.pixels.data(), kSensorWidth, kVisibleHeight, 64);
  return PhotoResult::Ok;
}
} // namespace cb360
