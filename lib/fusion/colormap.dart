/// 调色板 (colormap) Dart 实现.
///
/// matplotlib 的 cmap 在 Python 端是 N×4 (RGBA) 浮点表; 这里把常用的几套
/// colormap 离散为 256 项 LUT (uint8 RGB) 内置. 数据是 matplotlib 标准表
/// 的 256 步采样, 双端视觉一致.
library;

import 'dart:typed_data';

/// 内置 colormap 名称.
const List<String> kBuiltinColormaps = [
  'jet',
  'hot',
  'inferno',
  'magma',
  'plasma',
  'viridis',
  'cividis',
  'turbo',
  'gray',
  'cool',
  'rainbow',
];

/// 返回 256*3 的 uint8 LUT (R,G,B,R,G,B,...).
///
/// 实现说明:
/// * 'gray' / 'jet' / 'hot' / 'cool' 由解析公式生成 (与 matplotlib 一致).
/// * 'inferno' / 'magma' / 'plasma' / 'viridis' / 'cividis' / 'turbo' /
///   'rainbow' 也用近似分段插值. 与 matplotlib 不是字节级精确, 但视觉
///   一致, 适合上位机展示.
Uint8List getColormapLut(String name) {
  final lower = name.toLowerCase();
  switch (lower) {
    case 'jet':
      return _generate(_jet);
    case 'hot':
      return _generate(_hot);
    case 'cool':
      return _generate(_cool);
    case 'gray':
    case 'grey':
      return _generate(_gray);
    case 'turbo':
      return _generate(_turbo);
    case 'viridis':
      return _generate(_viridis);
    case 'plasma':
      return _generate(_plasma);
    case 'inferno':
      return _generate(_inferno);
    case 'magma':
      return _generate(_magma);
    case 'cividis':
      return _generate(_cividis);
    case 'rainbow':
      return _generate(_rainbow);
    default:
      return _generate(_jet);
  }
}

typedef _CmapFn = List<double> Function(double t);

Uint8List _generate(_CmapFn fn) {
  final out = Uint8List(256 * 3);
  for (int i = 0; i < 256; i++) {
    final t = i / 255.0;
    final c = fn(t);
    out[i * 3] = (c[0] * 255.0).clamp(0, 255).toInt();
    out[i * 3 + 1] = (c[1] * 255.0).clamp(0, 255).toInt();
    out[i * 3 + 2] = (c[2] * 255.0).clamp(0, 255).toInt();
  }
  return out;
}

// ---------- 公式型 ----------

List<double> _gray(double t) => [t, t, t];

List<double> _jet(double t) {
  // matplotlib jet 的分段近似
  double r, g, b;
  if (t < 0.125) {
    r = 0;
    g = 0;
    b = 0.5 + 4 * t;
  } else if (t < 0.375) {
    r = 0;
    g = 4 * (t - 0.125);
    b = 1.0;
  } else if (t < 0.625) {
    r = 4 * (t - 0.375);
    g = 1.0;
    b = 1.0 - 4 * (t - 0.375);
  } else if (t < 0.875) {
    r = 1.0;
    g = 1.0 - 4 * (t - 0.625);
    b = 0;
  } else {
    r = 1.0 - 4 * (t - 0.875);
    g = 0;
    b = 0;
  }
  return [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
}

List<double> _hot(double t) {
  final r = (t / 0.375).clamp(0.0, 1.0);
  final g = ((t - 0.375) / 0.375).clamp(0.0, 1.0);
  final b = ((t - 0.75) / 0.25).clamp(0.0, 1.0);
  return [r, g, b];
}

List<double> _cool(double t) => [t, 1.0 - t, 1.0];

// 7 色彩虹
List<double> _rainbow(double t) => _interp(t, const [
      [148 / 255, 0 / 255, 211 / 255],
      [75 / 255, 0 / 255, 130 / 255],
      [0 / 255, 0 / 255, 1.0],
      [0 / 255, 1.0, 0 / 255],
      [1.0, 1.0, 0 / 255],
      [1.0, 127 / 255, 0 / 255],
      [1.0, 0 / 255, 0 / 255],
    ]);

// ---------- 控制点采样型 (matplotlib 离散关键点) ----------

List<double> _viridis(double t) => _interp(t, const [
      [0.267, 0.005, 0.329],
      [0.283, 0.130, 0.449],
      [0.254, 0.265, 0.530],
      [0.207, 0.372, 0.553],
      [0.164, 0.471, 0.558],
      [0.128, 0.567, 0.551],
      [0.135, 0.659, 0.518],
      [0.267, 0.749, 0.441],
      [0.477, 0.821, 0.318],
      [0.741, 0.873, 0.150],
      [0.993, 0.906, 0.144],
    ]);

List<double> _plasma(double t) => _interp(t, const [
      [0.050, 0.030, 0.528],
      [0.225, 0.014, 0.611],
      [0.396, 0.001, 0.643],
      [0.557, 0.045, 0.642],
      [0.692, 0.165, 0.564],
      [0.799, 0.279, 0.470],
      [0.881, 0.392, 0.383],
      [0.949, 0.522, 0.295],
      [0.987, 0.665, 0.197],
      [0.991, 0.812, 0.149],
      [0.940, 0.975, 0.131],
    ]);

List<double> _inferno(double t) => _interp(t, const [
      [0.001, 0.000, 0.014],
      [0.114, 0.041, 0.288],
      [0.260, 0.038, 0.420],
      [0.395, 0.083, 0.433],
      [0.527, 0.130, 0.422],
      [0.665, 0.182, 0.371],
      [0.787, 0.255, 0.291],
      [0.886, 0.354, 0.197],
      [0.961, 0.488, 0.085],
      [0.988, 0.652, 0.046],
      [0.988, 0.998, 0.645],
    ]);

List<double> _magma(double t) => _interp(t, const [
      [0.001, 0.000, 0.014],
      [0.084, 0.063, 0.260],
      [0.224, 0.063, 0.398],
      [0.365, 0.083, 0.432],
      [0.495, 0.131, 0.431],
      [0.629, 0.184, 0.413],
      [0.762, 0.247, 0.367],
      [0.881, 0.339, 0.337],
      [0.969, 0.499, 0.395],
      [0.996, 0.681, 0.520],
      [0.987, 0.991, 0.749],
    ]);

List<double> _cividis(double t) => _interp(t, const [
      [0.000, 0.135, 0.305],
      [0.000, 0.205, 0.426],
      [0.121, 0.279, 0.405],
      [0.226, 0.336, 0.418],
      [0.314, 0.396, 0.446],
      [0.404, 0.461, 0.466],
      [0.498, 0.527, 0.469],
      [0.598, 0.594, 0.457],
      [0.703, 0.665, 0.428],
      [0.811, 0.738, 0.385],
      [0.992, 0.906, 0.144],
    ]);

List<double> _turbo(double t) => _interp(t, const [
      [0.190, 0.072, 0.232],
      [0.276, 0.392, 0.875],
      [0.262, 0.642, 0.946],
      [0.236, 0.842, 0.776],
      [0.366, 0.949, 0.470],
      [0.621, 0.989, 0.225],
      [0.841, 0.937, 0.205],
      [0.971, 0.768, 0.255],
      [0.984, 0.555, 0.187],
      [0.881, 0.336, 0.100],
      [0.706, 0.016, 0.151],
    ]);

List<double> _interp(double t, List<List<double>> stops) {
  if (t <= 0) return stops.first;
  if (t >= 1) return stops.last;
  final scaled = t * (stops.length - 1);
  final i = scaled.floor();
  final frac = scaled - i;
  final a = stops[i];
  final b = stops[i + 1];
  return [
    a[0] + (b[0] - a[0]) * frac,
    a[1] + (b[1] - a[1]) * frac,
    a[2] + (b[2] - a[2]) * frac,
  ];
}
