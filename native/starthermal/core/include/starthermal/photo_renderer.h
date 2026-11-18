#pragma once
#include "starthermal/photo.h"
#include "starthermal/thermal_raster.h"
#include "starthermal/thermal_overlay.h"

namespace starthermal {
using PhotoByteSink = bool (*)(void* context, const uint8_t* bytes, size_t count);
// Borrowed restored frame must remain alive and unchanged until next begin().
class PhotoRenderer {
 public:
  // Photo overlays follow the current display and tracking settings.
  void begin(const DisplayFrame& restored, const Settings& settings, bool hud = true);
  bool row(uint16_t y, uint16_t* rgb565, size_t count, bool includeHud = true);
  PhotoResult thumbnail(uint16_t* rgb565, size_t count, uint16_t width, uint16_t height);
  // Standard 320x240, top-down, 24-bit BMP. Caller owns the output stream;
  // false sink return cancels export, leaving a partial destination to discard.
  PhotoResult writeBmp(PhotoByteSink sink, void* context);
 private:
  ThermalRaster raster_;
  ThermalOverlay overlay_;
  bool ready_ = false, hud_ = true;
};
} // namespace starthermal
