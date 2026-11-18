#pragma once
#include <cstdint>

namespace starthermal {
struct ThermalSpot {
  uint16_t index = 0; // Row-major index in the visible 120x90 image.
  int16_t centiC = 0;  // Unsmoothed temperature at this exact pixel.
};
struct ThermalExtrema {
  ThermalSpot hot{}, cold{};
  bool valid = false;
};
struct TrackingOptions {
  bool hot = true, cold = true;
  bool hotTemperature = true, coldTemperature = true;
};
// Fold into an existing scan. Strict comparisons select the first equal-valued
// pixel deterministically; no sort, second image pass, heap or temporal lag.
struct ExtremaAccumulator {
  int16_t low = INT16_MAX, high = INT16_MIN;
  uint16_t lowIndex = 0, highIndex = 0;
  void observe(int16_t value, uint16_t index) {
    if (value < low) { low = value; lowIndex = index; }
    if (value > high) { high = value; highIndex = index; }
  }
  ThermalExtrema temperatures(int16_t lowTemperature, int16_t highTemperature) const {
    ThermalExtrema result;
    result.valid = true;
    const ThermalSpot first{lowIndex, lowTemperature}, second{highIndex, highTemperature};
    result.cold = lowTemperature <= highTemperature ? first : second;
    result.hot = lowTemperature <= highTemperature ? second : first;
    return result;
  }
};
} // namespace starthermal
