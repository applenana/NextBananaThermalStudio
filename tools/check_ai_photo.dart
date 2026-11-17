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
      final before = input.render();
      final clock = Stopwatch()..start();
      final after = input.enhance();
      clock.stop();
      expect(after.temperatureField, before.temperatureField);
      expect(source, Float32List.fromList(values));
      expect((after.width, after.height), (240, 180));
      expect(after.rgb, isNot(before.rgb));
      final original = img.Image.fromBytes(
        width: 240,
        height: 180,
        bytes: before.rgb.buffer,
        numChannels: 3,
      );
      final enhanced = img.Image.fromBytes(
        width: 240,
        height: 180,
        bytes: after.rgb.buffer,
        numChannels: 3,
      );
      final comparison = img.Image(width: 480, height: 206);
      img.compositeImage(comparison, original, dstX: 0, dstY: 26);
      img.compositeImage(comparison, enhanced, dstX: 240, dstY: 26);
      img.drawString(comparison, 'Regular 2x', font: img.arial14, x: 8, y: 5);
      img.drawString(
        comparison,
        'ESPCN AI 2x',
        font: img.arial14,
        x: 248,
        y: 5,
      );
      final dir = await Directory(
        'build/ai-photo-check',
      ).create(recursive: true);
      await File(
        '${dir.path}/comparison.png',
      ).writeAsBytes(img.encodePng(comparison));
      await File('${dir.path}/ai2x.png').writeAsBytes(img.encodePng(enhanced));
      await File('${dir.path}/result.json').writeAsString(
        jsonEncode({
          'sourceWidth': 120,
          'sourceHeight': 90,
          'width': 240,
          'height': 180,
          'pipelineMs': clock.elapsedMilliseconds,
          'temperatureUnchanged': true,
        }),
      );
    },
  );
}
