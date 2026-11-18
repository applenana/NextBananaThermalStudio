#pragma once
#include <array>
#include <cstdint>

#include "starthermal/types.h"

namespace starthermal {
// Removes narrow horizontal/vertical fixed-pattern stripes from a display
// buffer. Each column/row mean is high-passed against a 5-tap median and the
// bounded offset is subtracted in place. No heap, no per-pixel division.
class StripeSuppressor {
 public:
  void apply(int16_t* pixels, uint16_t width, uint16_t height, int16_t limit);
  void prepare(const int16_t* pixels, uint16_t width, uint16_t height, int16_t limit);
  void prepareFrame(DisplayFrame& frame, int16_t limit);

 private:
  std::array<int32_t, kSensorWidth> columnMean_{};
  std::array<int16_t, kSensorWidth> columnOffset_{};
  std::array<int32_t, kSensorHeight> rowMean_{};
  std::array<int16_t, kSensorHeight> rowOffset_{};
};
}
