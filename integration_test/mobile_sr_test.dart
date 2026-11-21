import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/mobile_ai_backend.dart';
import 'package:banana_thermal/render/photo_ai_session.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'mobile photo export uses the selected backend and preserves temperatures',
    (_) async {
      final frame = PhotoRenderInput(
        temperatures: Float32List.fromList(
          List.generate(120 * 90, (i) => 18.0 + (i % 120) / 10),
        ),
        width: 120,
        height: 90,
        params: const RenderParams(bilateralEnabled: false),
      );
      final normal = frame.render(scale: 3);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(MobileAiSettings.key);
      final session = PhotoAiSession()..setScale(3);
      try {
        for (final backend in MobileAiBackend.values) {
          await MobileAiSettings.select(backend);
          await prefs.reload();
          MobileAiSettings.load(prefs);
          expect(MobileAiSettings.preferred.value, backend);
          String? device, fallback;
          void observe() {
            final progress = session.progress;
            if (progress?.stage == 'complete') {
              device = progress!.device;
              fallback = progress.fallback;
            }
          }

          session.addListener(observe);
          final output = await session.export(frame);
          session.removeListener(observe);
          expect([output.width, output.height], [360, 270]);
          expect(output.temperatureField, normal.temperatureField);
          expect(output.rgb.toSet().length, greaterThan(8));
          expect(device, fallback == null ? backend.name : 'cpu');
          // Printed by the device runner so fallback is visible for each phone.
          debugPrint(
            'mobile SR: ${backend.name} -> $device, 360x270, fallback: $fallback',
          );
        }
      } finally {
        session.dispose();
        if (saved == null) {
          await prefs.remove(MobileAiSettings.key);
        } else {
          await prefs.setString(MobileAiSettings.key, saved);
        }
        MobileAiSettings.load(prefs);
      }
    },
    skip: !MobileAiSettings.supported,
  );
}
