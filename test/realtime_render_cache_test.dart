import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/realtime_render_cache.dart';
import 'package:banana_thermal/render/render_params.dart';

void main() {
  test(
    'progress rebuilds reuse rendering; frames, settings and fusion invalidate',
    () {
      final cache = RealtimeRenderCache();
      var temperatures = Float32List.fromList([10, 20, 30, 40]);
      var params = const RenderParams(
        upsampleScale: 2,
        bilateralEnabled: false,
      );
      Uint8List? visible;
      PhotoRenderInput input() => PhotoRenderInput(
        temperatures: temperatures,
        width: 2,
        height: 2,
        params: params,
        visibleRgb: visible,
        visibleW: visible == null ? 0 : 2,
        visibleH: visible == null ? 0 : 2,
      );
      final first = cache.render(input());
      expect(identical(cache.render(input()), first), isTrue);
      temperatures = Float32List.fromList([11, 21, 31, 41]);
      final next = cache.render(input());
      expect(identical(next, first), isFalse);
      expect(next.temperatureField, input().render().temperatureField);
      params = params.copyWith(colormapName: 'iron');
      final colored = cache.render(input());
      expect(colored.rgb, isNot(next.rgb));
      visible = Uint8List(12);
      final fusion = cache.render(input());
      expect(identical(fusion, colored), isFalse);
      cache.clear();
      expect(identical(cache.render(input()), fusion), isFalse);
    },
  );
}
