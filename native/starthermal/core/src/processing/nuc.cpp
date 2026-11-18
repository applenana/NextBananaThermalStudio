#include "starthermal/nuc.h"

#include <algorithm>
#include "starthermal/parameter_line.h"

namespace starthermal {
namespace {
int32_t truncDivide(int64_t numerator, int32_t denominator) {
  return static_cast<int32_t>(numerator / denominator);
}

int32_t truncDivide2(int32_t value) {
  return value / 2;
}
}  // namespace

int16_t averageReferencePixel(int64_t sum, uint16_t frameCount) {
  if (frameCount == 0) return 0;
  int64_t quotient = sum / frameCount;
  const int64_t remainder = sum % frameCount;
  const uint64_t magnitude = remainder < 0 ? -remainder : remainder;
  const uint64_t doubled = magnitude * 2;
  if (doubled > frameCount ||
      (doubled == frameCount && (quotient & 1) != 0)) {
    quotient += sum < 0 ? -1 : 1;
  }
  return wrapSigned16(static_cast<int32_t>(quotient));
}

NucResult applyNuc(const int16_t* source, const int32_t* reference,
                   const uint16_t* coefficients, int16_t* output) {
  int64_t referenceSum = 0;
  for (size_t i = 0; i < kPixelCount; ++i) referenceSum += reference[i];
  const int32_t average = truncDivide(referenceSum, kPixelCount);

  for (size_t i = 0; i < kPixelCount; ++i) {
    const int32_t gain = coefficients[i] & 0x7FFF;
    const int32_t delta = static_cast<int32_t>(source[i]) - reference[i];
    // |delta| <= 65535 and gain <= 32767, so the product fits int32_t
    // (2,147,385,345 <= INT32_MAX). Avoid a 64-bit multiply per pixel.
    const int32_t product = delta * gain;
    const int32_t correction = (product + (product < 0 ? 8191 : 0)) >> 13;
    output[i] = wrapSigned16(average + correction);
  }

  int x = 0;
  int y = 0;
  for (size_t i = 0; i < kPixelCount; ++i) {
    if ((coefficients[i] & 0x8000) != 0) {
      int16_t neighbors[8];
      size_t count = 0;
      for (int ny = std::max(0, y - 1);
           ny <= std::min(static_cast<int>(kSensorHeight) - 1, y + 1); ++ny) {
        for (int nx = std::max(0, x - 1);
             nx <= std::min(static_cast<int>(kSensorWidth) - 1, x + 1); ++nx) {
          const size_t neighbor = static_cast<size_t>(ny) * kSensorWidth + nx;
          if (neighbor != i && (coefficients[neighbor] & 0x8000) == 0) {
            neighbors[count++] = output[neighbor];
          }
        }
      }
      if (count != 0) {
        std::sort(neighbors, neighbors + count);
        const size_t middle = count / 2;
        const int32_t median = (count & 1)
                                   ? neighbors[middle]
                                   : truncDivide2(neighbors[middle - 1]) +
                                         truncDivide2(neighbors[middle]);
        output[i] = wrapSigned16(median);
      }
    }
    if (++x == kSensorWidth) {
      x = 0;
      ++y;
    }
  }
  return {average};
}
}  // namespace starthermal
