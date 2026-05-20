/// 自动视差对齐: Sobel 边缘 + 归一化互相关 (NCC) + 抛物线亚像素插值.
///
/// 输入:
///   thermalData  — Float32List, 原始温度值 (°C), 尺寸 tW×tH (行优先).
///   visibleRgb   — Uint8List, RGB888, 尺寸 vW×vH (行优先, 已旋转到与热像同方向).
/// 输出:
///   (dx, dy) 单位: 热像素. 正 dx → 热像画面相对可见光向右偏; 正 dy → 向下偏.
///   confidence  — NCC 峰值 [0,1]. < [kMinConfidence] 时不可靠, 上层不应更新偏移.
///
/// 此文件中所有函数均为纯 Dart 计算, 可直接置于 Isolate.run() 回调.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 最大搜索半径 (热像素整数步长, 候选数 = (2*r+1)^2 = 169).
const int kParallaxMaxSearch = 6;

/// NCC 峰值低于此阈值视为特征不足, 不更新偏移.
const double kMinConfidence = 0.15;

/// 视差计算结果.
class ParallaxResult {
  /// X 方向偏移 (热像素单位, 亚像素精度).
  final double dx;

  /// Y 方向偏移 (热像素单位, 亚像素精度).
  final double dy;

  /// NCC 峰值置信度 [0, 1].
  final double confidence;

  const ParallaxResult({
    required this.dx,
    required this.dy,
    required this.confidence,
  });
}

/// 计算热像与可见光的视差偏移.
///
/// 此函数是纯 Dart 计算, 可直接用 [Isolate.run] 包装.
ParallaxResult computeParallaxOffset({
  required Float32List thermalData,
  required int tW,
  required int tH,
  required Uint8List visibleRgb,
  required int vW,
  required int vH,
}) {
  // 1. 热像 → 归一化灰度 (Float32, 行优先, 值域 [0, 255])
  final thermalGray = _thermalToGray(thermalData, tW, tH);

  // 2. 可见光 → 面积平均下采样到热像分辨率 → 灰度
  final visibleGray = _visibleDownsampleGray(visibleRgb, vW, vH, tW, tH);

  // 3. Sobel 边缘幅值 (|Gx|+|Gy|, L1 加速; 边缘一圈为 0)
  final edgeT = _sobelMag(thermalGray, tW, tH);
  final edgeV = _sobelMag(visibleGray, tW, tH);

  // 4. NCC 整数网格搜索 + 抛物线亚像素插值
  return _nccSearch(edgeT, edgeV, tW, tH);
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

Float32List _thermalToGray(Float32List data, int w, int h) {
  double mn = double.infinity, mx = -double.infinity;
  for (final v in data) {
    if (!v.isFinite) continue;
    if (v < mn) mn = v;
    if (v > mx) mx = v;
  }
  final span = (mx - mn) < 1e-6 ? 1.0 : (mx - mn);
  final gray = Float32List(w * h);
  for (int i = 0; i < data.length; i++) {
    gray[i] = ((data[i] - mn) / span).clamp(0.0, 1.0) * 255.0;
  }
  return gray;
}

/// 面积平均下采样 + RGB→灰度 (BT.601 加权).
Float32List _visibleDownsampleGray(
    Uint8List rgb, int vW, int vH, int outW, int outH) {
  final gray = Float32List(outW * outH);
  final scaleX = vW / outW;
  final scaleY = vH / outH;
  for (int oy = 0; oy < outH; oy++) {
    final y0 = (oy * scaleY).floor();
    final y1 = ((oy + 1) * scaleY).ceil().clamp(0, vH);
    for (int ox = 0; ox < outW; ox++) {
      final x0 = (ox * scaleX).floor();
      final x1 = ((ox + 1) * scaleX).ceil().clamp(0, vW);
      double sum = 0;
      int count = 0;
      for (int vy = y0; vy < y1; vy++) {
        for (int vx = x0; vx < x1; vx++) {
          final idx = (vy * vW + vx) * 3;
          sum += rgb[idx] * 0.299 +
              rgb[idx + 1] * 0.587 +
              rgb[idx + 2] * 0.114;
          count++;
        }
      }
      gray[oy * outW + ox] = count > 0 ? sum / count : 0.0;
    }
  }
  return gray;
}

/// Sobel 边缘幅值 (L1: |Gx|+|Gy|). 边缘一圈像素设为 0.
Float32List _sobelMag(Float32List gray, int w, int h) {
  final mag = Float32List(w * h);
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final gx = -gray[i - w - 1] + gray[i - w + 1] //
          - 2 * gray[i - 1] + 2 * gray[i + 1] //
          - gray[i + w - 1] + gray[i + w + 1];
      final gy = -gray[i - w - 1] - 2 * gray[i - w] - gray[i - w + 1] //
          + gray[i + w - 1] + 2 * gray[i + w] + gray[i + w + 1];
      mag[i] = gx.abs() + gy.abs();
    }
  }
  return mag;
}

/// 在 dx,dy ∈ [-kParallaxMaxSearch, +kParallaxMaxSearch] 网格上搜索 NCC 最大值,
/// 然后对峰值做二次抛物线插值获得亚像素精度.
ParallaxResult _nccSearch(Float32List eT, Float32List eV, int w, int h) {
  final tMean = _mean(eT);
  final tStd = _std(eT, tMean);
  if (tStd < 1e-6) {
    return const ParallaxResult(dx: 0, dy: 0, confidence: 0);
  }

  const r = kParallaxMaxSearch;
  final diam = r * 2 + 1;
  final nccMap = Float32List(diam * diam);

  double bestNcc = -double.infinity;
  int bestDx = 0, bestDy = 0;

  for (int dy = -r; dy <= r; dy++) {
    for (int dx = -r; dx <= r; dx++) {
      final ncc = _nccAt(eT, eV, w, h, dx, dy, tMean, tStd);
      final idx = (dy + r) * diam + (dx + r);
      nccMap[idx] = ncc;
      if (ncc > bestNcc) {
        bestNcc = ncc;
        bestDx = dx;
        bestDy = dy;
      }
    }
  }

  if (bestNcc < kMinConfidence) {
    return ParallaxResult(dx: 0, dy: 0, confidence: bestNcc);
  }

  // 抛物线亚像素插值 (x 方向和 y 方向分别独立插值)
  double subDx = bestDx.toDouble();
  double subDy = bestDy.toDouble();

  final bxi = bestDx + r;
  final byi = bestDy + r;

  if (bxi > 0 && bxi < diam - 1) {
    final f0 = nccMap[byi * diam + bxi - 1];
    final f1 = nccMap[byi * diam + bxi];
    final f2 = nccMap[byi * diam + bxi + 1];
    final denom = 2 * f1 - f0 - f2;
    if (denom.abs() > 1e-6) {
      subDx = bestDx + (f0 - f2) / (2 * denom);
    }
  }

  if (byi > 0 && byi < diam - 1) {
    final f0 = nccMap[(byi - 1) * diam + bxi];
    final f1 = nccMap[byi * diam + bxi];
    final f2 = nccMap[(byi + 1) * diam + bxi];
    final denom = 2 * f1 - f0 - f2;
    if (denom.abs() > 1e-6) {
      subDy = bestDy + (f0 - f2) / (2 * denom);
    }
  }

  return ParallaxResult(dx: subDx, dy: subDy, confidence: bestNcc);
}

/// 在给定 (dx, dy) 偏移下计算 eT 与 eV 的 NCC.
/// 仅统计 eT 与 eV 都在有效范围内 (避边缘 1 圈) 的像素.
double _nccAt(Float32List eT, Float32List eV, int w, int h, int dx, int dy,
    double tMean, double tStd) {
  double crossSum = 0;
  double vSum = 0;
  double vSumSq = 0;
  int count = 0;

  for (int y = 1; y < h - 1; y++) {
    final vy = y + dy;
    if (vy < 1 || vy >= h - 1) continue;
    for (int x = 1; x < w - 1; x++) {
      final vx = x + dx;
      if (vx < 1 || vx >= w - 1) continue;
      final tVal = eT[y * w + x] - tMean;
      final vVal = eV[vy * w + vx];
      crossSum += tVal * vVal;
      vSum += vVal;
      vSumSq += vVal * vVal;
      count++;
    }
  }

  if (count == 0) return 0;

  final vMean = vSum / count;
  final vVar = vSumSq / count - vMean * vMean;
  final vStd = math.sqrt(vVar.clamp(0.0, double.infinity));
  if (vStd < 1e-6) return 0;

  return (crossSum / count) / (tStd * vStd);
}

double _mean(Float32List a) {
  double s = 0;
  for (final v in a) s += v;
  return s / a.length;
}

double _std(Float32List a, double mean) {
  double s = 0;
  for (final v in a) s += (v - mean) * (v - mean);
  return math.sqrt(s / a.length);
}
