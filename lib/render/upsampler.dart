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

/// 按设备固件 `BilinearInterpolation.h::_rebuild_lut()` 的源窗口规则上采样。
///
/// 坐标先量化为 Q10，边缘钳制也与固件保持一致；采样核仍服从上位机当前选择
/// 的 nearest / bilinear / bicubic，从而只同步设备的缩放与平移，不覆盖用户
/// 已选择的插值质量。
Float32List upsampleThermalView({
  required Float32List src,
  required int srcW,
  required int srcH,
  required int dstW,
  required int dstH,
  required double scale,
  required int xOffset,
  required int yOffset,
  UpsampleMethod method = UpsampleMethod.bicubic,
}) {
  final maxX = srcW - 1;
  final maxY = srcH - 1;
  final safeScale = scale.clamp(1.0, 2.0);

  double xStart;
  double yStart;
  double xEnd;
  double yEnd;
  if (safeScale > 1.01) {
    final halfW = maxX / (2.0 * safeScale);
    final halfH = maxY / (2.0 * safeScale);
    var centerX = srcW / 2.0;
    var centerY = srcH / 2.0;
    if (centerX - halfW < 0) centerX = halfW;
    if (centerX + halfW > maxX) centerX = maxX - halfW;
    if (centerY - halfH < 0) centerY = halfH;
    if (centerY + halfH > maxY) centerY = maxY - halfH;
    xStart = centerX - halfW;
    yStart = centerY - halfH;
    xEnd = centerX + halfW;
    yEnd = centerY + halfH;
  } else {
    xStart = 0;
    yStart = 0;
    xEnd = maxX.toDouble();
    yEnd = maxY.toDouble();
  }

  final panX = xOffset / 10.0;
  final panY = yOffset / 10.0;
  xStart += panX;
  xEnd += panX;
  yStart += panY;
  yEnd += panY;

  final xCoords = _firmwareCoords(
    start: xStart,
    span: xEnd - xStart,
    dstSize: dstW,
    srcMax: maxX,
  );
  final yCoords = _firmwareCoords(
    start: yStart,
    span: yEnd - yStart,
    dstSize: dstH,
    srcMax: maxY,
  );

  final out = Float32List(dstW * dstH);
  for (int y = 0; y < dstH; y++) {
    final cy = yCoords[y];
    for (int x = 0; x < dstW; x++) {
      final cx = xCoords[x];
      out[y * dstW + x] = switch (method) {
        UpsampleMethod.nearest => _sampleNearest(src, srcW, cx, cy),
        UpsampleMethod.bilinear => _sampleBilinear(src, srcW, cx, cy),
        UpsampleMethod.bicubic => _sampleBicubic(src, srcW, srcH, cx, cy),
      };
    }
  }
  return out;
}

class _FirmwareCoord {
  final int idx0;
  final int idx1;
  final int fracQ10;

  const _FirmwareCoord(this.idx0, this.idx1, this.fracQ10);
}

List<_FirmwareCoord> _firmwareCoords({
  required double start,
  required double span,
  required int dstSize,
  required int srcMax,
}) {
  final startQ10 = (start * 1024.0).toInt();
  final spanQ10 = (span * 1024.0).toInt();
  final denominator = 2 * dstSize;
  return List<_FirmwareCoord>.generate(dstSize, (d) {
    final srcQ10 = startQ10 - 512 + ((2 * d + 1) * spanQ10) ~/ denominator;
    var idx0 = srcQ10 >> 10;
    var idx1 = idx0 + 1;
    var frac = srcQ10 - (idx0 << 10);
    if (idx0 < 0) {
      idx0 = 0;
      frac = 0;
    }
    if (idx1 < 0) idx1 = 0;
    if (idx1 > srcMax) idx1 = srcMax;
    if (idx0 > srcMax) idx0 = srcMax;
    if (frac < 0) frac = 0;
    return _FirmwareCoord(idx0, idx1, frac);
  }, growable: false);
}

double _sampleNearest(
  Float32List src,
  int srcW,
  _FirmwareCoord x,
  _FirmwareCoord y,
) {
  final sx = x.fracQ10 < 512 ? x.idx0 : x.idx1;
  final sy = y.fracQ10 < 512 ? y.idx0 : y.idx1;
  return src[sy * srcW + sx];
}

double _sampleBilinear(
  Float32List src,
  int srcW,
  _FirmwareCoord x,
  _FirmwareCoord y,
) {
  final fx = x.fracQ10 / 1024.0;
  final fy = y.fracQ10 / 1024.0;
  final v00 = src[y.idx0 * srcW + x.idx0];
  final v10 = src[y.idx0 * srcW + x.idx1];
  final v01 = src[y.idx1 * srcW + x.idx0];
  final v11 = src[y.idx1 * srcW + x.idx1];
  final a = v00 * (1.0 - fx) + v10 * fx;
  final b = v01 * (1.0 - fx) + v11 * fx;
  return a * (1.0 - fy) + b * fy;
}

double _sampleBicubic(
  Float32List src,
  int srcW,
  int srcH,
  _FirmwareCoord x,
  _FirmwareCoord y,
) {
  // 固件在窗口越界时会把 idx0/idx1 同时钳制到边缘。此时坐标也必须
  // 固定在边缘，不能让 bicubic 核再次混入倒数第二行/列。
  final sx = x.idx0 == x.idx1 ? x.idx0.toDouble() : x.idx0 + x.fracQ10 / 1024.0;
  final sy = y.idx0 == y.idx1 ? y.idx0.toDouble() : y.idx0 + y.fracQ10 / 1024.0;
  final ix = sx.floor();
  final iy = sy.floor();
  double acc = 0;
  for (int dy = -1; dy <= 2; dy++) {
    final yy = (iy + dy).clamp(0, srcH - 1);
    final wy = _cubicKernel(sy - (iy + dy));
    for (int dx = -1; dx <= 2; dx++) {
      final xx = (ix + dx).clamp(0, srcW - 1);
      final wx = _cubicKernel(sx - (ix + dx));
      acc += src[yy * srcW + xx] * wx * wy;
    }
  }
  return acc;
}

Float32List _nearest(Float32List src, int sw, int sh, int dw, int dh) {
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

Float32List _bilinear(Float32List src, int sw, int sh, int dw, int dh) {
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

Float32List _bicubic(Float32List src, int sw, int sh, int dw, int dh) {
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
