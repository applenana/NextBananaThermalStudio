#include "starthermal/view.h"
#include "starthermal/config.h"
#include "starthermal/nuc.h"
#include "starthermal/parameter_line.h"
#include "starthermal/temperature.h"

#include <algorithm>
#include <array>

namespace starthermal {
namespace {
TemperatureMapper& sharedTemperatureMapper() {
  static TemperatureMapper mapper;
  return mapper;
}

int16_t midpointCentiC(int16_t first, int16_t second) {
  const int32_t sum = static_cast<int32_t>(first) + second;
  return static_cast<int16_t>((sum + (sum < 0 ? -1 : 1)) / 2);
}

TemperatureAdjustments defaults(float emissivity) {
  TemperatureAdjustments adjustments{};
  adjustments.emissivity = emissivity;
  return adjustments;
}

int centerRegionRadius(CenterRegion region) {
  switch (region) {
    case CenterRegion::Single: return 0;
    case CenterRegion::Median3x3: return 1;
    case CenterRegion::Median5x5: return 2;
  }
  return 0;
}

int16_t medianOfCentered(const int16_t* corrected, int32_t averageReference,
                         int radius, int centerX = kSensorWidth / 2,
                         int centerY = kVisibleHeight / 2) {
  std::array<int16_t, 25> window{};
  size_t count = 0;
  for (int dy = -radius; dy <= radius; ++dy) {
    const int y = std::clamp(centerY + dy, 0, static_cast<int>(kVisibleHeight) - 1);
    const size_t row = static_cast<size_t>(y + kVisibleFirstRow) * kSensorWidth;
    for (int dx = -radius; dx <= radius; ++dx) {
      const int x = std::clamp(centerX + dx, 0, static_cast<int>(kSensorWidth) - 1);
      window[count++] = wrapSigned16(
          static_cast<int32_t>(corrected[row + x]) - averageReference);
    }
  }
  // Small windows (<=25 values): insertion sort keeps the frame cost tiny.
  for (size_t i = 1; i < count; ++i) {
    const int16_t value = window[i];
    size_t j = i;
    while (j > 0 && window[j - 1] > value) {
      window[j] = window[j - 1];
      --j;
    }
    window[j] = value;
  }
  return window[count / 2];
}

int16_t smoothedRangeValue(int16_t previous, int32_t target,
                           RangeResponse response) {
  const int oldWeight = response == RangeResponse::Fast ? 1
      : response == RangeResponse::Stable ? 7 : 3;
  const int32_t numerator = static_cast<int32_t>(previous) * oldWeight + target;
  const int32_t value = numerator / (oldWeight + 1);
  return static_cast<int16_t>(value);
}

bool calculateTemperatureRangeImpl(const int16_t* corrected,
                                   const Parameters& parameters,
                                   const TemperatureCurves& curves,
                                   int32_t averageReference,
                                   const TemperatureAdjustments& adjustments,
                                   int16_t* temperaturePixels,
                                   int16_t& lowCentiC, int16_t& highCentiC) {
  if (corrected == nullptr || temperaturePixels == nullptr) return false;
  int16_t low = INT16_MAX, high = INT16_MIN;
  const uint16_t* curve =
      selectTemperatureCurve(parameters, curves, adjustments.farDistance);
  for (uint16_t y = 0; y < kVisibleHeight; ++y) {
    const size_t row = static_cast<size_t>(y + kVisibleFirstRow) * kSensorWidth;
    for (uint16_t x = 0; x < kSensorWidth; ++x) {
      const int16_t centered = wrapSigned16(
          static_cast<int32_t>(corrected[row + x]) - averageReference);
      int16_t temperature = 0;
      if (!estimatePixelTemperature(centered, curve, parameters, adjustments,
                                    temperature)) return false;
      temperaturePixels[static_cast<size_t>(y) * kSensorWidth + x] = temperature;
      low = std::min(low, temperature);
      high = std::max(high, temperature);
    }
  }
  lowCentiC = low;
  highCentiC = high;
  return true;
}

bool calculateTemperatureBoundsImpl(const int16_t* corrected,
                                    const Parameters& parameters,
                                    const TemperatureCurves& curves,
                                    int32_t averageReference,
                                    const TemperatureAdjustments& adjustments,
                                    int16_t& lowCentiC, int16_t& highCentiC) {
  if (corrected == nullptr) return false;
  int16_t lowY16 = INT16_MAX, highY16 = INT16_MIN;
  for (uint16_t y = 0; y < kVisibleHeight; ++y) {
    const size_t row = static_cast<size_t>(y + kVisibleFirstRow) * kSensorWidth;
    for (uint16_t x = 0; x < kSensorWidth; ++x) {
      const int16_t centered = wrapSigned16(
          static_cast<int32_t>(corrected[row + x]) - averageReference);
      lowY16 = std::min(lowY16, centered);
      highY16 = std::max(highY16, centered);
    }
  }

  const uint16_t* curve =
      selectTemperatureCurve(parameters, curves, adjustments.farDistance);
  int16_t endpointA = 0, endpointB = 0;
  if (!estimatePixelTemperature(lowY16, curve, parameters, adjustments, endpointA) ||
      !estimatePixelTemperature(highY16, curve, parameters, adjustments, endpointB))
    return false;
  lowCentiC = std::min(endpointA, endpointB);
  highCentiC = std::max(endpointA, endpointB);
  return true;
}

bool calculateY16DisplayRangeImpl(const Parameters& parameters,
                                  const TemperatureCurves& curves,
                                  int32_t averageReference,
                                  const TemperatureAdjustments& adjustments,
                                  int16_t lowCentiC, int16_t highCentiC,
                                  int16_t& lowY16, int16_t& highY16) {
  if (highCentiC <= lowCentiC) return false;
  TemperatureMapper& mapper = sharedTemperatureMapper();
  if (!mapper.prepare(parameters, curves, adjustments)) return false;
  int16_t centeredA = 0, centeredB = 0;
  if (!mapper.invert(lowCentiC, centeredA) ||
      !mapper.invert(highCentiC, centeredB)) return false;
  const int32_t rawA = static_cast<int32_t>(centeredA) + averageReference;
  const int32_t rawB = static_cast<int32_t>(centeredB) + averageReference;
  if (rawA < INT16_MIN || rawA > INT16_MAX ||
      rawB < INT16_MIN || rawB > INT16_MAX || rawA == rawB) return false;
  lowY16 = static_cast<int16_t>(std::min(rawA, rawB));
  highY16 = static_cast<int16_t>(std::max(rawA, rawB));
  return true;
}

template <bool TrackExtrema>
bool calculateTemperatureSummaryImpl(const int16_t* corrected,
                                     const Parameters& parameters,
                                     const TemperatureCurves& curves,
                                     int32_t averageReference,
                                     const TemperatureAdjustments& adjustments,
                                     CenterRegion centerRegion,
                                     int16_t* scratchPixels,
                                     TemperatureSummary& summary, bool measureCenter) {
  summary = {};
  if (corrected == nullptr || scratchPixels == nullptr) return false;
  TemperatureMapper& mapper = sharedTemperatureMapper();
  if (!mapper.prepare(parameters, curves, adjustments)) return false;

  int16_t lowCentered = INT16_MAX, highCentered = INT16_MIN;
  for (uint16_t y = 0; y < kVisibleHeight; ++y) {
    const size_t sourceRow = static_cast<size_t>(y + kVisibleFirstRow) * kSensorWidth;
    const size_t outputRow = static_cast<size_t>(y) * kSensorWidth;
    for (uint16_t x = 0; x < kSensorWidth; ++x) {
      const int16_t centered = wrapSigned16(
          static_cast<int32_t>(corrected[sourceRow + x]) - averageReference);
      scratchPixels[outputRow + x] = centered;
      lowCentered = std::min(lowCentered, centered);
      highCentered = std::max(highCentered, centered);
    }
  }

  int16_t lowTemperature = 0;
  int16_t highTemperature = 0;
  if (!mapper.convert(lowCentered, lowTemperature) ||
      !mapper.convert(highCentered, highTemperature)) return false;

  ThermalExtrema trackedExtrema{};
  if constexpr (TrackExtrema) {
    ExtremaAccumulator extrema;
    for (size_t i = 0; i < kVisiblePixelCount; ++i)
      extrema.observe(scratchPixels[i], static_cast<uint16_t>(i));
    trackedExtrema = extrema.temperatures(lowTemperature, highTemperature);
  }

  int16_t* middle = scratchPixels + kVisiblePixelCount / 2;
  std::nth_element(scratchPixels, middle,
                   scratchPixels + kVisiblePixelCount);
  const int16_t lowerMedianCentered = *std::max_element(scratchPixels, middle);
  const int16_t upperMedianCentered = *middle;
  int16_t lowerMedianTemperature = 0;
  int16_t upperMedianTemperature = 0;
  if (!mapper.convert(lowerMedianCentered, lowerMedianTemperature) ||
      !mapper.convert(upperMedianCentered, upperMedianTemperature)) return false;

  int16_t centerTemperature = 0;
  if (measureCenter && !mapper.convert(medianOfCentered(corrected,
      averageReference, centerRegionRadius(centerRegion)), centerTemperature)) return false;

  summary.valid = true;
  summary.extrema = trackedExtrema;
  summary.minimumCentiC = std::min(lowTemperature, highTemperature);
  summary.maximumCentiC = std::max(lowTemperature, highTemperature);
  summary.medianCentiC = midpointCentiC(lowerMedianTemperature,
                                        upperMedianTemperature);
  summary.centerCentiC = centerTemperature;
  summary.legendCentiC = {summary.maximumCentiC,
      midpointCentiC(summary.minimumCentiC, summary.maximumCentiC),
      summary.minimumCentiC};
  summary.legendValidMask = 7;
  return true;
}

bool updateLowContrastRangeImpl(bool& lowContrastMode, bool& initialized,
                                int16_t temperatureLow, int16_t temperatureHigh,
                                int16_t minimumMappedRangeCentiC,
                                RangeResponse response,
                                int16_t& smoothedLow, int16_t& smoothedHigh) {
  if (temperatureHigh < temperatureLow) return false;
  const bool firstRange = !initialized;
  const bool wasLowContrast = lowContrastMode;
  const int32_t spread = static_cast<int32_t>(temperatureHigh) - temperatureLow;
  if (!initialized) {
    lowContrastMode = spread <= minimumMappedRangeCentiC;
  } else if (lowContrastMode) {
    if (spread >= static_cast<int32_t>(minimumMappedRangeCentiC) +
                  config::kLowContrastHysteresisCentiC)
      lowContrastMode = false;
  } else if (spread <= minimumMappedRangeCentiC) {
    lowContrastMode = true;
  }
  initialized = true;
  if (!lowContrastMode) return true;
  const bool enteringLowContrast = firstRange || !wasLowContrast;
  const int32_t targetSpan = std::max<int32_t>(minimumMappedRangeCentiC, spread);
  const int32_t lowNumerator = static_cast<int32_t>(temperatureLow) +
      temperatureHigh - targetSpan;
  const int32_t targetLow = lowNumerator >= 0 ? lowNumerator / 2
                                               : (lowNumerator - 1) / 2;
  const int32_t targetHigh = targetLow + targetSpan;
  if (targetHigh <= targetLow) return false;
  if (enteringLowContrast || smoothedHigh <= smoothedLow) {
    smoothedLow = static_cast<int16_t>(targetLow);
    smoothedHigh = static_cast<int16_t>(targetHigh);
  } else {
    smoothedLow = smoothedRangeValue(smoothedLow, targetLow, response);
    smoothedHigh = smoothedRangeValue(smoothedHigh, targetHigh, response);
    if (smoothedHigh <= smoothedLow) smoothedHigh = smoothedLow + 1;
  }
  if (static_cast<int32_t>(smoothedHigh) - smoothedLow < targetSpan) {
    smoothedLow = static_cast<int16_t>(targetLow);
    smoothedHigh = static_cast<int16_t>(targetHigh);
  }
  return true;
}
}  // namespace

bool calculateTemperatureRange(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference, float emissivity,
                               int16_t* temperaturePixels,
                               int16_t& lowCentiC, int16_t& highCentiC) {
  return calculateTemperatureRangeImpl(corrected, parameters, curves,
                                       averageReference, defaults(emissivity),
                                       temperaturePixels, lowCentiC, highCentiC);
}

bool calculateTemperatureRange(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference,
                               const TemperatureAdjustments& adjustments,
                               int16_t* temperaturePixels,
                               int16_t& lowCentiC, int16_t& highCentiC) {
  return calculateTemperatureRangeImpl(corrected, parameters, curves,
                                       averageReference, adjustments,
                                       temperaturePixels, lowCentiC, highCentiC);
}

bool calculateTemperatureBounds(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference, float emissivity,
                               int16_t& lowCentiC, int16_t& highCentiC) {
  return calculateTemperatureBoundsImpl(corrected, parameters, curves,
                                        averageReference, defaults(emissivity),
                                        lowCentiC, highCentiC);
}

bool calculateTemperatureBounds(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference,
                               const TemperatureAdjustments& adjustments,
                               int16_t& lowCentiC, int16_t& highCentiC) {
  return calculateTemperatureBoundsImpl(corrected, parameters, curves,
                                        averageReference, adjustments,
                                        lowCentiC, highCentiC);
}

bool calculateY16DisplayRange(const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference, float emissivity,
                              int16_t lowCentiC, int16_t highCentiC,
                              int16_t& lowY16, int16_t& highY16) {
  return calculateY16DisplayRangeImpl(parameters, curves, averageReference,
                                      defaults(emissivity), lowCentiC,
                                      highCentiC, lowY16, highY16);
}

bool calculateY16DisplayRange(const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference,
                              const TemperatureAdjustments& adjustments,
                              int16_t lowCentiC, int16_t highCentiC,
                              int16_t& lowY16, int16_t& highY16) {
  return calculateY16DisplayRangeImpl(parameters, curves, averageReference,
                                      adjustments, lowCentiC, highCentiC,
                                      lowY16, highY16);
}

bool calculateTemperatureSummary(const int16_t* corrected,
                                 const Parameters& parameters,
                                 const TemperatureCurves& curves,
                                 int32_t averageReference, float emissivity,
                                 int16_t* scratchPixels,
                                 TemperatureSummary& summary,
                                 bool trackExtrema) {
  return calculateTemperatureSummary(
      corrected, parameters, curves, averageReference, defaults(emissivity),
      CenterRegion::Single, scratchPixels, summary, trackExtrema);
}

bool calculateTemperatureSummary(const int16_t* corrected,
                                 const Parameters& parameters,
                                 const TemperatureCurves& curves,
                                 int32_t averageReference,
                                 const TemperatureAdjustments& adjustments,
                                 CenterRegion centerRegion,
                                 int16_t* scratchPixels,
                                 TemperatureSummary& summary,
                                 bool trackExtrema, bool measureCenter) {
  return trackExtrema
      ? calculateTemperatureSummaryImpl<true>(corrected, parameters, curves,
          averageReference, adjustments, centerRegion, scratchPixels, summary, measureCenter)
      : calculateTemperatureSummaryImpl<false>(corrected, parameters, curves,
          averageReference, adjustments, centerRegion, scratchPixels, summary, measureCenter);
}

bool calculateMeasurementPoints(const int16_t* corrected,
    const Parameters& parameters, const TemperatureCurves& curves,
    int32_t averageReference, const TemperatureAdjustments& adjustments,
    CenterRegion region, const PointMeasurements& selection,
    PointMeasurements& output, size_t* convertedCount) {
  output = selection;
  if (convertedCount) *convertedCount = 0;
  for (auto& point : output.points) { point.valid = false; point.centiC = 0; }
  if (selection.count > kMaximumMeasurementPoints ||
      static_cast<unsigned>(selection.mode) > 1 ||
      (selection.mode == MeasurementMode::Single && selection.count > 1)) return false;
  for (size_t i = 0; i < selection.count; ++i)
    if (selection.points[i].x >= 320 || selection.points[i].y >= 240) return false;
  if (!selection.count) return true;
  if (!corrected) return false;
  TemperatureMapper& mapper = sharedTemperatureMapper();
  if (!mapper.prepare(parameters, curves, adjustments)) return false;
  for (size_t i = 0; i < selection.count; ++i) {
    auto& point = output.points[i];
    const int x = (point.x * 2 + 1) * kSensorWidth / 640;
    const int y = (point.y * 2 + 1) * kVisibleHeight / 480;
    const int16_t sample = medianOfCentered(corrected, averageReference,
        centerRegionRadius(region), x, y);
    if (!mapper.convert(sample, point.centiC)) return false;
    point.valid = true;
    if (convertedCount) ++*convertedCount;
  }
  return true;
}

bool convertTemperaturePixels(const int16_t* corrected,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference, float emissivity,
                              int16_t* temperaturePixels,
                              TemperatureSummary* summary) {
  return convertTemperaturePixels(corrected, parameters, curves,
                                  averageReference, defaults(emissivity),
                                  CenterRegion::Single, temperaturePixels,
                                  summary);
}

bool convertTemperaturePixels(const int16_t* corrected,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference,
                              const TemperatureAdjustments& adjustments,
                              CenterRegion centerRegion,
                              int16_t* temperaturePixels,
                              TemperatureSummary* summary) {
  if (summary) *summary = {};
  if (corrected == nullptr || temperaturePixels == nullptr) return false;
  TemperatureMapper& mapper = sharedTemperatureMapper();
  if (summary && !calculateTemperatureSummary(
          corrected, parameters, curves, averageReference, adjustments,
          centerRegion, temperaturePixels, *summary)) return false;
  if (!mapper.prepare(parameters, curves, adjustments)) return false;
  for (uint16_t y = 0; y < kVisibleHeight; ++y) {
    const size_t sourceRow = static_cast<size_t>(y + kVisibleFirstRow) * kSensorWidth;
    const size_t outputRow = static_cast<size_t>(y) * kSensorWidth;
    for (uint16_t x = 0; x < kSensorWidth; ++x) {
      const int16_t centered = wrapSigned16(
          static_cast<int32_t>(corrected[sourceRow + x]) - averageReference);
      if (!mapper.convert(centered, temperaturePixels[outputRow + x]))
        return false;
    }
  }
  return true;
}

bool updateLowContrastRange(bool& lowContrastMode, bool& initialized,
                            int16_t temperatureLow, int16_t temperatureHigh,
                            int16_t minimumMappedRangeCentiC,
                            int16_t& smoothedLow, int16_t& smoothedHigh) {
  return updateLowContrastRangeImpl(lowContrastMode, initialized,
                                    temperatureLow, temperatureHigh,
                                    minimumMappedRangeCentiC,
                                    RangeResponse::Standard, smoothedLow,
                                    smoothedHigh);
}

bool updateLowContrastRange(bool& lowContrastMode, bool& initialized,
                            int16_t temperatureLow, int16_t temperatureHigh,
                            int16_t minimumMappedRangeCentiC,
                            RangeResponse response,
                            int16_t& smoothedLow, int16_t& smoothedHigh) {
  return updateLowContrastRangeImpl(lowContrastMode, initialized,
                                    temperatureLow, temperatureHigh,
                                    minimumMappedRangeCentiC, response,
                                    smoothedLow, smoothedHigh);
}

uint16_t visibleSourceIndex(uint16_t x, uint16_t y) {
  if (x >= kSensorWidth || y >= kVisibleHeight) return UINT16_MAX;
  return static_cast<uint16_t>((y + kVisibleFirstRow) * kSensorWidth + x);
}

void copyVisibleRegion(const int16_t* source, int16_t* destination) {
  for (uint16_t y = 0; y < kVisibleHeight; ++y) {
    const size_t sourceIndex = static_cast<size_t>(y + kVisibleFirstRow) *
                               kSensorWidth;
    const size_t destinationIndex = static_cast<size_t>(y) * kSensorWidth;
    std::copy(source + sourceIndex, source + sourceIndex + kSensorWidth,
              destination + destinationIndex);
  }
}

void calculateDisplayRange(const int16_t* pixels, int16_t& low, int16_t& high) {
  low = INT16_MAX;
  high = INT16_MIN;
  for (size_t i = 0; i < kVisiblePixelCount; ++i) {
    low = std::min(low, pixels[i]);
    high = std::max(high, pixels[i]);
  }
  if (high <= low && low < INT16_MAX) high = low + 1;
}

uint16_t paletteColor(Palette palette, uint8_t level) {
  uint8_t red = 0;
  uint8_t green = 0;
  uint8_t blue = 0;
  if (palette == Palette::WhiteHot) {
    red = green = blue = level;
  } else if (palette == Palette::BlackHot) {
    red = green = blue = static_cast<uint8_t>(255 - level);
  } else {
    constexpr int ironPositions[] = {0, 22, 48, 72, 90, 100};
    constexpr int iron[][3] = {{12, 9, 24}, {88, 12, 48}, {190, 35, 28},
        {250, 142, 28}, {255, 226, 92}, {255, 255, 238}};
    constexpr int rainbowPositions[] = {0, 20, 40, 60, 80, 100};
    constexpr int rainbow[][3] = {{42, 62, 112}, {58, 126, 166},
        {92, 166, 142}, {177, 185, 104}, {220, 151, 92}, {190, 78, 76}};
    constexpr int arcticPositions[] = {0, 22, 46, 68, 84, 100};
    constexpr int arctic[][3] = {{18, 27, 54}, {35, 73, 112},
        {72, 132, 158}, {145, 180, 151}, {225, 198, 117}, {245, 243, 220}};
    constexpr int lavaPositions[] = {0, 20, 42, 62, 82, 100};
    constexpr int lava[][3] = {{12, 21, 59}, {30, 69, 139},
        {94, 91, 139}, {183, 91, 92}, {239, 151, 68}, {255, 242, 198}};
    const int* positions = ironPositions;
    const int (*colors)[3] = iron;
    int lastSegment = 4;
    if (palette == Palette::Rainbow) {
      positions = rainbowPositions; colors = rainbow;
    } else if (palette == Palette::Arctic) {
      positions = arcticPositions; colors = arctic;
    } else if (palette == Palette::Lava) {
      positions = lavaPositions; colors = lava;
    }
    int segment = 0;
    while (segment < lastSegment && level * 100 > positions[segment + 1] * 255) ++segment;
    const int span = (positions[segment + 1] - positions[segment]) * 255;
    const int offset = level * 100 - positions[segment] * 255;
    const auto channel = [&](int c) {
      return static_cast<uint8_t>((colors[segment][c] * (span - offset) +
          colors[segment + 1][c] * offset + span / 2) / span);
    };
    red = channel(0);
    green = channel(1);
    blue = channel(2);
  }
  return static_cast<uint16_t>(((red & 0xF8) << 8) |
                               ((green & 0xFC) << 3) | (blue >> 3));
}
}  // namespace starthermal
