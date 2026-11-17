#pragma once

#include <atomic>
#include <cstdint>

#include "cb360/version.h"

namespace cb360 {
enum class Palette : uint8_t { Iron, Rainbow, WhiteHot, BlackHot, Arctic, Lava };

namespace config {
constexpr uint16_t kSensorWidth = 120;
constexpr uint16_t kSensorHeight = 92;
constexpr uint16_t kVisibleFirstRow = 2;
constexpr uint16_t kVisibleHeight = 90;
constexpr uint16_t kDisplayWidth = 320;
constexpr uint16_t kDisplayHeight = 240;
constexpr uint8_t kDefaultEmissivityPercent = 98;
constexpr int8_t kDefaultReflectedTemperatureC = 25;
constexpr int16_t kDefaultTemperatureOffsetCentiC = 0;
constexpr int16_t kDefaultManualRangeLowCentiC = 0;
constexpr int16_t kDefaultManualRangeHighCentiC = 3000;
constexpr int8_t kMinimumReflectedTemperatureC = -20;
constexpr int8_t kMaximumReflectedTemperatureC = 100;
constexpr int16_t kMaximumTemperatureOffsetCentiC = 1000;
constexpr int8_t kMinimumManualRangeC = -20;
constexpr int8_t kMaximumManualRangeC = 120;
constexpr uint8_t kDefaultBrightness = 180;
constexpr Palette kDefaultPalette = Palette::Iron;
constexpr int16_t kDefaultMinimumMappedRangeCentiC = 500;
constexpr int16_t kMinimumMappedRangeCentiC = 50;
constexpr int16_t kMaximumMappedRangeCentiC = 2000;
constexpr int16_t kMappedRangeStepCentiC = 50;
constexpr int16_t kLowContrastHysteresisCentiC = 50;
constexpr uint16_t kDefaultAutoCalibrationIntervalSeconds = 30;
constexpr uint16_t kMinimumAutoCalibrationIntervalSeconds = 10;
constexpr uint16_t kMaximumAutoCalibrationIntervalSeconds = 300;
constexpr uint16_t kAutoCalibrationIntervalStepSeconds = 10;
constexpr const char* kSettingsPath = "/cb360_config.bin";
constexpr const char* kSettingsTemporaryPath = "/cb360_config.tmp";
constexpr const char* kFirmwareVersion = CB360_FIRMWARE_VERSION;
}  // namespace config

namespace board {
constexpr uint8_t kLogTx = 0;
constexpr uint8_t kSerialRx = 1;
constexpr uint32_t kLogBaud = 115200;
constexpr uint8_t kBacklight = 4;
constexpr uint8_t kSensorPowerEnable = 5;
constexpr uint8_t kDisplayClock = 6;
constexpr uint8_t kDisplayMosi = 7;
constexpr uint8_t kDisplayDataCommand = 8;
constexpr uint8_t kDisplayChipSelect = 9;
constexpr uint8_t kDisplayRotation = 3;
constexpr uint8_t kButton1 = 10;
constexpr uint8_t kButton2 = 11;
constexpr uint8_t kTouchReset = 14;
constexpr uint8_t kTouchSda = 12;
constexpr uint8_t kTouchScl = 13;
constexpr uint8_t kLeftButton = 23;
constexpr uint8_t kMiddleButton = 24;
constexpr uint8_t kRightButton = 25;
// Battery sense: BAT -> 300k -> ADC0/GPIO26 -> 680k -> GND, 100nF at the
// ADC node (C13). The divider ratio is 680/(300+680).
constexpr uint8_t kBatteryAdc = 26;
constexpr uint16_t kBatteryAdcFullMv = 3300;
constexpr uint16_t kBatteryAdcMaxCount = 4095;
constexpr uint32_t kBatteryDividerTopOhm = 300000;
constexpr uint32_t kBatteryDividerBottomOhm = 680000;
constexpr uint16_t kDisplayWidth = config::kDisplayWidth;
constexpr uint16_t kDisplayHeight = config::kDisplayHeight;
}  // namespace board

struct RuntimeConfig {
  std::atomic<uint8_t> palette{static_cast<uint8_t>(config::kDefaultPalette)};
  std::atomic<uint8_t> emissivityPercent{config::kDefaultEmissivityPercent};
  std::atomic<uint8_t> brightness{config::kDefaultBrightness};
  std::atomic<int16_t> minimumMappedRangeCentiC{
      config::kDefaultMinimumMappedRangeCentiC};
  std::atomic<uint16_t> autoCalibrationIntervalSeconds{
      config::kDefaultAutoCalibrationIntervalSeconds};
  std::atomic<bool> hotTracking{true};
  std::atomic<bool> coldTracking{true};
  std::atomic<bool> hotTemperature{true};
  std::atomic<bool> coldTemperature{true};
  std::atomic<int8_t> reflectedTemperatureC{config::kDefaultReflectedTemperatureC};
  std::atomic<int16_t> temperatureOffsetCentiC{
      config::kDefaultTemperatureOffsetCentiC};
  std::atomic<uint8_t> temperatureUnit{0};
  std::atomic<uint8_t> readoutStability{1};
  std::atomic<uint8_t> centerRegion{0};
  std::atomic<uint8_t> rangeResponse{1};
  std::atomic<uint8_t> distanceMode{0};
  // Publish the two one-byte selections as one per-frame snapshot.
  std::atomic<uint16_t> tableSelections{0};
  std::atomic<bool> manualRangeEnabled{false};
  std::atomic<int16_t> manualRangeLowCentiC{
      config::kDefaultManualRangeLowCentiC};
  std::atomic<int16_t> manualRangeHighCentiC{
      config::kDefaultManualRangeHighCentiC};
};

extern RuntimeConfig gRuntimeConfig;
}  // namespace cb360
