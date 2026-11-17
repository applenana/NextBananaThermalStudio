#include "cb360/photo_renderer.h"
#include <cstring>
#include <memory>
using namespace cb360;
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
struct Output { uint8_t* bytes; size_t at = 0; };
static bool sink(void* opaque, const uint8_t* data, size_t n) {
 auto& out = *static_cast<Output*>(opaque);
 if (out.at + n > 230454) return false;
 memcpy(out.bytes + out.at, data, n); out.at += n; return true;
}
static PhotoRenderConfig configFromValues(const int32_t* v) {
 PhotoRenderConfig cfg;
 cfg.averageReference = v[0];
 cfg.settings.emissivityPercent = v[1];
 cfg.settings.reflectedTemperatureC = v[2];
 cfg.settings.temperatureOffsetCentiC = v[3];
 cfg.settings.distanceMode = static_cast<DistanceMode>(v[4]);
 cfg.settings.palette = static_cast<Palette>(v[5]);
 cfg.settings.osdMode = static_cast<OsdMode>(v[6]);
 cfg.settings.temperatureUnit = static_cast<TemperatureUnit>(v[7]);
 cfg.settings.centerRegion = static_cast<CenterRegion>(v[8]);
 cfg.settings.centerOverlay.reticle = v[9];
 cfg.settings.centerOverlay.temperature = v[10];
 cfg.settings.manualRangeEnabled = v[11];
 cfg.settings.manualRangeLowCentiC = v[12];
 cfg.settings.manualRangeHighCentiC = v[13];
 cfg.settings.minimumMappedRangeCentiC = v[14];
 cfg.settings.rangeResponse = static_cast<RangeResponse>(v[15]);
 cfg.settings.tracking.hot = v[16];
 cfg.settings.tracking.cold = v[17];
 cfg.settings.tracking.hotTemperature = v[18];
 cfg.settings.tracking.coldTemperature = v[19];
 cfg.parameters.fpaCentiC = v[20];
 cfg.parameters.shutterCentiC = v[21];
 cfg.parameters.nearB = v[22];
 cfg.parameters.nearKf = v[23];
 cfg.parameters.nearB2 = v[24];
 cfg.parameters.nearKf2 = v[25];
 cfg.parameters.farB = v[26];
 cfg.parameters.farKf = v[27];
 cfg.parameters.farB2 = v[28];
 cfg.parameters.farKf2 = v[29];
 cfg.measurements.mode = static_cast<MeasurementMode>(v[30]);
 cfg.measurements.count = v[31];
 cfg.measurements.points[0].x = v[32]; cfg.measurements.points[0].y = v[33];
 cfg.measurements.points[1].x = v[34]; cfg.measurements.points[1].y = v[35];
 cfg.measurements.points[2].x = v[36]; cfg.measurements.points[2].y = v[37];
 cfg.measurements.points[3].x = v[38]; cfg.measurements.points[3].y = v[39];
 cfg.measurements.points[4].x = v[40]; cfg.measurements.points[4].y = v[41];
 return cfg;
}
// 10800 signed pixels, 600 curve points, ABI v1 integers, BMP and centi-C outputs.
API int cb360_restore(const int16_t* pixels, const uint16_t* curve,
 const int32_t* v, int count, uint8_t* bmp, int16_t* temperatures) {
 if (!pixels || !curve || !v || count != 42 || !bmp || !temperatures) return -1;
 try {
 auto cfg = configFromValues(v);
 if (v[31] < 0 || v[31] > 5) return -2;
 auto frame = std::make_unique<DisplayFrame>();
 auto curves = std::make_unique<TemperatureCurves>();
 curves->count = 1; curves->loadedIndex = 0;
 auto& selected = curves->values[0][cfg.settings.distanceMode == DistanceMode::Far ? 1 : 0];
 memcpy(selected.data(), curve, 1200);
 memcpy(frame->pixels.data(), pixels, 21600);
 PhotoInfo info;
 for (size_t i = 0; i < 10800; ++i)
  if (!photoTemperature(info, cfg, *curves, pixels[i], temperatures[i])) return -3;
 auto result = restorePhotoFrame(info, cfg, *curves, *frame);
 if (result != PhotoResult::Ok) return static_cast<int>(result) + 1;
 auto renderer = std::make_unique<PhotoRenderer>();
 renderer->begin(*frame, cfg.settings, true);
 Output output{bmp};
 return renderer->writeBmp(sink, &output) == PhotoResult::Ok && output.at == 230454 ? 0 : -4;
 } catch (...) { return -5; }
}

// One lookup table per parameter snapshot; every streaming pixel uses exactly
// photoTemperature's signed wrapping, interpolation and emissivity arithmetic.
API int cb360_temperature_lut(const uint16_t* curve, const int32_t* v,
 int count, int16_t* output) {
 if (!curve || !v || count != 42 || !output) return -1;
 try {
  auto cfg = configFromValues(v);
  auto curves = std::make_unique<TemperatureCurves>();
  curves->count = 1; curves->loadedIndex = 0;
  auto& selected = curves->values[0][cfg.settings.distanceMode == DistanceMode::Far ? 1 : 0];
  memcpy(selected.data(), curve, 1200);
  PhotoInfo info;
  for (int code = -32768; code <= 32767; ++code)
   if (!photoTemperature(info, cfg, *curves, static_cast<int16_t>(code), output[code + 32768])) return -3;
  return 0;
 } catch (...) { return -5; }
}
