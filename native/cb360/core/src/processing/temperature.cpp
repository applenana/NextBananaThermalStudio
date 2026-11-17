#include "cb360/temperature.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include "cb360/parameter_line.h"

namespace cb360 {
namespace {
constexpr int32_t kKnotHysteresisCentiC = 50;

uint8_t nearestKnot(int16_t fpaCentiC, const TemperatureCurves& curves) {
  size_t best = 0;
  int32_t bestDistance = 65536;
  const size_t count = std::min<size_t>(curves.count, kMaximumCurveCount);
  for (size_t i = 0; i < count; ++i) {
    const int32_t delta = static_cast<int32_t>(fpaCentiC) - curves.knotsCentiC[i];
    const int32_t distance = delta < 0 ? -delta : delta;
    if (distance < bestDistance) {
      best = i;
      bestDistance = distance;
    }
  }
  return static_cast<uint8_t>(best);
}

struct CurveSelectionState {
  uint8_t index = 0;
  uint8_t loadedIndex = 0;
  uint8_t count = 0;
  bool valid = false;
};

int upperBoundIndex(const uint16_t* values, uint16_t target) {
  int first = 0;
  int last = kCurvePoints;
  while (first < last) {
    const int middle = first + (last - first) / 2;
    if (target < values[middle]) last = middle;
    else first = middle + 1;
  }
  return first;
}

float endpointSlope(const uint16_t* curve, bool highEnd) {
  if (highEnd) {
    for (size_t i = kCurvePoints - 1; i > 0; --i) {
      const float slope = static_cast<float>(curve[i]) - curve[i - 1];
      if (std::fabs(slope) > 0.0f) return slope;
    }
  } else {
    for (size_t i = 1; i < kCurvePoints; ++i) {
      const float slope = static_cast<float>(curve[i]) - curve[i - 1];
      if (std::fabs(slope) > 0.0f) return slope;
    }
  }
  return 0.0f;
}

// The captured table covers 0-60 C at 0.1 C per index. Outside that range the
// curve is continued linearly with its first/last non-zero segment slope, so
// hot and cold scenes are extrapolated instead of clamped to the table ends.
float curveTemperatureIndex(int32_t targetCode, const uint16_t* curve) {
  if (curve == nullptr) return NAN;
  if (targetCode < curve[0]) {
    const float slope = endpointSlope(curve, false);
    return slope == 0.0f ? 0.0f :
        static_cast<float>(targetCode - static_cast<int32_t>(curve[0])) / slope;
  }
  if (targetCode > curve[kCurvePoints - 1]) {
    const float slope = endpointSlope(curve, true);
    return slope == 0.0f ? static_cast<float>(kCurvePoints - 1) :
        static_cast<float>(kCurvePoints - 1) +
        static_cast<float>(targetCode -
                           static_cast<int32_t>(curve[kCurvePoints - 1])) /
            slope;
  }

  const int index = upperBoundIndex(curve, static_cast<uint16_t>(targetCode));
  return static_cast<float>(std::min(index, static_cast<int>(kCurvePoints - 1)));
}

bool saturateCentiC(float temperatureC, int16_t& temperatureCentiC) {
  if (!std::isfinite(temperatureC)) return false;
  const double centi = static_cast<double>(temperatureC) * 100.0;
  if (!std::isfinite(centi)) return false;
  if (centi >= static_cast<double>(INT16_MAX)) {
    temperatureCentiC = INT16_MAX;
  } else if (centi <= static_cast<double>(INT16_MIN)) {
    temperatureCentiC = INT16_MIN;
  } else {
    temperatureCentiC = static_cast<int16_t>(centi);
  }
  return true;
}

struct CurveChoice {
  const uint16_t* curve = nullptr;
  bool far = false;
};

CurveChoice chooseCurve(const Parameters& parameters,
                        const TemperatureCurves& curves, bool farDistance) {
  CurveChoice choice{};
  const uint8_t index = selectTemperatureCurveIndex(parameters, curves);
  if (farDistance) {
    const uint16_t* far = temperatureCurveAt(curves, index, 1);
    if (temperatureCurveUsable(far)) {
      choice.curve = far;
      choice.far = true;
      return choice;
    }
    // Empty or damaged far slot: stay on the validated near curve instead of
    // emitting meaningless temperatures.
  }
  choice.curve = temperatureCurveAt(curves, index, 0);
  choice.far = false;
  return choice;
}

float estimatePixel(int16_t centeredY16, const Parameters& parameters,
                    const CurveChoice& choice,
                    const TemperatureAdjustments& adjustments) {
  if (choice.curve == nullptr) return NAN;
  const int32_t shutterIndex = parameters.shutterCentiC / 10;
  if (shutterIndex < 0 || shutterIndex >= static_cast<int32_t>(kCurvePoints)) {
    return NAN;
  }
  const int16_t kf = choice.far ? parameters.farKf : parameters.nearKf;
  const int16_t kf2 = choice.far ? parameters.farKf2 : parameters.nearKf2;
  const int16_t base = choice.far ? parameters.farB : parameters.nearB;
  const int16_t base2 = choice.far ? parameters.farB2 : parameters.nearB2;
  const float nearGain = (kf / 10000.0f) * (kf2 / 10000.0f);
  const float nearBias = (base + base2) / 10000.0f;
  const float targetCode = nearGain * centeredY16 + choice.curve[shutterIndex];
  if (!std::isfinite(targetCode)) return NAN;
  const int32_t signedTarget = static_cast<int32_t>(targetCode);
  const float temperatureIndex = curveTemperatureIndex(signedTarget, choice.curve);
  if (!std::isfinite(temperatureIndex)) return NAN;
  const float temperature = temperatureIndex / 10.0f + nearBias;
  return emissivityCorrection(temperature, adjustments.emissivity,
                              adjustments.reflectedC) +
      adjustments.offsetCentiC / 100.0f;
}

bool estimateWithCurve(int16_t centeredY16, const uint16_t* curve,
                       const Parameters& parameters,
                       const TemperatureAdjustments& adjustments,
                       int16_t& temperatureCentiC) {
  const CurveChoice choice{curve, adjustments.farDistance};
  const float estimate = estimatePixel(centeredY16, parameters, choice, adjustments);
  return saturateCentiC(estimate, temperatureCentiC);
}
}  // namespace

bool temperatureCurveUsable(const uint16_t* curve) {
  if (curve == nullptr) return false;
  if (curve[0] >= curve[kCurvePoints - 1]) return false;
  for (size_t i = 1; i < kCurvePoints; ++i)
    if (curve[i] < curve[i - 1]) return false;
  return true;
}

uint8_t selectTemperatureCurveIndex(const Parameters& parameters,
                                    const TemperatureCurves& curves) {
  static CurveSelectionState state{};
  if (manualTableAvailable(curves.selection, curves.count)) {
    // Returning to Auto starts from the current FPA, not pre-manual hysteresis.
    state.valid = false;
    return curves.selection - 1;
  }
  const uint8_t nearest = nearestKnot(parameters.fpaCentiC, curves);
  if (!state.valid || state.loadedIndex != curves.loadedIndex ||
      state.count != curves.count ||
      state.index >= std::min<size_t>(curves.count, kMaximumCurveCount) ||
      !temperatureCurveUsable(temperatureCurveAt(curves, state.index, 0))) {
    state.index = nearest;
    state.loadedIndex = curves.loadedIndex;
    state.count = curves.count;
    state.valid = true;
    return nearest;
  }
  // Interval selection with 0.5 C hysteresis: keep the current knot unless a
  // neighbour is clearly closer, which removes boundary chatter while keeping
  // the same curve family as the K-map selection.
  const int32_t currentDelta = std::abs(static_cast<int32_t>(parameters.fpaCentiC) -
                                        curves.knotsCentiC[state.index]);
  const int32_t nearestDelta = std::abs(static_cast<int32_t>(parameters.fpaCentiC) -
                                        curves.knotsCentiC[nearest]);
  if (nearestDelta + kKnotHysteresisCentiC < currentDelta) state.index = nearest;
  return state.index;
}

const uint16_t* temperatureCurveAt(const TemperatureCurves& curves,
                                   uint8_t index, uint8_t distance) {
  if (index >= curves.count || index >= kMaximumCurveCount ||
      distance >= kDistanceCurveCount) return nullptr;
#if defined(ARDUINO)
  if (index != curves.loadedIndex) return nullptr;
  return curves.values[0][distance].data();
#else
  return curves.values[index][distance].data();
#endif
}

float emissivityCorrection(float temperatureC, float emissivity,
                           float reflectedTemperatureC) {
  float result = temperatureC;
  if (emissivity <= 0.98f) {
    const double a = emissivity * 0.0001988507 - 0.0001762534;
    const double b = emissivity * -0.750542 + 1.744737;
    const double c = emissivity * -4.247635 + 4.750041;
    result = static_cast<float>(a * result * result + b * result + c);
    if (emissivity >= 0.9f) {
      result -= ((1.0f - emissivity) / emissivity) * reflectedTemperatureC;
    }
  }
  return result;
}

bool estimateCenterTemperature(const int16_t* corrected,
                               const Parameters& parameters,
                               const TemperatureCurves& curves,
                               int32_t averageReference,
                               float emissivity,
                               int16_t& temperatureCentiC) {
  const TemperatureAdjustments adjustments{emissivity, 25.0f, 0, false};
  if (corrected == nullptr || !std::isfinite(emissivity) ||
      emissivity <= 0.0f || emissivity > 1.0f) return false;
  const CurveChoice choice = chooseCurve(parameters, curves, false);
  constexpr size_t centerSourceY = kVisibleFirstRow + kVisibleHeight / 2;
  const size_t index = centerSourceY * kSensorWidth + kSensorWidth / 2;
  const int16_t centered = wrapSigned16(
      static_cast<int32_t>(corrected[index]) - averageReference);
  return saturateCentiC(estimatePixel(centered, parameters, choice, adjustments),
                        temperatureCentiC);
}

bool estimatePixelTemperature(int16_t centeredY16,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              float emissivity,
                              int16_t& temperatureCentiC) {
  return estimatePixelTemperature(
      centeredY16, parameters, curves,
      TemperatureAdjustments{emissivity, 25.0f, 0, false}, temperatureCentiC);
}

bool estimatePixelTemperature(int16_t centeredY16,
                              const Parameters& parameters,
                              const TemperatureCurves& curves,
                              const TemperatureAdjustments& adjustments,
                              int16_t& temperatureCentiC) {
  if (!std::isfinite(adjustments.emissivity) || adjustments.emissivity <= 0.0f ||
      adjustments.emissivity > 1.0f) return false;
  const CurveChoice choice =
      chooseCurve(parameters, curves, adjustments.farDistance);
  return saturateCentiC(estimatePixel(centeredY16, parameters, choice, adjustments),
                        temperatureCentiC);
}

bool estimatePixelTemperature(int16_t centeredY16, const uint16_t* curve,
                              const Parameters& parameters, float emissivity,
                              int16_t& temperatureCentiC) {
  return estimateWithCurve(centeredY16, curve, parameters,
                           TemperatureAdjustments{emissivity, 25.0f, 0, false},
                           temperatureCentiC);
}

bool estimatePixelTemperature(int16_t centeredY16, const uint16_t* curve,
                              const Parameters& parameters,
                              const TemperatureAdjustments& adjustments,
                              int16_t& temperatureCentiC) {
  if (curve == nullptr || !std::isfinite(adjustments.emissivity) ||
      adjustments.emissivity <= 0.0f || adjustments.emissivity > 1.0f)
    return false;
  return estimateWithCurve(centeredY16, curve, parameters, adjustments,
                           temperatureCentiC);
}

const uint16_t* selectTemperatureCurve(const Parameters& parameters,
                                      const TemperatureCurves& curves) {
  return selectTemperatureCurve(parameters, curves, false);
}

const uint16_t* selectTemperatureCurve(const Parameters& parameters,
                                      const TemperatureCurves& curves,
                                      bool farDistance) {
  return chooseCurve(parameters, curves, farDistance).curve;
}

bool TemperatureMapper::prepare(const Parameters& parameters,
                                const TemperatureCurves& curves,
                                float emissivity) {
  return prepare(parameters, curves,
                 TemperatureAdjustments{emissivity, 25.0f, 0, false});
}

bool TemperatureMapper::prepare(const Parameters& parameters,
                                const TemperatureCurves& curves,
                                const TemperatureAdjustments& adjustments) {
  if (!std::isfinite(adjustments.emissivity) ||
      adjustments.emissivity <= 0.0f || adjustments.emissivity > 1.0f)
    return false;
  const int32_t shutterIndex = parameters.shutterCentiC / 10;
  if (shutterIndex < 0 || shutterIndex >= static_cast<int32_t>(kCurvePoints))
    return false;

  const CurveChoice choice =
      chooseCurve(parameters, curves, adjustments.farDistance);
  const uint16_t* curve = choice.curve;
  if (!curve) return false;
  const bool far = choice.far;
  if (curve != curve_ || curves.loadedIndex != loadedCurveIndex_ ||
      far != adjustments_.farDistance) {
    curve_ = curve;
    loadedCurveIndex_ = curves.loadedIndex;
    // 256 high-byte buckets turn the per-pixel curve search into a couple of
    // comparisons instead of a ten-step binary search over 600 points.
    size_t index = 0;
    for (size_t bucket = 0; bucket <= 256; ++bucket) {
      const uint32_t boundary = static_cast<uint32_t>(bucket) * 256;
      while (index < kCurvePoints && curve[index] < boundary) ++index;
      curveBucketStarts_[bucket] = static_cast<uint16_t>(index);
    }
    curveReady_ = true;
  }

  const int16_t kf = far ? parameters.farKf : parameters.nearKf;
  const int16_t kf2 = far ? parameters.farKf2 : parameters.nearKf2;
  const int16_t base = far ? parameters.farB : parameters.nearB;
  const int16_t base2 = far ? parameters.farB2 : parameters.nearB2;
  const float nearBias = (base + base2) / 10000.0f;
  const float offsetC = adjustments.offsetCentiC / 100.0f;
  if (!temperaturesReady_ || nearBias != nearBias_ ||
      adjustments.emissivity != emissivity_ ||
      adjustments.reflectedC != adjustments_.reflectedC ||
      adjustments.offsetCentiC != adjustments_.offsetCentiC ||
      far != adjustments_.farDistance) {
    for (size_t i = 0; i < correctedTemperatures_.size(); ++i) {
      const float temperature = static_cast<float>(i) / 10.0f + nearBias;
      const float corrected =
          emissivityCorrection(temperature, adjustments.emissivity,
                               adjustments.reflectedC) + offsetC;
      correctedTemperatures_[i] = INT16_MIN;
      saturateCentiC(corrected, correctedTemperatures_[i]);
    }
    nearBias_ = nearBias;
    emissivity_ = adjustments.emissivity;
    adjustments_.reflectedC = adjustments.reflectedC;
    adjustments_.offsetCentiC = adjustments.offsetCentiC;
    adjustments_.farDistance = far;
    temperaturesReady_ = true;
  }
  adjustments_.emissivity = adjustments.emissivity;
  nearGain_ = (kf / 10000.0f) * (kf2 / 10000.0f);
  shutterCode_ = static_cast<float>(curve[shutterIndex]);
  return curveReady_;
}

bool TemperatureMapper::convert(int16_t centeredY16,
                                int16_t& temperatureCentiC) const {
  if (!curveReady_ || !temperaturesReady_ || curve_ == nullptr) return false;
  const float targetCode = nearGain_ * centeredY16 + shutterCode_;
  // nearGain_ comes from two int16 parameters and centeredY16 is int16, so
  // targetCode is always finite; skip the per-pixel isfinite helper calls.
  const int32_t target = static_cast<int32_t>(targetCode);

  // In-range pixels take the precomputed table; no floorf, double or full
  // curve search on the hot path. Out-of-range pixels keep the linear
  // extrapolation below.
  if (target >= static_cast<int32_t>(curve_[0]) &&
      target <= static_cast<int32_t>(curve_[kCurvePoints - 1])) {
    const uint16_t code = static_cast<uint16_t>(target);
    int low = curveBucketStarts_[code >> 8];
    int high = curveBucketStarts_[(code >> 8) + 1];
    while (low < high) {
      const int middle = low + (high - low) / 2;
      if (code < curve_[middle]) high = middle;
      else low = middle + 1;
    }
    int index = low;
    if (index >= static_cast<int>(kCurvePoints))
      index = static_cast<int>(kCurvePoints) - 1;
    const int16_t corrected = correctedTemperatures_[static_cast<size_t>(index)];
    if (corrected != INT16_MIN) {
      temperatureCentiC = corrected;
      return true;
    }
  }

  const float temperatureIndex = curveTemperatureIndex(target, curve_);
  if (!std::isfinite(temperatureIndex)) return false;
  const float temperature = temperatureIndex / 10.0f + nearBias_;
  const float corrected =
      emissivityCorrection(temperature, adjustments_.emissivity,
                           adjustments_.reflectedC) +
      adjustments_.offsetCentiC / 100.0f;
  return saturateCentiC(corrected, temperatureCentiC);
}

bool TemperatureMapper::invert(int16_t temperatureCentiC,
                               int16_t& centeredY16) const {
  if (!curveReady_ || !temperaturesReady_) return false;
  int16_t lowTemperature = 0, highTemperature = 0;
  if (!convert(INT16_MIN, lowTemperature) ||
      !convert(INT16_MAX, highTemperature) ||
      lowTemperature == highTemperature) return false;
  const bool ascending = lowTemperature < highTemperature;
  if ((ascending && (temperatureCentiC < lowTemperature ||
                     temperatureCentiC > highTemperature)) ||
      (!ascending && (temperatureCentiC > lowTemperature ||
                      temperatureCentiC < highTemperature))) return false;
  int32_t low = INT16_MIN;
  int32_t high = INT16_MAX;
  while (low < high) {
    const int32_t middle = low + (high - low) / 2;
    int16_t mapped = 0;
    if (!convert(static_cast<int16_t>(middle), mapped)) return false;
    const bool beforeTarget = ascending ? mapped < temperatureCentiC
                                        : mapped > temperatureCentiC;
    if (beforeTarget) low = middle + 1;
    else high = middle;
  }
  centeredY16 = static_cast<int16_t>(low);
  return true;
}
}  // namespace cb360
