#include "starthermal/photo_renderer.h"

namespace starthermal {
void PhotoRenderer::begin(const DisplayFrame& f, const Settings& settings, bool hud) {
  raster_.beginFrame(f, settings.palette);
  overlay_.beginFrame(f, settings.palette, OverlayMode::Photo, settings.tracking,
                      false, 0, 0, settings.osdMode, settings.temperatureUnit,
                      settings.centerOverlay);
  hud_ = hud; ready_ = true;
}
bool PhotoRenderer::row(uint16_t y, uint16_t* out, size_t count, bool includeHud) {
  if (!ready_ || !out || count < 320 || y >= 240) return false;
  raster_.renderRow(y, out);
  if (hud_ && includeHud) overlay_.renderRow(y, out);
  else if (hud_) overlay_.renderTrackingRow(y, out);
  return true;
}
PhotoResult PhotoRenderer::thumbnail(uint16_t* out, size_t count, uint16_t w, uint16_t h) {
  if (!ready_) return PhotoResult::NotReady;
  if (!out || !w || !h || w > 320 || h > 240 || count < size_t(w) * h)
    return PhotoResult::InvalidArgument;
  uint16_t pixels[320];
  for (uint16_t y = 0; y < h; ++y) {
    row(uint32_t(y) * 240 / h, pixels, 320);
    for (uint16_t x = 0; x < w; ++x) out[size_t(y) * w + x] = pixels[uint32_t(x) * 320 / w];
  }
  return PhotoResult::Ok;
}
PhotoResult PhotoRenderer::writeBmp(PhotoByteSink sink, void* context) {
  if (!ready_) return PhotoResult::NotReady;
  if (!sink) return PhotoResult::InvalidArgument;
  uint8_t header[54]{};
  auto put = [&](size_t at, uint32_t value, size_t n) {
    for (size_t i = 0; i < n; ++i) header[at + i] = value >> (i * 8);
  };
  header[0] = 'B'; header[1] = 'M';
  put(2, 54 + 320 * 240 * 3, 4); put(10, 54, 4); put(14, 40, 4);
  put(18, 320, 4); put(22, uint32_t(-240), 4); put(26, 1, 2); put(28, 24, 2);
  put(34, 320 * 240 * 3, 4);
  if (!sink(context, header, sizeof(header))) return PhotoResult::Canceled;
  uint16_t pixels[320]; uint8_t bgr[960];
  for (uint16_t y = 0; y < 240; ++y) {
    row(y, pixels, 320);
    for (size_t x = 0; x < 320; ++x) {
      const uint16_t c = pixels[x];
      bgr[x * 3] = (c & 31) * 255 / 31;
      bgr[x * 3 + 1] = ((c >> 5) & 63) * 255 / 63;
      bgr[x * 3 + 2] = (c >> 11) * 255 / 31;
    }
    if (!sink(context, bgr, sizeof(bgr))) return PhotoResult::Canceled;
  }
  return PhotoResult::Ok;
}
} // namespace starthermal
