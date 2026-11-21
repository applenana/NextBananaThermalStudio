import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:banana_thermal/render/frame_interpolation.dart';
import 'package:banana_thermal/ui/widgets/rgb_image_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart' show BoxFit;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a scene cut bypasses synthesis', () {
    final rgb = Uint8List(64 * 48 * 3);
    final black = MotionSample.fromRgb(rgb, 64, 48);
    rgb.fillRange(0, rgb.length, 255);
    expect(
      MidpointFlow.estimate(black, MotionSample.fromRgb(rgb, 64, 48)),
      isNull,
    );
  });

  test('painted midpoint follows translation and blends exposure', () async {
    const w = 64, h = 48;
    final random = Random(713);
    final pattern = List.generate(w * h, (_) => random.nextInt(170) + 20);
    Uint8List frame(int shift, int bias) => Uint8List.fromList([
      for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
          for (int c = 0; c < 3; c++)
            pattern[y * w + (x - shift).clamp(0, w - 1)] + bias,
    ]);
    Future<ui.Image> texture(Uint8List rgb) {
      final bytes = Uint8List(w * h * 4);
      for (int k = 0; k < w * h; k++) {
        bytes.setRange(4 * k, 4 * k + 3, rgb, k * 3);
        bytes[4 * k + 3] = 255;
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bytes,
        w,
        h,
        ui.PixelFormat.rgba8888,
        done.complete,
      );
      return done.future;
    }

    final a = frame(0, 0), b = frame(4, 10);
    final flow = MidpointFlow.estimate(
      MotionSample.fromRgb(a, w, h),
      MotionSample.fromRgb(b, w, h),
    )!;
    final left = await texture(a), right = await texture(b);
    final rec = ui.PictureRecorder();
    RgbFramePainter(
      image: right,
      previous: left,
      flow: flow,
      fit: BoxFit.fill,
      filterQuality: ui.FilterQuality.none,
    ).paint(ui.Canvas(rec), const ui.Size(64, 48));
    final picture = rec.endRecording();
    final out = await picture.toImage(w, h);
    final data = (await out.toByteData())!;
    var absolute = 0;
    for (int y = 8; y < 40; y++) {
      for (int x = 8; x < 56; x++) {
        absolute +=
            (data.getUint8(4 * (y * w + x)) - (pattern[y * w + x - 2] + 5))
                .abs();
      }
    }
    out.dispose();
    picture.dispose();
    left.dispose();
    right.dispose();
    expect(absolute / (32 * 48), lessThan(1.5));
  });
}
