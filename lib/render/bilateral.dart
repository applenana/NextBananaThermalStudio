/// 双边滤波 (Bilateral Filter) - 保边降噪.
///
/// 给定 2D 浮点矩阵, 每个像素加权平均其邻域:
///   w(p,q) = exp(-||p-q||^2 / (2*sigmaS^2)) * exp(-|I(p)-I(q)|^2 / (2*sigmaR^2))
///
/// 邻域半径 = ceil(2 * sigmaS), 上限 6 (避免 24x32 上反复 O(N*r^2) 爆开销).
library;

import 'dart:math' as math;
import 'dart:typed_data';

Float32List bilateralFilter({
  required Float32List src,
  required int width,
  required int height,
  double sigmaSpatial = 1.5,
  double sigmaIntensity = 1.5,
}) {
  if (sigmaSpatial <= 0 || sigmaIntensity <= 0) {
    return Float32List.fromList(src);
  }
  final r = math.min(6, math.max(1, (2 * sigmaSpatial).ceil()));

  // 预计算空间权重
  final spatial = Float32List((2 * r + 1) * (2 * r + 1));
  final invSpatial = 1.0 / (2 * sigmaSpatial * sigmaSpatial);
  for (int dy = -r; dy <= r; dy++) {
    for (int dx = -r; dx <= r; dx++) {
      spatial[(dy + r) * (2 * r + 1) + (dx + r)] =
          math.exp(-(dx * dx + dy * dy) * invSpatial);
    }
  }
  final invIntensity = 1.0 / (2 * sigmaIntensity * sigmaIntensity);

  final out = Float32List(src.length);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final i = y * width + x;
      final ip = src[i];
      double sumW = 0;
      double sumV = 0;
      for (int dy = -r; dy <= r; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= height) continue;
        for (int dx = -r; dx <= r; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= width) continue;
          final iq = src[yy * width + xx];
          final diff = ip - iq;
          final w = spatial[(dy + r) * (2 * r + 1) + (dx + r)] *
              math.exp(-(diff * diff) * invIntensity);
          sumW += w;
          sumV += w * iq;
        }
      }
      out[i] = sumW > 0 ? sumV / sumW : ip;
    }
  }
  return out;
}
