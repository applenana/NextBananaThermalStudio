import 'dart:async';
import 'dart:typed_data';
import 'package:banana_thermal/ui/widgets/rgb_image_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('12.5 Hz source paints interleaved midpoints', (tester) async {
    final source = ValueNotifier(Uint8List(120 * 90 * 3));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<Uint8List>(
          valueListenable: source,
          builder: (_, rgb, child) =>
              RgbImageView(rgb: rgb, width: 120, height: 90, interpolate: true),
        ),
      ),
    );
    final timer = Timer.periodic(const Duration(milliseconds: 80), (t) {
      final rgb = Uint8List(120 * 90 * 3);
      for (var i = 0; i < 120 * 90; i++) {
        final value = (i % 120 + t.tick * 2) % 120;
        rgb.fillRange(3 * i, 3 * i + 3, value);
      }
      source.value = rgb;
    });
    try {
      await Future<void>.delayed(const Duration(seconds: 4));
      final text = tester.widget<Text>(find.textContaining(' FPS')).data!;
      final fps = double.parse(RegExp(r'[0-9.]+').firstMatch(text)![0]!);
      debugPrint('12.5 Hz synthetic input: $text');
      expect(fps, greaterThan(17));
      expect(fps, lessThan(28));
    } finally {
      timer.cancel();
      await tester.pumpWidget(const SizedBox());
      source.dispose();
    }
  });
}
