#include "starthermal/thermal_raster.h"

#include <algorithm>
#include "starthermal/view.h"

namespace starthermal {
namespace {
struct Axis {
  uint8_t index[4];
  int16_t weight[3];
};

// Both axes scale by 8/3. Source position is (6*i-5)/16. The cubic
// coefficients are exact integers in Q13; constexpr tables stay in flash.
// The center-tap weight is omitted because all four weights sum to 8192.
template <size_t Output, int Input>
constexpr std::array<Axis, Output> makeAxis() {
  std::array<Axis, Output> result{};
  for (size_t i = 0; i < Output; ++i) {
    int q = static_cast<int>(6 * i) - 5;
    q = q < 0 ? 0 : (q > (Input - 1) * 16 ? (Input - 1) * 16 : q);
    const int base = q / 16;
    const int n = q % 16, n2 = n * n, n3 = n2 * n;
    for (int k = 0; k < 4; ++k) {
      const int x = base + k - 1;
      result[i].index[k] = x < 0 ? 0 : (x >= Input ? Input - 1 : x);
    }
    result[i].weight[0] = -n3 + 32 * n2 - 256 * n;
    result[i].weight[1] = -3 * n3 + 64 * n2 + 256 * n;
    result[i].weight[2] = n3 - 16 * n2;
  }
  return result;
}
constexpr auto xAxis = makeAxis<320, 120>();
constexpr auto yAxis = makeAxis<240, 90>();
}  // namespace

void ThermalRaster::beginFrame(const DisplayFrame& frame, Palette palette) {
  pixels_ = frame.pixels.data();
  stripeFrame_ = frame.deferredStripes ? &frame : nullptr;
  owners_.fill(-1);
  if (frame.pixelDomain == DisplayFrame::PixelDomain::TemperatureCentiC) {
    low_ = frame.rangeLow;
    high_ = std::max<int16_t>(frame.rangeLow + 1, frame.rangeHigh);
  } else if (frame.rangeHigh > frame.rangeLow) {
    low_ = frame.rangeLow;
    high_ = frame.rangeHigh;
  } else {
    calculateDisplayRange(pixels_, low_, high_);
  }
  spanQ2_ = std::max<int32_t>(1, static_cast<int32_t>(high_) - low_) * 4;
  scaleQ20_ = (255u << 20) / static_cast<uint32_t>(spanQ2_);
  if (!paletteReady_ || palette != currentPalette_) {
    for (size_t i = 0; i < palette_.size(); ++i)
      palette_[i] = paletteColor(palette, static_cast<uint8_t>(i));
    currentPalette_ = palette;
    paletteReady_ = true;
  }
}

void ThermalRaster::beginFrame(const int16_t* pixels, Palette palette) {
  pixels_ = pixels;
  stripeFrame_ = nullptr;
  owners_.fill(-1);
  calculateDisplayRange(pixels_, low_, high_);
  spanQ2_ = std::max<int32_t>(1, static_cast<int32_t>(high_) - low_) * 4;
  scaleQ20_ = (255u << 20) / static_cast<uint32_t>(spanQ2_);
  if (!paletteReady_ || palette != currentPalette_) {
    for (size_t i = 0; i < palette_.size(); ++i)
      palette_[i] = paletteColor(palette, static_cast<uint8_t>(i));
    currentPalette_ = palette;
    paletteReady_ = true;
  }
}

const int32_t* ThermalRaster::horizontalRow(uint8_t y) {
  const unsigned slot = y % 4;
  if (owners_[slot] == y) return rows_[slot].data();
  owners_[slot] = y;
  const int16_t* source = pixels_ + y * kSensorWidth;
  auto value = [&](unsigned x) -> int32_t {
    const int32_t v = source[x];
    return stripeFrame_ ? std::max<int32_t>(INT16_MIN, std::min<int32_t>(INT16_MAX,
        v + stripeFrame_->stripeColumns[x] + stripeFrame_->stripeRows[y])) : v;
  };
  for (size_t x = 0; x < 320; ++x) {
    const auto& a = xAxis[x];
    const int32_t center = value(a.index[1]);
    const int32_t sum = center * 8192 +
        a.weight[0] * (value(a.index[0]) - center) +
        a.weight[1] * (value(a.index[2]) - center) +
        a.weight[2] * (value(a.index[3]) - center);
    // Keep quarter-code precision, including signed cubic overshoot. Q2
    // leaves enough headroom for the vertical Q13 multiply in int32_t.
    rows_[slot][x] = (sum + 1024) >> 11;
  }
  return rows_[slot].data();
}

void ThermalRaster::renderRow(uint16_t y, uint16_t* output) {
  const auto& a = yAxis[y];
  const int32_t* r0 = horizontalRow(a.index[0]);
  const int32_t* r1 = horizontalRow(a.index[1]);
  const int32_t* r2 = horizontalRow(a.index[2]);
  const int32_t* r3 = horizontalRow(a.index[3]);
  for (size_t x = 0; x < 320; ++x) {
    const int32_t center = r1[x];
    const int32_t sum = center * 8192 +
        a.weight[0] * (r0[x] - center) +
        a.weight[1] * (r2[x] - center) +
        a.weight[2] * (r3[x] - center);
    const int32_t interpolatedQ2 = (sum + 4096) >> 13;
    const int32_t delta = interpolatedQ2 - static_cast<int32_t>(low_) * 4;
    const unsigned level = delta <= 0 ? 0 : delta >= spanQ2_ ? 255 :
        (static_cast<uint32_t>(delta) * scaleQ20_) >> 20;
    output[x] = palette_[level];
  }
}
}  // namespace starthermal
