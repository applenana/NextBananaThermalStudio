// Non-UI smoke test using an existing x,y,temperature_c CSV. Output is ignored.
// THERMAL_SR_SAMPLE=<csv> THERMAL_SR_LIBRARY=<dll> flutter test tools/check_ai_photo.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/render_params.dart';

void main() {
  test(
    'real photo AI pipeline preserves temperature and exports comparison',
    () async {
      final path = Platform.environment['THERMAL_SR_SAMPLE'];
      if (path == null) throw ArgumentError('Set THERMAL_SR_SAMPLE');
      final values = (await File(path).readAsLines())
          .skip(1)
          .where((line) => line.isNotEmpty)
          .map((line) => double.parse(line.split(',')[2]))
          .toList();
      expect(values.length, 10800);
      final source = Float32List.fromList(values);
      final input = PhotoRenderInput(
        temperatures: source,
        width: 120,
        height: 90,
        params: const RenderParams(upsampleScale: 2, colormapName: 'plasma'),
      );
      final dir = await Directory(
        'build/ai-photo-check',
      ).create(recursive: true);
      final records = <Map<String, Object>>[];
      final comparison = img.Image(width: 960, height: 3 * 390);
      for (final scale in photoAiScales) {
        final before = input.render(scale: scale);
        final clock = Stopwatch()..start();
        final after = input.withAiScale(scale).enhance();
        clock.stop();
        expect(after.temperatureField, before.temperatureField);
        expect(after.normalizedField, before.normalizedField);
        expect(after.thermalColorScaleRgb, before.thermalColorScaleRgb);
        expect((after.tMin, after.tMax), (before.tMin, before.tMax));
        expect(source, Float32List.fromList(values));
        expect((after.width, after.height), (120 * scale, 90 * scale));
        expect(after.rgb, isNot(before.rgb));
        final original = img.Image.fromBytes(
          width: before.width,
          height: before.height,
          bytes: before.rgb.buffer,
          numChannels: 3,
        );
        final enhanced = img.Image.fromBytes(
          width: after.width,
          height: after.height,
          bytes: after.rgb.buffer,
          numChannels: 3,
        );
        await File(
          '${dir.path}/regular${scale}x.png',
        ).writeAsBytes(img.encodePng(original));
        await File(
          '${dir.path}/ai${scale}x.png',
        ).writeAsBytes(img.encodePng(enhanced));
        final rowY = photoAiScales.indexOf(scale) * 390;
        img.compositeImage(
          comparison,
          img.copyResize(original, width: 480, height: 360),
          dstY: rowY + 30,
        );
        img.compositeImage(
          comparison,
          img.copyResize(enhanced, width: 480, height: 360),
          dstX: 480,
          dstY: rowY + 30,
        );
        img.drawString(
          comparison,
          'Regular ${scale}x',
          font: img.arial14,
          x: 8,
          y: rowY + 7,
        );
        img.drawString(
          comparison,
          'ESPCN ${scale}x (${scale == 2 ? "native" : "cascade"})',
          font: img.arial14,
          x: 488,
          y: rowY + 7,
        );
        records.add({
          'scale': scale,
          'width': after.width,
          'height': after.height,
          'pipelineMs': clock.elapsedMilliseconds,
          'temperatureUnchanged': true,
        });
      }
      await File(
        '${dir.path}/comparison.png',
      ).writeAsBytes(img.encodePng(comparison));
      await File('${dir.path}/result.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'source': path,
          'sourceWidth': 120,
          'sourceHeight': 90,
          'model': 'ESPCN x2 ordinary-image training; x4/x8 cascaded',
          'results': records,
        }),
      );
    },
  );
}
