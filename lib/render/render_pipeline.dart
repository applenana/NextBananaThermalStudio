/// 渲染流水线: 把 Float32 温度帧 + 可选可见光 + RenderParams -> RGB888.
///
/// 流水线步骤:
///   1. 双边滤波 (在原始温度空间, 保边降噪)
///   2. min/max 归一化
///   3. 上采样到 srcW*scale x srcH*scale (在归一化空间)
///   4. 映射曲线 + colormap -> RGB
///   5. 与可见光融合 (在上采样后的尺寸做)
library;

import 'dart:typed_data';

import '../fusion/fusion.dart';
import 'bilateral.dart';
import 'render_params.dart';
import 'upsampler.dart';

class RenderedFrame {
  /// 渲染后的 RGB888 行优先字节. 长度 = width*height*3.
  final Uint8List rgb;
  final int width;
  final int height;

  /// 上采样后的归一化数据 (用于鼠标取温反算: 归一化->原始度数 = norm*(tMax-tMin)+tMin)
  final Float32List normalizedField;

  /// 上采样后的真实温度场 (摄氏度), 与 [normalizedField] 同尺寸.
  /// 鼠标悬浮时直接 [y*width+x] 取值, 不必反算归一化.
  final Float32List temperatureField;

  /// 实际使用的归一化范围 (摄氏度).
  final double tMin;
  final double tMax;

  /// 与本帧热像着色完全同源的低温→高温 RGB 色标采样。
  ///
  /// 每 3 个字节为一个 RGB888 颜色。它在可见光融合前生成，因此即使最终
  /// [rgb] 是融合图，也仍然准确描述热像层的温度颜色映射。
  final Uint8List thermalColorScaleRgb;

  /// 原始热像场是否至少包含一个有限温度值。
  final bool hasFiniteTemperatureData;

  const RenderedFrame({
    required this.rgb,
    required this.width,
    required this.height,
    required this.normalizedField,
    required this.temperatureField,
    required this.tMin,
    required this.tMax,
    required this.thermalColorScaleRgb,
    required this.hasFiniteTemperatureData,
  });
}

RenderedFrame renderPipeline({
  required Float32List thermalFrame,
  required int srcW,
  required int srcH,
  required RenderParams params,
  Uint8List? visibleRgb,
  int visibleW = 0,
  int visibleH = 0,
  double? minOverride,
  double? maxOverride,
}) {
  // -- 步骤 1: 双边滤波 (温度空间) --
  Float32List field = thermalFrame;
  if (params.bilateralEnabled) {
    field = bilateralFilter(
      src: field,
      width: srcW,
      height: srcH,
      sigmaSpatial: params.bilateralSigmaSpatial,
      sigmaIntensity: params.bilateralSigmaIntensity,
    );
  }

  // MLX 方屏在线上仍传输真实 32x24。设备本机将它放入逻辑 32x32
  // 坐标空间后再应用方屏缩放/偏移；这一步在上位机复原同一条链路，
  // 避免弱算力固件发送 8 行重复温度。
  var workingW = srcW;
  var workingH = srcH;
  final thermalView = params.thermalView;
  if (thermalView.enabled &&
      thermalView.restoresMlxSquareChain &&
      srcW == 32 &&
      srcH == 24) {
    field = restoreMlxSquareContainer(
      field,
      sensorRotate180: thermalView.sensorRotate180,
    );
    workingH = 32;
  }

  // -- 步骤 2: 上采样 (在温度空间, 数值更平滑) --
  final scale = params.upsampleScale.clamp(1, 32);
  final dstW = workingW * scale;
  final dstH = workingH * scale;
  final upField = thermalView.enabled
      ? upsampleThermalView(
          src: field,
          srcW: workingW,
          srcH: workingH,
          dstW: dstW,
          dstH: dstH,
          scale: thermalView.scale,
          xOffset: thermalView.xOffset,
          yOffset: thermalView.yOffset,
          method: params.upsampleMethod,
        )
      : scale == 1
      ? Float32List.fromList(field)
      : upsample(
          src: field,
          srcW: workingW,
          srcH: workingH,
          dstW: dstW,
          dstH: dstH,
          method: params.upsampleMethod,
        );

  // -- 步骤 3: 归一化 (上采样后再算 min/max, 避免插值后超出原 range) --
  double mn = double.infinity, mx = -double.infinity;
  bool hasFiniteTemperatureData = false;
  for (final v in upField) {
    if (!v.isFinite) continue;
    hasFiniteTemperatureData = true;
    if (v < mn) mn = v;
    if (v > mx) mx = v;
  }
  if (!mn.isFinite) mn = 0;
  if (!mx.isFinite) mx = 1;
  final lo = minOverride ?? mn;
  final hi = maxOverride ?? mx;
  final span = (hi - lo).abs() < 1e-6 ? 1.0 : (hi - lo);
  final norm = Float32List(upField.length);
  for (int i = 0; i < upField.length; i++) {
    final n = (upField[i] - lo) / span;
    norm[i] = n.isNaN
        ? 0
        : n < 0
        ? 0
        : n > 1
        ? 1
        : n;
  }

  // -- 步骤 4: colormap -> RGB --
  final thermalRgb = colorize(
    normalized: norm,
    width: dstW,
    height: dstH,
    colormapName: params.colormapName,
    mappingCurve: params.mappingCurve,
    useCustomColors: params.useCustomColors,
    coldColor: params.coldColor,
    midColor: params.midColor,
    hotColor: params.hotColor,
  );
  final thermalColorScaleRgb = _buildThermalColorScale(params);

  // -- 步骤 5: 融合 --
  Uint8List outRgb = thermalRgb;
  if (visibleRgb != null &&
      visibleW > 0 &&
      visibleH > 0 &&
      params.fusion.mode != FusionMode.off) {
    outRgb = fuse(
      thermalRgb: thermalRgb,
      tw: dstW,
      th: dstH,
      visibleRgb: visibleRgb,
      vw: visibleW,
      vh: visibleH,
      params: params.fusion,
    );
  }

  return RenderedFrame(
    rgb: outRgb,
    width: dstW,
    height: dstH,
    normalizedField: norm,
    temperatureField: upField,
    tMin: lo,
    tMax: hi,
    thermalColorScaleRgb: thermalColorScaleRgb,
    hasFiniteTemperatureData: hasFiniteTemperatureData,
  );
}

/// Rebuilds the device's logical 32x32 MLX square-view container from the
/// transmitted, screen-oriented 32x24 temperature matrix.
Float32List restoreMlxSquareContainer(
  Float32List source, {
  required bool sensorRotate180,
}) {
  assert(source.length == 32 * 24);
  final output = Float32List(32 * 32);

  // AppState 已将线上帧垂直翻转到屏幕方向。对应设备 getValue() 的最终
  // 显示方向，旋转开启时上补 7/下补 1，关闭时上补 1/下补 7。
  final topPadding = sensorRotate180 ? 7 : 1;
  final bottomPadding = 8 - topPadding;
  for (var row = 0; row < topPadding; row++) {
    output.setRange(row * 32, (row + 1) * 32, source, 0);
  }
  for (var row = 0; row < 24; row++) {
    final sourceStart = row * 32;
    final destinationStart = (row + topPadding) * 32;
    output.setRange(
      destinationStart,
      destinationStart + 32,
      source,
      sourceStart,
    );
  }
  final lastRowStart = 23 * 32;
  for (var row = 0; row < bottomPadding; row++) {
    final destinationStart = (topPadding + 24 + row) * 32;
    output.setRange(
      destinationStart,
      destinationStart + 32,
      source,
      lastRowStart,
    );
  }
  return output;
}

const int _thermalColorScaleSteps = 64;
final Map<(String, String, bool, int, int, int), Uint8List>
_thermalColorScaleCache = {};

/// 通过正式的 [colorize] 路径生成色标，确保 S 曲线、内置色盘的
/// 0.05~0.95 端点裁剪和自定义三色插值都与画面完全一致。
Uint8List _buildThermalColorScale(RenderParams params) {
  final key = (
    params.colormapName,
    params.mappingCurve,
    params.useCustomColors,
    params.coldColor,
    params.midColor,
    params.hotColor,
  );
  final cached = _thermalColorScaleCache[key];
  if (cached != null) return cached;

  final normalized = Float32List(_thermalColorScaleSteps);
  for (int i = 0; i < normalized.length; i++) {
    normalized[i] = i / (normalized.length - 1);
  }
  final rgb = colorize(
    normalized: normalized,
    width: normalized.length,
    height: 1,
    colormapName: params.colormapName,
    mappingCurve: params.mappingCurve,
    useCustomColors: params.useCustomColors,
    coldColor: params.coldColor,
    midColor: params.midColor,
    hotColor: params.hotColor,
  );

  // 自定义色很多时限制缓存增长；内置色盘通常只会占用少量条目。
  if (_thermalColorScaleCache.length >= 32) {
    _thermalColorScaleCache.clear();
  }
  _thermalColorScaleCache[key] = rgb;
  return rgb;
}
