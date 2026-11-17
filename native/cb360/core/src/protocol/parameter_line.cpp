#include "cb360/parameter_line.h"

#include <cmath>

namespace cb360 {
namespace {
int16_t readS16(const uint8_t* bytes) {
  const uint16_t value = static_cast<uint16_t>(bytes[0]) |
                         (static_cast<uint16_t>(bytes[1]) << 8);
  return static_cast<int16_t>(value);
}
}  // namespace

int16_t fpaRawToCentiC(int16_t raw) {
  const double value = (static_cast<double>(0x142837A0) -
                        static_cast<double>(raw) * 18181.8) /
                       1000000.0 * 100.0;
  return wrapSigned16(static_cast<int32_t>(value));
}

int16_t temperatureRawToCentiC(int16_t raw) {
  const double sample = raw;
  double value = 4.0235e-11 * sample;
  value *= sample;
  value *= sample;
  value = -value;
  double quadratic = 1.2184e-6 * sample;
  quadratic *= sample;
  const double linear = -(sample * 0.0182181);
  value += quadratic;
  value += linear;
  value += 127.361;
  return wrapSigned16(static_cast<int32_t>(value * 100.0));
}

bool parseParameterLine(const uint8_t* bytes, size_t length,
                        Parameters& output) {
  if (bytes == nullptr || length != kParameterBytes ||
      readS16(bytes) != static_cast<int16_t>(0xAA55) ||
      readS16(bytes + 4) != static_cast<int16_t>(kSensorWidth) ||
      readS16(bytes + 6) != static_cast<int16_t>(kSensorHeight)) {
    return false;
  }

  auto word = [bytes](size_t index) { return readS16(bytes + index * 2); };
  Parameters parsed{};
  parsed.shutterRaw = word(9);
  parsed.lensRaw = word(10);
  parsed.fpaRaw = word(11);
  parsed.shutterFlag = word(12);
  parsed.fpaCentiC = fpaRawToCentiC(parsed.fpaRaw);
  parsed.shutterCentiC = temperatureRawToCentiC(parsed.shutterRaw);
  parsed.nearB = word(0x4F);
  parsed.nearKf = word(0x50);
  parsed.farB = word(0x52);
  parsed.farKf = word(0x53);
  parsed.nearB2 = word(0x55);
  parsed.nearKf2 = word(0x56);
  parsed.farB2 = word(0x57);
  parsed.farKf2 = word(0x58);
  if (parsed.nearKf2 < 9000 || parsed.nearKf2 > 11000) {
    parsed.nearB2 = 0;
    parsed.nearKf2 = 10000;
  }
  if (parsed.farKf2 < 9000 || parsed.farKf2 > 11000) {
    parsed.farB2 = 0;
    parsed.farKf2 = 10000;
  }
  output = parsed;
  return true;
}
}  // namespace cb360
