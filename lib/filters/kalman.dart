/// 一维 / 二维卡尔曼滤波 (与 thermal_dual_app.py 中 KalmanFilter
/// 和 ThermalKalmanFilter 等价).
library;

import 'dart:typed_data';

class KalmanFilter1D {
  final double q;
  final double r;
  double _x = 0.0;
  double _p = 1.0;
  bool _init = false;

  KalmanFilter1D({this.q = 1e-4, this.r = 1e-2});

  double update(double z) {
    if (!_init) {
      _x = z;
      _init = true;
      return z;
    }
    final pPred = _p + q;
    final k = pPred / (pPred + r);
    _x = _x + k * (z - _x);
    _p = (1.0 - k) * pPred;
    return _x;
  }

  void reset() {
    _init = false;
    _x = 0.0;
    _p = 1.0;
  }
}

/// 像素级卡尔曼: 对 H*W 的浮点帧逐点平滑.
class KalmanFilter2D {
  final int h;
  final int w;
  final double q;
  final double r;

  Float32List? _x;
  late Float32List _p;

  KalmanFilter2D({
    this.h = 24,
    this.w = 32,
    this.q = 1e-4,
    this.r = 1e-2,
  }) {
    _p = Float32List(h * w)..fillRange(0, h * w, 1.0);
  }

  Float32List filter(Float32List frame) {
    assert(frame.length == h * w, 'frame size mismatch');
    if (_x == null) {
      _x = Float32List.fromList(frame);
      return Float32List.fromList(_x!);
    }
    final x = _x!;
    for (int i = 0; i < frame.length; i++) {
      final pPred = _p[i] + q;
      final k = pPred / (pPred + r);
      x[i] = x[i] + k * (frame[i] - x[i]);
      _p[i] = (1.0 - k) * pPred;
    }
    return Float32List.fromList(x);
  }

  void reset() {
    _x = null;
    _p = Float32List(h * w)..fillRange(0, h * w, 1.0);
  }
}
