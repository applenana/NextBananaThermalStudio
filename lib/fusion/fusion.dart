/// 伪彩着色 + 可见光/热成像融合 (Dart 端实现, 与 fusion_utils.py 行为对齐).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'colormap.dart';

/// 把 0~1 归一化的浮点数据映射为 RGB888 字节图 (行优先, 长度 = w*h*3).
///
/// * [mappingCurve]: 'linear' 或 'nonlinear' (S 形曲线).
/// * [useCustomColors]=true 时走三色线性插值 (cold→mid→hot).
/// * 否则按 [colormapName] 取内置 colormap, 数据先线性裁剪到 0.05~0.95
///   再查表 (与 fusion_utils.py 一致).
Uint8List colorize({
  required Float32List normalized,
  required int width,
  required int height,
  String colormapName = 'jet',
  String mappingCurve = 'linear',
  bool useCustomColors = false,
  int coldColor = 0x0000FF,
  int midColor = 0x00FF00,
  int hotColor = 0xFF0000,
}) {
  assert(normalized.length == width * height,
      'normalized length != width*height');

  final data = Float32List(normalized.length);
  for (int i = 0; i < normalized.length; i++) {
    var v = normalized[i];
    if (v.isNaN) v = 0.0;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    if (mappingCurve == 'nonlinear') {
      v = _sCurve(v, 2.5);
    }
    data[i] = v;
  }

  final out = Uint8List(normalized.length * 3);

  if (useCustomColors) {
    final cr = (coldColor >> 16) & 0xFF, cg = (coldColor >> 8) & 0xFF, cb = coldColor & 0xFF;
    final mr = (midColor >> 16) & 0xFF, mg = (midColor >> 8) & 0xFF, mb = midColor & 0xFF;
    final hr = (hotColor >> 16) & 0xFF, hg = (hotColor >> 8) & 0xFF, hb = hotColor & 0xFF;
    for (int i = 0, j = 0; i < data.length; i++, j += 3) {
      final v = data[i];
      if (v <= 0.5) {
        final t = v * 2;
        out[j] = (cr * (1 - t) + mr * t).round();
        out[j + 1] = (cg * (1 - t) + mg * t).round();
        out[j + 2] = (cb * (1 - t) + mb * t).round();
      } else {
        final t = (v - 0.5) * 2;
        out[j] = (mr * (1 - t) + hr * t).round();
        out[j + 1] = (mg * (1 - t) + hg * t).round();
        out[j + 2] = (mb * (1 - t) + hb * t).round();
      }
    }
    return out;
  }

  final lut = getColormapLut(colormapName);
  for (int i = 0, j = 0; i < data.length; i++, j += 3) {
    // 裁剪到 0.05~0.95 (避免两端过黑/过白, 与 Python 一致)
    final clipped = data[i] * 0.9 + 0.05;
    final idx = (clipped * 255.0).round().clamp(0, 255);
    out[j] = lut[idx * 3];
    out[j + 1] = lut[idx * 3 + 1];
    out[j + 2] = lut[idx * 3 + 2];
  }
  return out;
}

/// 把 24x32 热像帧 (浮点摄氏度) → 渲染后的 RGB888 图像 (使用动态 min/max 归一化).
Uint8List renderThermalRgb({
  required Float32List frame,
  required int width,
  required int height,
  String colormapName = 'jet',
  String mappingCurve = 'linear',
  bool useCustomColors = false,
  int coldColor = 0x0000FF,
  int midColor = 0x00FF00,
  int hotColor = 0xFF0000,
  double? minOverride,
  double? maxOverride,
}) {
  double mn = double.infinity, mx = -double.infinity;
  for (final v in frame) {
    if (v < mn) mn = v;
    if (v > mx) mx = v;
  }
  final lo = minOverride ?? mn;
  final hi = maxOverride ?? mx;
  final span = (hi - lo).abs() < 1e-6 ? 1.0 : (hi - lo);

  final norm = Float32List(frame.length);
  for (int i = 0; i < frame.length; i++) {
    norm[i] = ((frame[i] - lo) / span).clamp(0.0, 1.0);
  }
  return colorize(
    normalized: norm,
    width: width,
    height: height,
    colormapName: colormapName,
    mappingCurve: mappingCurve,
    useCustomColors: useCustomColors,
    coldColor: coldColor,
    midColor: midColor,
    hotColor: hotColor,
  );
}

double _sCurve(double x, double power) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final ratio = (1.0 - x) / math.max(x, 1e-9);
  return 1.0 / (1.0 + math.pow(ratio, power));
}

// ===========================================================================
// 融合
// ===========================================================================

enum FusionMode { off, blend, edge }

class FusionParams {
  final FusionMode mode;
  final double gamma;
  final double alpha;
  final double edgeStrength;
  final double edgeThresh;
  /// 边缘粗细 (px). 取值范围 [0, 6]:
  /// * < 0.75: 在 2x 超分图上做边缘检测得到亚像素细边
  /// * 1: 1 像素细边 (NMS, 不膨胀)
  /// * > 1: NMS 后向外膨胀 round(value-1) 像素
  final double edgeWidth;
  final int edgeColor; // 0xRRGGBB

  const FusionParams({
    this.mode = FusionMode.off,
    this.gamma = 1.0,
    this.alpha = 0.5,
    this.edgeStrength = 0.6,
    this.edgeThresh = 0.082,
    this.edgeWidth = 1.0,
    this.edgeColor = 0x333333,
  });
}

/// 对单帧执行融合.
///
/// * [thermalRgb]: 已 colorize 的热像 RGB888, 长度 = tw*th*3
/// * [visibleRgb]: 可见光 RGB888 (原始分辨率), 长度 = vw*vh*3. 传 null 跳过.
/// * 返回融合后 RGB888, 尺寸 = tw*th*3 (与热像一致).
Uint8List fuse({
  required Uint8List thermalRgb,
  required int tw,
  required int th,
  Uint8List? visibleRgb,
  int vw = 0,
  int vh = 0,
  FusionParams params = const FusionParams(),
}) {
  if (visibleRgb == null || params.mode == FusionMode.off || vw == 0 || vh == 0) {
    return thermalRgb;
  }

  // 转 image 包对象做 resize / gamma
  final visImage = img.Image.fromBytes(
    width: vw,
    height: vh,
    bytes: visibleRgb.buffer,
    bytesOffset: visibleRgb.offsetInBytes,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );

  if (params.mode == FusionMode.blend) {
    final visResized = img.copyResize(visImage,
        width: tw, height: th, interpolation: img.Interpolation.linear);
    final gammaInv = 1.0 / (params.gamma <= 0 ? 1.0 : params.gamma);
    final a = params.alpha.clamp(0.0, 1.0);
    final oneMinusA = 1.0 - a;

    // 预算 256 项 gamma LUT, 避免每像素 3 次 pow
    final gammaLut = Uint8List(256);
    for (int k = 0; k < 256; k++) {
      gammaLut[k] = (math.pow(k / 255.0, gammaInv) * 255.0).round().clamp(0, 255).toInt();
    }

    final out = Uint8List(tw * th * 3);
    final visBytes = visResized.getBytes(order: img.ChannelOrder.rgb);
    final n = tw * th;
    for (int i = 0; i < n; i++) {
      final tj = i * 3;
      final vr = gammaLut[visBytes[tj]];
      final vg = gammaLut[visBytes[tj + 1]];
      final vb = gammaLut[visBytes[tj + 2]];
      out[tj] = (thermalRgb[tj] * oneMinusA + vr * a).toInt();
      out[tj + 1] = (thermalRgb[tj + 1] * oneMinusA + vg * a).toInt();
      out[tj + 2] = (thermalRgb[tj + 2] * oneMinusA + vb * a).toInt();
    }
    return out;
  }

  // edge 模式: 在工作分辨率 (tw*ss × th*ss) 上做 Sobel+NMS, 再面积平均下采样回 tw×th
  // 得到亚像素细边. ss=4 → 1/4 px, ss=2 → 1/2 px, ss=1 → 1 px (再可膨胀).
  if (params.mode == FusionMode.edge) {
    final ew = params.edgeWidth.clamp(0.0, 6.0);
    final int ss = ew < 0.375 ? 4 : (ew < 0.75 ? 2 : 1);
    final int gw = tw * ss;
    final int gh = th * ss;

    final visResized = img.copyResize(visImage,
        width: gw, height: gh, interpolation: img.Interpolation.linear);
    final visBytes = visResized.getBytes(order: img.ChannelOrder.rgb);
    final gray = Float32List(gw * gh);
    for (int i = 0; i < gw * gh; i++) {
      final j = i * 3;
      gray[i] = (visBytes[j] + visBytes[j + 1] + visBytes[j + 2]) / 3.0;
    }
    final t = params.edgeThresh.clamp(0.0, 1.0) * 1020.0;
    final mag = Float32List(gw * gh);
    final gxArr = Float32List(gw * gh);
    final gyArr = Float32List(gw * gh);
    for (int y = 1; y < gh - 1; y++) {
      for (int x = 1; x < gw - 1; x++) {
        final i = y * gw + x;
        final gx = -gray[i - gw - 1] + gray[i - gw + 1]
            - 2 * gray[i - 1] + 2 * gray[i + 1]
            - gray[i + gw - 1] + gray[i + gw + 1];
        final gy = -gray[i - gw - 1] - 2 * gray[i - gw] - gray[i - gw + 1]
            + gray[i + gw - 1] + 2 * gray[i + gw] + gray[i + gw + 1];
        gxArr[i] = gx;
        gyArr[i] = gy;
        mag[i] = gx.abs() + gy.abs();
      }
    }
    // NMS: 沿梯度方向 (量化为 4 方向) 比较前后两邻居, 仅保留局部最大
    Uint8List maskHigh = Uint8List(gw * gh);
    for (int y = 1; y < gh - 1; y++) {
      for (int x = 1; x < gw - 1; x++) {
        final i = y * gw + x;
        final m = mag[i];
        if (m <= t) continue;
        final gx = gxArr[i].abs();
        final gy = gyArr[i].abs();
        int n1, n2;
        if (gx >= gy * 2.414) {
          n1 = i - 1; n2 = i + 1;
        } else if (gy >= gx * 2.414) {
          n1 = i - gw; n2 = i + gw;
        } else if ((gxArr[i] > 0) == (gyArr[i] > 0)) {
          n1 = i - gw - 1; n2 = i + gw + 1;
        } else {
          n1 = i - gw + 1; n2 = i + gw - 1;
        }
        if (m >= mag[n1] && m >= mag[n2]) {
          maskHigh[i] = 255;
        }
      }
    }

    // 下采样: ss>1 时用面积均值, 得到亚像素抗锯齿细边
    Uint8List maskBytes;
    if (ss == 1) {
      maskBytes = maskHigh;
    } else {
      maskBytes = Uint8List(tw * th);
      final invCellArea = 1.0 / (ss * ss);
      for (int y = 0; y < th; y++) {
        for (int x = 0; x < tw; x++) {
          int sum = 0;
          final y0 = y * ss;
          final x0 = x * ss;
          for (int dy = 0; dy < ss; dy++) {
            final row = (y0 + dy) * gw + x0;
            for (int dx = 0; dx < ss; dx++) {
              sum += maskHigh[row + dx];
            }
          }
          maskBytes[y * tw + x] = (sum * invCellArea).round().clamp(0, 255);
        }
      }
    }

    // 膨胀仅在 ew >= 1 时启用, 量为 round(ew - 1)
    final int dilateW = ew >= 1.0 ? (ew - 1.0).round().clamp(0, 5) : 0;
    if (dilateW > 0) {
      final w = dilateW;
      final tmp1 = Uint8List(tw * th);
      for (int y = 0; y < th; y++) {
        for (int x = 0; x < tw; x++) {
          int v = 0;
          final x0 = (x - w) < 0 ? 0 : x - w;
          final x1 = (x + w) >= tw ? tw - 1 : x + w;
          for (int nx = x0; nx <= x1; nx++) {
            final mv = maskBytes[y * tw + nx];
            if (mv > v) { v = mv; if (v == 255) break; }
          }
          tmp1[y * tw + x] = v;
        }
      }
      final tmp2 = Uint8List(tw * th);
      for (int x = 0; x < tw; x++) {
        for (int y = 0; y < th; y++) {
          int v = 0;
          final y0 = (y - w) < 0 ? 0 : y - w;
          final y1 = (y + w) >= th ? th - 1 : y + w;
          for (int ny = y0; ny <= y1; ny++) {
            final mv = tmp1[ny * tw + x];
            if (mv > v) { v = mv; if (v == 255) break; }
          }
          tmp2[y * tw + x] = v;
        }
      }
      maskBytes = tmp2;
    }

    final s = params.edgeStrength.clamp(0.0, 1.0);
    final er = (params.edgeColor >> 16) & 0xFF;
    final eg = (params.edgeColor >> 8) & 0xFF;
    final eb = params.edgeColor & 0xFF;

    final out = Uint8List(tw * th * 3);
    for (int i = 0; i < tw * th; i++) {
      final tj = i * 3;
      final m = (maskBytes[i] / 255.0) * s;
      out[tj] = ((thermalRgb[tj] * (1 - m) + er * m)).round().clamp(0, 255);
      out[tj + 1] = ((thermalRgb[tj + 1] * (1 - m) + eg * m)).round().clamp(0, 255);
      out[tj + 2] = ((thermalRgb[tj + 2] * (1 - m) + eb * m)).round().clamp(0, 255);
    }
    return out;
  }

  return thermalRgb;
}
