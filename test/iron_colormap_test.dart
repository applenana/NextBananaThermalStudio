import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/fusion/colormap.dart';
import 'package:banana_thermal/fusion/fusion.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';

void main() {
  test('firmware iron endpoints use the entire palette range', () {
    expect(kBuiltinColormaps, contains(kDefaultPhotoColormap));
    final lut = getColormapLut('iron');
    expect(lut.length, 768);
    expect(lut.sublist(0, 3), [12, 9, 24]);
    expect(lut.sublist(765), [255, 255, 238]);
    final rgb = colorize(
      normalized: Float32List.fromList([0, 1]),
      width: 2,
      height: 1,
      colormapName: 'iron',
    );
    expect(rgb, [12, 9, 24, 255, 255, 238]);
    // Existing palettes keep their endpoint compression.
    final gray = colorize(
      normalized: Float32List.fromList([0, 1]),
      width: 2,
      height: 1,
      colormapName: 'gray',
    );
    expect(gray, [13, 13, 13, 242, 242, 242]);
  });

  test(
    'iron changes display and legend together without changing temperatures',
    () {
      final source = Float32List.fromList([10, 20, 30, 40]);
      RenderedFrame render(String palette) => renderPipeline(
        thermalFrame: source,
        srcW: 2,
        srcH: 2,
        params: RenderParams(
          colormapName: palette,
          bilateralEnabled: false,
          upsampleScale: 2,
        ),
      );
      final ordinary = render('plasma');
      final iron = render(kDefaultPhotoColormap);
      expect(iron.temperatureField, ordinary.temperatureField);
      expect(iron.normalizedField, ordinary.normalizedField);
      expect((iron.tMin, iron.tMax), (ordinary.tMin, ordinary.tMax));
      expect(iron.rgb, isNot(ordinary.rgb));
      expect(iron.thermalColorScaleRgb.sublist(0, 3), [12, 9, 24]);
      expect(
        iron.thermalColorScaleRgb.sublist(iron.thermalColorScaleRgb.length - 3),
        [255, 255, 238],
      );
    },
  );
}
