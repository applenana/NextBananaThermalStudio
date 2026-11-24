import 'dart:math' as math;
import 'dart:typed_data';

/// Appearance is sampled on a bounded grid; output images keep their full size.
class MotionSample {
  static const width = 64, height = 48;
  final Uint8List luma;
  MotionSample.fromRgb(Uint8List rgb, int w, int h)
    : luma = Uint8List(width * height) {
    for (int y = 0; y < height; y++) {
      final row = ((2 * y + 1) * h ~/ (2 * height)) * w;
      for (int x = 0; x < width; x++) {
        final i = 3 * (row + (2 * x + 1) * w ~/ (2 * width));
        luma[y * width + x] =
            (77 * rgb[i] + 150 * rgb[i + 1] + 29 * rgb[i + 2]) >> 8;
      }
    }
  }
}

/// Midpoint sampling offsets, in thumbnail pixels, on a regular warp mesh.
class MidpointFlow {
  static const cols = 7, rows = 5;
  final Int8List dx = Int8List(cols * rows), dy = Int8List(cols * rows);

  static MidpointFlow? estimate(MotionSample before, MotionSample after) {
    const w = MotionSample.width, h = MotionSample.height;
    final a = before.luma, b = after.luma;
    final flow = MidpointFlow();
    var residual = 0;
    // Weights fitted by tools/frame_interpolation/train_matcher.py.
    for (int j = 0; j < rows; j++) {
      final y = (j * (h - 1) ~/ (rows - 1)).clamp(4, h - 5);
      for (int i = 0; i < cols; i++) {
        final x = (i * (w - 1) ~/ (cols - 1)).clamp(4, w - 5);
        var best = -double.infinity, bestError = 0;
        for (int v = -2; v <= 2; v++) {
          for (int u = -2; u <= 2; u++) {
            final d = v * w + u;
            var absolute = 0, clipped = 0, signed = 0;
            for (int py = -2; py <= 2; py++) {
              int k = (y + py) * w + x - 2;
              for (int px = 0; px < 5; px++, k++) {
                final diff = a[k - d] - b[k + d], mag = diff.abs();
                absolute += mag;
                clipped += math.min(20, mag);
                signed += diff;
              }
            }
            final score =
                (-45.83737 * absolute -
                        176.38783 * clipped +
                        23.815 * signed.abs()) /
                    (25 * 255) -
                1.120015 * (u * u + v * v) / 8;
            if (score > best) {
              best = score;
              bestError = absolute;
              flow.dx[j * cols + i] = u;
              flow.dy[j * cols + i] = v;
            }
          }
        }
        residual += bestError;
      }
    }
    return residual > cols * rows * 25 * 32 ? null : flow;
  }
}
