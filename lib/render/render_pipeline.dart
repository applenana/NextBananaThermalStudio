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

  const RenderedFrame({
    required this.rgb,
    required this.width,
    required this.height,
    required this.normalizedField,
    required this.temperatureField,
    required this.tMin,
    required this.tMax,
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

  // -- 步骤 2: 上采样 (在温度空间, 数值更平滑) --
  final scale = params.upsampleScale.clamp(1, 32);
  final dstW = srcW * scale;
  final dstH = srcH * scale;
  final upField = scale == 1
      ? Float32List.fromList(field)
      : upsample(
          src: field,
          srcW: srcW,
          srcH: srcH,
          dstW: dstW,
          dstH: dstH,
          method: params.upsampleMethod,
        );

  // -- 步骤 3: 归一化 (上采样后再算 min/max, 避免插值后超出原 range) --
  double mn = double.infinity, mx = -double.infinity;
  for (final v in upField) {
    if (v.isNaN) continue;
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
  );
}
