/// `thermal view` 设备响应的数据模型与校验。
library;

class ThermalViewConfig {
  static const String responseType = 'thermal_view';
  static const int supportedVersion = 1;

  final int version;
  final int xOffset;
  final int yOffset;
  final double scale;

  const ThermalViewConfig({
    required this.version,
    required this.xOffset,
    required this.yOffset,
    required this.scale,
  });

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

    if (version != supportedVersion ||
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

    return ThermalViewConfig(
      version: version!,
      xOffset: xOffset,
      yOffset: yOffset,
      scale: scale,
    );
  }
}
