#pragma once

#include <array>
#include <cstdint>
#include "starthermal/settings.h"
#include "starthermal/types.h"
#include "starthermal/temperature.h"

namespace starthermal {
uint16_t visibleSourceIndex(uint16_t x, uint16_t y);
void copyVisibleRegion(const int16_t* source, int16_t* destination);
void calculateDisplayRange(const int16_t* pixels, int16_t& low, int16_t& high);
bool calculateTemperatureRange(const int16_t* corrected,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference, float emissivity,
                              int16_t* temperaturePixels,
                              int16_t& lowCentiC, int16_t& highCentiC);
bool calculateTemperatureRange(const int16_t* corrected,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference,
                              const TemperatureAdjustments& adjustments,
                              int16_t* temperaturePixels,
                              int16_t& lowCentiC, int16_t& highCentiC);
bool calculateTemperatureBounds(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference, float emissivity,
                               int16_t& lowCentiC, int16_t& highCentiC);
bool calculateTemperatureBounds(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference,
                               const TemperatureAdjustments& adjustments,
                               int16_t& lowCentiC, int16_t& highCentiC);
bool calculateY16DisplayRange(const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference, float emissivity,
                              int16_t lowCentiC, int16_t highCentiC,
                              int16_t& lowY16, int16_t& highY16);
bool calculateY16DisplayRange(const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference,
                              const TemperatureAdjustments& adjustments,
                              int16_t lowCentiC, int16_t highCentiC,
                              int16_t& lowY16, int16_t& highY16);
// scratchPixels is overwritten while selecting the median of the visible Y16 data.
bool calculateTemperatureSummary(const int16_t* corrected,
                                 const Parameters& parameters,
                                 const TemperatureCurves& curves,
                                 int32_t averageReference, float emissivity,
                                 int16_t* scratchPixels,
                                 TemperatureSummary& summary,
                                 bool trackExtrema = true);
bool calculateTemperatureSummary(const int16_t* corrected,
                                 const Parameters& parameters,
                                 const TemperatureCurves& curves,
                                 int32_t averageReference,
                                 const TemperatureAdjustments& adjustments,
                                 CenterRegion centerRegion,
                                 int16_t* scratchPixels,
                                 TemperatureSummary& summary,
                                 bool trackExtrema = true,
                                 bool measureCenter = true);
// Converts only the selected samples (or bounded 3x3/5x5 local medians).
// convertedCount is useful for performance checks; it is never > selection.count.
bool calculateMeasurementPoints(const int16_t* corrected,
    const Parameters& parameters, const TemperatureCurves& curves,
    int32_t averageReference, const TemperatureAdjustments& adjustments,
    CenterRegion region, const PointMeasurements& selection,
    PointMeasurements& output, size_t* convertedCount = nullptr);
bool convertTemperaturePixels(const int16_t* corrected,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference, float emissivity,
                              int16_t* temperaturePixels,
                              TemperatureSummary* summary = nullptr);
bool convertTemperaturePixels(const int16_t* corrected,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              int32_t averageReference,
                              const TemperatureAdjustments& adjustments,
                              CenterRegion centerRegion,
                              int16_t* temperaturePixels,
                              TemperatureSummary* summary = nullptr);
bool updateLowContrastRange(bool& lowContrastMode, bool& initialized,
                            int16_t temperatureLow, int16_t temperatureHigh,
                            int16_t minimumMappedRangeCentiC,
                            int16_t& smoothedLow, int16_t& smoothedHigh);
bool updateLowContrastRange(bool& lowContrastMode, bool& initialized,
                            int16_t temperatureLow, int16_t temperatureHigh,
                            int16_t minimumMappedRangeCentiC,
                            RangeResponse response,
                            int16_t& smoothedLow, int16_t& smoothedHigh);
uint16_t paletteColor(Palette palette, uint8_t level);
}  // namespace starthermal
