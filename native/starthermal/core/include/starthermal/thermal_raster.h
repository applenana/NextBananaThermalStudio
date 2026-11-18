#pragma once

#include <array>
#include <cstdint>
#include "starthermal/types.h"

namespace starthermal {
// Streaming Catmull-Rom resize, 120x90 -> 320x240. No full LCD framebuffer.
class ThermalRaster {
 public:
  void beginFrame(const DisplayFrame& frame, Palette palette);
  void beginFrame(const int16_t* pixels, Palette palette);
  void renderRow(uint16_t y, uint16_t* output);
  int16_t low() const { return low_; }
  int16_t high() const { return high_; }

 private:
  const int32_t* horizontalRow(uint8_t y);
  const int16_t* pixels_ = nullptr;
  const DisplayFrame* stripeFrame_ = nullptr;
  std::array<std::array<int32_t, 320>, 4> rows_{};
  std::array<int16_t, 4> owners_{{-1, -1, -1, -1}};
  std::array<uint16_t, 256> palette_{};
  Palette currentPalette_ = Palette::Iron;
  bool paletteReady_ = false;
  int16_t low_ = 0;
  int16_t high_ = 1;
  int32_t spanQ2_ = 4;
  uint32_t scaleQ20_ = 0;
};
}  // namespace starthermal
