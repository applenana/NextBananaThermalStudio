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

  // ---- 融合 ----
  final FusionParams fusion;

  // ---- 显示选项 ----
  /// 在图片上叠加 Tmax/Tmin/Tavg 信息条 (用于 Photo Tab 导出和实时可选)
  final bool showInfoOverlay;

  /// 显示十字光标 + 鼠标悬浮取温
  final bool showCursorTemp;

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
    this.fusion = const FusionParams(),
    this.showInfoOverlay = false,
    this.showCursorTemp = true,
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
    FusionParams? fusion,
    bool? showInfoOverlay,
    bool? showCursorTemp,
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
      fusion: fusion ?? this.fusion,
      showInfoOverlay: showInfoOverlay ?? this.showInfoOverlay,
      showCursorTemp: showCursorTemp ?? this.showCursorTemp,
    );
  }
}
