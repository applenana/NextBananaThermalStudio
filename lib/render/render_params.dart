/// 统一渲染参数. 实时画面和图片下载共享同一份, 由 AppState 持有.
///
/// 渲染流水线顺序:
///   Float32 (24x32)
///     -> Kalman 2D (可选, 在 AppState 上层做)
///     -> Bilateral 2D 滤波 (可选)
///     -> min-max 归一化
///     -> 上采样 (nearest/bilinear/bicubic, 在归一化空间插值数值更平滑)
///     -> 映射曲线 (linear / S-curve)
///     -> Colormap 查表 -> RGB
///     -> Fusion (off/blend/edge) 与可见光叠加
library;

import 'package:flutter/foundation.dart';

import '../fusion/fusion.dart';

enum UpsampleMethod { nearest, bilinear, bicubic }

/// 设备端热像视图变换参数。
///
/// [enabled] 仅在成功收到设备 `thermal view` 响应后置为 true，避免旧固件
/// 不支持查询时改变上位机原有的插值行为。偏移单位与设备一致：屏幕像素，
/// 每 10 屏幕像素对应 1 个热传感器源像素。
@immutable
class ThermalViewParams {
  final bool enabled;
  final double scale;
  final int xOffset;
  final int yOffset;

  const ThermalViewParams({
    this.enabled = false,
    this.scale = 1.0,
    this.xOffset = 0,
    this.yOffset = 0,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'scale': scale,
    'xOffset': xOffset,
    'yOffset': yOffset,
  };

  factory ThermalViewParams.fromJson(Map<String, dynamic> j) {
    return ThermalViewParams(
      enabled: j['enabled'] as bool? ?? false,
      scale: (j['scale'] as num?)?.toDouble() ?? 1.0,
      xOffset: (j['xOffset'] as num?)?.toInt() ?? 0,
      yOffset: (j['yOffset'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class RenderParams {
  // ---- 上采样 ----
  /// 输出相对热像原始尺寸 (24x32) 的倍率. 1/2/4/8/16.
  final int upsampleScale;
  final UpsampleMethod upsampleMethod;

  // ---- 双边滤波 (像素级抑噪, 保边) ----
  final bool bilateralEnabled;

  /// 空间高斯 sigma (像素单位). 越大邻域越宽, 越平滑.
  final double bilateralSigmaSpatial;

  /// 亮度高斯 sigma (输入数值单位, 归一化前的原始值差).
  /// 越大对差异容忍越高 (更平滑); 越小越保边.
  final double bilateralSigmaIntensity;

  // ---- 颜色映射 ----
  final String colormapName;

  /// 'linear' / 'nonlinear' (S 曲线)
  final String mappingCurve;
  final bool useCustomColors;
  final int coldColor;
  final int midColor;
  final int hotColor;

  // ---- 设备热像视图变换 ----
  final ThermalViewParams thermalView;

  // ---- 融合 ----
  final FusionParams fusion;

  // ---- 显示选项 ----
  /// 在图片上叠加 Tmax/Tmin/Tavg 信息条 (用于 Photo Tab 导出和实时可选)
  final bool showInfoOverlay;

  /// 显示十字光标 + 鼠标悬浮取温
  final bool showCursorTemp;

  /// 主画面叠加最高温跟踪 (橙黄▼角标 + H 标签).
  final bool showHotSpot;

  /// 主画面叠加最低温跟踪 (冰青▲角标 + L 标签).
  final bool showColdSpot;

  const RenderParams({
    this.upsampleScale = 8,
    this.upsampleMethod = UpsampleMethod.bicubic,
    this.bilateralEnabled = true,
    this.bilateralSigmaSpatial = 1.5,
    this.bilateralSigmaIntensity = 1.5,
    this.colormapName = 'jet',
    this.mappingCurve = 'linear',
    this.useCustomColors = false,
    this.coldColor = 0x0000FF,
    this.midColor = 0x00FF00,
    this.hotColor = 0xFF0000,
    this.thermalView = const ThermalViewParams(),
    this.fusion = const FusionParams(),
    this.showInfoOverlay = false,
    this.showCursorTemp = true,
    this.showHotSpot = true,
    this.showColdSpot = false,
  });

  RenderParams copyWith({
    int? upsampleScale,
    UpsampleMethod? upsampleMethod,
    bool? bilateralEnabled,
    double? bilateralSigmaSpatial,
    double? bilateralSigmaIntensity,
    String? colormapName,
    String? mappingCurve,
    bool? useCustomColors,
    int? coldColor,
    int? midColor,
    int? hotColor,
    ThermalViewParams? thermalView,
    FusionParams? fusion,
    bool? showInfoOverlay,
    bool? showCursorTemp,
    bool? showHotSpot,
    bool? showColdSpot,
  }) {
    return RenderParams(
      upsampleScale: upsampleScale ?? this.upsampleScale,
      upsampleMethod: upsampleMethod ?? this.upsampleMethod,
      bilateralEnabled: bilateralEnabled ?? this.bilateralEnabled,
      bilateralSigmaSpatial:
          bilateralSigmaSpatial ?? this.bilateralSigmaSpatial,
      bilateralSigmaIntensity:
          bilateralSigmaIntensity ?? this.bilateralSigmaIntensity,
      colormapName: colormapName ?? this.colormapName,
      mappingCurve: mappingCurve ?? this.mappingCurve,
      useCustomColors: useCustomColors ?? this.useCustomColors,
      coldColor: coldColor ?? this.coldColor,
      midColor: midColor ?? this.midColor,
      hotColor: hotColor ?? this.hotColor,
      thermalView: thermalView ?? this.thermalView,
      fusion: fusion ?? this.fusion,
      showInfoOverlay: showInfoOverlay ?? this.showInfoOverlay,
      showCursorTemp: showCursorTemp ?? this.showCursorTemp,
      showHotSpot: showHotSpot ?? this.showHotSpot,
      showColdSpot: showColdSpot ?? this.showColdSpot,
    );
  }

  /// 序列化为可写入 .btpkg meta 的 JSON Map (字段名稳定, 增加新字段时保持向后兼容).
  Map<String, dynamic> toJson() => {
    'upsampleScale': upsampleScale,
    'upsampleMethod': upsampleMethod.name,
    'bilateralEnabled': bilateralEnabled,
    'bilateralSigmaSpatial': bilateralSigmaSpatial,
    'bilateralSigmaIntensity': bilateralSigmaIntensity,
    'colormapName': colormapName,
    'mappingCurve': mappingCurve,
    'useCustomColors': useCustomColors,
    'coldColor': coldColor,
    'midColor': midColor,
    'hotColor': hotColor,
    'thermalView': thermalView.toJson(),
    'fusion': fusion.toJson(),
    'showInfoOverlay': showInfoOverlay,
    'showCursorTemp': showCursorTemp,
    'showHotSpot': showHotSpot,
    'showColdSpot': showColdSpot,
  };

  factory RenderParams.fromJson(Map<String, dynamic> j) {
    UpsampleMethod parseMethod(String? s) {
      for (final m in UpsampleMethod.values) {
        if (m.name == s) return m;
      }
      return UpsampleMethod.bicubic;
    }

    final fusionJson = j['fusion'];
    final thermalViewJson = j['thermalView'];
    return RenderParams(
      upsampleScale: (j['upsampleScale'] as num?)?.toInt() ?? 8,
      upsampleMethod: parseMethod(j['upsampleMethod'] as String?),
      bilateralEnabled: j['bilateralEnabled'] as bool? ?? true,
      bilateralSigmaSpatial:
          (j['bilateralSigmaSpatial'] as num?)?.toDouble() ?? 1.5,
      bilateralSigmaIntensity:
          (j['bilateralSigmaIntensity'] as num?)?.toDouble() ?? 1.5,
      colormapName: j['colormapName'] as String? ?? 'jet',
      mappingCurve: j['mappingCurve'] as String? ?? 'linear',
      useCustomColors: j['useCustomColors'] as bool? ?? false,
      coldColor: (j['coldColor'] as num?)?.toInt() ?? 0x0000FF,
      midColor: (j['midColor'] as num?)?.toInt() ?? 0x00FF00,
      hotColor: (j['hotColor'] as num?)?.toInt() ?? 0xFF0000,
      thermalView: thermalViewJson is Map<String, dynamic>
          ? ThermalViewParams.fromJson(thermalViewJson)
          : const ThermalViewParams(),
      fusion: fusionJson is Map<String, dynamic>
          ? FusionParams.fromJson(fusionJson)
          : const FusionParams(),
      showInfoOverlay: j['showInfoOverlay'] as bool? ?? false,
      showCursorTemp: j['showCursorTemp'] as bool? ?? true,
      showHotSpot: j['showHotSpot'] as bool? ?? true,
      showColdSpot: j['showColdSpot'] as bool? ?? false,
    );
  }
}
