/// `thermal view` 设备响应的数据模型与校验。
library;

enum ThermalSensorKind { unknown, heimannHtpa32x32, mlx90640, mlx90641 }

enum ThermalScreenMode { fullscreen, square }

class ThermalViewConfig {
  static const String responseType = 'thermal_view';
  static const int latestSupportedVersion = 2;

  final int version;
  final int xOffset;
  final int yOffset;
  final double scale;
  final ThermalSensorKind sensor;
  final ThermalScreenMode screenMode;
  final int visibleWidth;
  final int visibleHeight;
  final int thermalWidth;
  final int thermalHeight;
  final int displayWidth;
  final int displayHeight;
  final bool sensorRotate180;

  const ThermalViewConfig({
    required this.version,
    required this.xOffset,
    required this.yOffset,
    required this.scale,
    this.sensor = ThermalSensorKind.unknown,
    this.screenMode = ThermalScreenMode.fullscreen,
    this.visibleWidth = 120,
    this.visibleHeight = 160,
    this.thermalWidth = 32,
    this.thermalHeight = 24,
    this.displayWidth = 320,
    this.displayHeight = 240,
    this.sensorRotate180 = true,
  });

  int get thermalCount => thermalWidth * thermalHeight;

  bool get isMlx =>
      sensor == ThermalSensorKind.mlx90640 ||
      sensor == ThermalSensorKind.mlx90641;

  /// 解析固件返回的 JSON 对象。
  ///
  /// 非本 API 响应或越界数据返回 null，调用方应保留未同步状态，不能把异常
  /// 参数带入逐像素渲染。
  static ThermalViewConfig? tryParse(Map<String, dynamic> json) {
    if (json['type'] != responseType) return null;

    final version = (json['version'] as num?)?.toInt();
    final xOffset = (json['x_offset'] as num?)?.toInt();
    final yOffset = (json['y_offset'] as num?)?.toInt();
    final scale = (json['scale'] as num?)?.toDouble();

    if (version != 1 && version != latestSupportedVersion ||
        xOffset == null ||
        yOffset == null ||
        scale == null ||
        !scale.isFinite ||
        scale < 1.0 ||
        scale > 2.0 ||
        xOffset < -100 ||
        xOffset > 100 ||
        yOffset < -100 ||
        yOffset > 100) {
      return null;
    }

    if (version == 1) {
      return ThermalViewConfig(
        version: version!,
        xOffset: xOffset,
        yOffset: yOffset,
        scale: scale,
      );
    }

    final sensor = _parseSensor(json['sensor']);
    final screenMode = _parseScreenMode(json['screen_mode']);
    final visibleWidth = (json['visible_width'] as num?)?.toInt();
    final visibleHeight = (json['visible_height'] as num?)?.toInt();
    final thermalWidth = (json['thermal_width'] as num?)?.toInt();
    final thermalHeight = (json['thermal_height'] as num?)?.toInt();
    final thermalCount = (json['thermal_count'] as num?)?.toInt();
    final displayWidth = (json['display_width'] as num?)?.toInt();
    final displayHeight = (json['display_height'] as num?)?.toInt();
    final sensorRotate180 = json['sensor_rotate180'];

    if (sensor == null ||
        screenMode == null ||
        visibleWidth == null ||
        visibleHeight == null ||
        thermalWidth == null ||
        thermalHeight == null ||
        thermalCount == null ||
        displayWidth == null ||
        displayHeight == null ||
        sensorRotate180 is! bool ||
        thermalWidth != 32 ||
        (thermalHeight != 24 && thermalHeight != 32) ||
        thermalCount != thermalWidth * thermalHeight ||
        (visibleWidth != 120 ||
            (visibleHeight != 120 && visibleHeight != 160)) ||
        (displayWidth != 240 && displayWidth != 320) ||
        displayHeight != 240 ||
        (screenMode == ThermalScreenMode.fullscreen &&
            (thermalHeight != 24 ||
                visibleHeight != 160 ||
                displayWidth != 320)) ||
        (screenMode == ThermalScreenMode.square &&
            (visibleHeight != 120 || displayWidth != 240)) ||
        ((sensor == ThermalSensorKind.mlx90640 ||
                sensor == ThermalSensorKind.mlx90641) &&
            thermalHeight != 24) ||
        (thermalHeight == 32 &&
            (sensor != ThermalSensorKind.heimannHtpa32x32 ||
                screenMode != ThermalScreenMode.square)) ||
        (sensor == ThermalSensorKind.heimannHtpa32x32 &&
            thermalHeight !=
                (screenMode == ThermalScreenMode.square ? 32 : 24))) {
      return null;
    }

    return ThermalViewConfig(
      version: version!,
      xOffset: xOffset,
      yOffset: yOffset,
      scale: scale,
      sensor: sensor,
      screenMode: screenMode,
      visibleWidth: visibleWidth,
      visibleHeight: visibleHeight,
      thermalWidth: thermalWidth,
      thermalHeight: thermalHeight,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
      sensorRotate180: sensorRotate180,
    );
  }

  static ThermalSensorKind? _parseSensor(Object? value) => switch (value) {
    'unknown' => ThermalSensorKind.unknown,
    'heimann_htpa32x32' => ThermalSensorKind.heimannHtpa32x32,
    'mlx90640' => ThermalSensorKind.mlx90640,
    'mlx90641' => ThermalSensorKind.mlx90641,
    _ => null,
  };

  static ThermalScreenMode? _parseScreenMode(Object? value) => switch (value) {
    'fullscreen' => ThermalScreenMode.fullscreen,
    'square' => ThermalScreenMode.square,
    _ => null,
  };
}
