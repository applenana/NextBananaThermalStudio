#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include "cb360/types.h"

namespace cb360 {
struct NucResult {
  int32_t averageReference = 0;
};

int16_t averageReferencePixel(int64_t sum, uint16_t frameCount);
// Source and output may alias; bad-pixel replacement reads only good neighbors.
NucResult applyNuc(const int16_t* source, const int32_t* reference,
                   const uint16_t* coefficients, int16_t* output);
}  // namespace cb360
