#pragma once

#include <cstddef>
#include <cstdint>
#include "cb360/types.h"

namespace cb360 {
bool parseParameterLine(const uint8_t* bytes, size_t length,
                        Parameters& output);
int16_t fpaRawToCentiC(int16_t raw);
int16_t temperatureRawToCentiC(int16_t raw);
inline int16_t wrapSigned16(int32_t value) {
  const uint16_t wrapped = static_cast<uint16_t>(value);
  return wrapped < 0x8000
             ? static_cast<int16_t>(wrapped)
             : static_cast<int16_t>(static_cast<int32_t>(wrapped) - 65536);
}
}  // namespace cb360
