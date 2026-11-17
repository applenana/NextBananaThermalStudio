#pragma once
#include <cstdint>
namespace cb360 {
struct OverlayGlyph { uint32_t codepoint; uint16_t offset; uint8_t width; };
struct OverlayFont {
  const OverlayGlyph* glyphs;
  const uint8_t* bitmap;
  uint16_t count;
  uint8_t height;
};
extern const OverlayFont overlayFont12;
extern const OverlayFont overlayCalibrationFont12;
}
