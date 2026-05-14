/// 2D 浮点上采样: nearest / bilinear / bicubic.
///
/// 输入: 行优先 Float32List, 尺寸 srcW * srcH.
/// 输出: 行优先 Float32List, 尺寸 dstW * dstH.
///
/// 在归一化前的原始数值空间插值, 数值更平滑, 之后再 colormap.
library;

import 'dart:typed_data';

import 'render_params.dart';

Float32List upsample({
  required Float32List src,
  required int srcW,
  required int srcH,
  required int dstW,
  required int dstH,
  UpsampleMethod method = UpsampleMethod.bicubic,
}) {
  if (srcW == dstW && srcH == dstH) {
    return Float32List.fromList(src);
  }
  switch (method) {
    case UpsampleMethod.nearest:
      return _nearest(src, srcW, srcH, dstW, dstH);
    case UpsampleMethod.bilinear:
      return _bilinear(src, srcW, srcH, dstW, dstH);
    case UpsampleMethod.bicubic:
      return _bicubic(src, srcW, srcH, dstW, dstH);
  }
}

Float32List _nearest(
    Float32List src, int sw, int sh, int dw, int dh) {
  final out = Float32List(dw * dh);
  final fx = sw / dw;
  final fy = sh / dh;
  for (int y = 0; y < dh; y++) {
    final sy = (y * fy).floor().clamp(0, sh - 1);
    for (int x = 0; x < dw; x++) {
      final sx = (x * fx).floor().clamp(0, sw - 1);
      out[y * dw + x] = src[sy * sw + sx];
    }
  }
  return out;
}

Float32List _bilinear(
    Float32List src, int sw, int sh, int dw, int dh) {
  final out = Float32List(dw * dh);
  // 用 "样本中心对齐" 的映射 (对边缘更友好):
  //   srcX = (dstX + 0.5) * sw/dw - 0.5
  final scaleX = sw / dw;
  final scaleY = sh / dh;
  for (int y = 0; y < dh; y++) {
    final sy = (y + 0.5) * scaleY - 0.5;
    int y0 = sy.floor();
    final ty = sy - y0;
    if (y0 < 0) y0 = 0;
    int y1 = y0 + 1;
    if (y1 > sh - 1) y1 = sh - 1;
    if (y0 > sh - 1) y0 = sh - 1;
    for (int x = 0; x < dw; x++) {
      final sx = (x + 0.5) * scaleX - 0.5;
      int x0 = sx.floor();
      final tx = sx - x0;
      if (x0 < 0) x0 = 0;
      int x1 = x0 + 1;
      if (x1 > sw - 1) x1 = sw - 1;
      if (x0 > sw - 1) x0 = sw - 1;
      final v00 = src[y0 * sw + x0];
      final v10 = src[y0 * sw + x1];
      final v01 = src[y1 * sw + x0];
      final v11 = src[y1 * sw + x1];
      final a = v00 * (1 - tx) + v10 * tx;
      final b = v01 * (1 - tx) + v11 * tx;
      out[y * dw + x] = a * (1 - ty) + b * ty;
    }
  }
  return out;
}

// Catmull-Rom 卷积核 (a = -0.5)
double _cubicKernel(double t) {
  final at = t.abs();
  if (at < 1.0) {
    return (1.5 * at - 2.5) * at * at + 1.0;
  } else if (at < 2.0) {
    return ((-0.5 * at + 2.5) * at - 4.0) * at + 2.0;
  }
  return 0.0;
}

Float32List _bicubic(
    Float32List src, int sw, int sh, int dw, int dh) {
  final out = Float32List(dw * dh);
  final scaleX = sw / dw;
  final scaleY = sh / dh;
  for (int y = 0; y < dh; y++) {
    final sy = (y + 0.5) * scaleY - 0.5;
    final iy = sy.floor();
    final fy = sy - iy;
    final wy0 = _cubicKernel(1 + fy);
    final wy1 = _cubicKernel(fy);
    final wy2 = _cubicKernel(1 - fy);
    final wy3 = _cubicKernel(2 - fy);
    for (int x = 0; x < dw; x++) {
      final sx = (x + 0.5) * scaleX - 0.5;
      final ix = sx.floor();
      final fx = sx - ix;
      final wx0 = _cubicKernel(1 + fx);
      final wx1 = _cubicKernel(fx);
      final wx2 = _cubicKernel(1 - fx);
      final wx3 = _cubicKernel(2 - fx);

      double acc = 0;
      for (int dy = -1; dy <= 2; dy++) {
        int yy = iy + dy;
        if (yy < 0) yy = 0;
        if (yy > sh - 1) yy = sh - 1;
        double row = 0;
        for (int dx = -1; dx <= 2; dx++) {
          int xx = ix + dx;
          if (xx < 0) xx = 0;
          if (xx > sw - 1) xx = sw - 1;
          final v = src[yy * sw + xx];
          final wx = dx == -1
              ? wx0
              : dx == 0
                  ? wx1
                  : dx == 1
                      ? wx2
                      : wx3;
          row += v * wx;
        }
        final wy = dy == -1
            ? wy0
            : dy == 0
                ? wy1
                : dy == 1
                    ? wy2
                    : wy3;
        acc += row * wy;
      }
      out[y * dw + x] = acc;
    }
  }
  return out;
}
