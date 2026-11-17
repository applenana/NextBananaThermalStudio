#include "cb360/stripe_suppression.h"

#include <algorithm>
#include <array>
#include <cstddef>

namespace cb360 {
namespace {
int32_t median5(const int32_t* values) {
  std::array<int32_t, 5> sorted{values[0], values[1], values[2], values[3],
                                values[4]};
  std::sort(sorted.begin(), sorted.end());
  return sorted[2];
}
int32_t average(int64_t sum, int count) {
  return static_cast<int32_t>(sum >= 0 ? (sum + count / 2) / count
                                       : (sum - count / 2) / count);
}
int32_t baseAt(const int32_t* means, int count, int index) {
  int32_t window[5];
  for (int k = 0; k < 5; ++k) {
    int position = index - 2 + k;
    if (position < 0) position = 0;
    if (position >= count) position = count - 1;
    window[k] = means[position];
  }
  return median5(window);
}
int16_t clamp16(int32_t value) {
  if (value > INT16_MAX) return INT16_MAX;
  if (value < INT16_MIN) return INT16_MIN;
  return static_cast<int16_t>(value);
}
int16_t boundedOffset(int32_t mean, int32_t base, int16_t limit) {
  int32_t delta = mean - base;
  if (delta > limit) delta = limit;
  if (delta < -limit) delta = -limit;
  if (delta > -2 && delta < 2) delta = 0;
  return static_cast<int16_t>(-delta);
}
}  // namespace

void StripeSuppressor::prepare(const int16_t* pixels, uint16_t width, uint16_t height,
                             int16_t limit) {
  if (pixels == nullptr || width == 0 || height == 0 ||
      width > kSensorWidth || height > kSensorHeight || limit <= 0) {
    return;
  }

  // Accumulate both axes in one row-major pass over the unmodified image.
  columnMean_.fill(0);
  for (uint16_t y = 0; y < height; ++y) {
    int64_t sum = 0;
    const size_t row = static_cast<size_t>(y) * width;
    for (uint16_t x = 0; x < width; ++x) {
      const int16_t value = pixels[row + x];
      sum += value;
      columnMean_[x] += value;
    }
    rowMean_[y] = average(sum, width);
  }
  for (uint16_t x = 0; x < width; ++x)
    columnMean_[x] = average(columnMean_[x], height);
  for (uint16_t x = 0; x < width; ++x) {
    columnOffset_[x] =
        boundedOffset(columnMean_[x], baseAt(columnMean_.data(), width, x), limit);
  }
  for (uint16_t y = 0; y < height; ++y) {
    rowOffset_[y] =
        boundedOffset(rowMean_[y], baseAt(rowMean_.data(), height, y), limit);
  }
}
void StripeSuppressor::prepareFrame(DisplayFrame& frame, int16_t limit) {
  prepare(frame.pixels.data(), kSensorWidth, kVisibleHeight, limit);
  std::copy_n(columnOffset_.begin(), kSensorWidth, frame.stripeColumns.begin());
  std::copy_n(rowOffset_.begin(), kVisibleHeight, frame.stripeRows.begin());
  frame.deferredStripes = true;
}
void StripeSuppressor::apply(int16_t* pixels, uint16_t width, uint16_t height, int16_t limit) {
  if (!pixels || !width || !height || width > kSensorWidth || height > kSensorHeight || limit <= 0) return;
  prepare(pixels, width, height, limit);
  for (uint16_t y = 0; y < height; ++y) {
    for (uint16_t x = 0; x < width; ++x) {
      const size_t index = static_cast<size_t>(y) * width + x;
      pixels[index] = clamp16(static_cast<int32_t>(pixels[index]) +
                              columnOffset_[x] + rowOffset_[y]);
    }
  }
}
}  // namespace cb360
