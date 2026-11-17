// Non-UI end-to-end model comparison on the user's last downloaded photo.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/photo_ai_model.dart';
import 'package:banana_thermal/render/photo_ai_runtime.dart';
import 'package:banana_thermal/render/photo_ai_progress.dart';
import 'package:banana_thermal/render/render_params.dart';

void main() {
  test(
    'all thermal models restore the last photo without changing measurements',
    () async {
      final sourcePath = Platform.environment['THERMAL_SR_SAMPLE']!;
      final values = (await File(sourcePath).readAsLines())
          .skip(1)
          .where((s) => s.isNotEmpty)
          .map((s) => double.parse(s.split(',')[2]))
          .toList();
      final source = Float32List.fromList(values);
      final input = PhotoRenderInput(
        temperatures: source,
        width: 120,
        height: 90,
        params: const RenderParams(upsampleScale: 2, colormapName: 'plasma'),
      );
      final dir = await Directory(
        Platform.environment['THERMAL_AI_RESULTS'] ??
            'build/thermal-ai-comparison',
      ).create(recursive: true);
      final models = PhotoAiModel.values;
      final canvas = img.Image(width: 960, height: models.length * 390);
      final records = <Map<String, Object>>[];
      addTearDown(() => PhotoAiRuntime.shared.close());
      for (final model in models) {
        expect(PhotoAiRuntime.available(model), isTrue, reason: model.id);
        final scale = model.scales.first;
        final measured = input.render(scale: scale);
        final events = <PhotoAiProgress>[];
        final clock = Stopwatch()..start();
        final result = await input
            .withAiScale(scale, model: model)
            .enhanceAsync(onProgress: events.add);
        clock.stop();
        final expectedDevice = Platform.environment['THERMAL_AI_EXPECT_DEVICE'];
        if (model.external && expectedDevice != null) {
          expect(events.last.device, expectedDevice);
          expect(events.every((e) => e.fallback == null), isTrue);
          final counts = events.where((e) => e.completed != null).toList();
          expect(counts, isNotEmpty);
          expect(counts.first.completed, 0);
          expect(counts.last.completed, counts.last.total);
          for (var i = 1; i < counts.length; i++) {
            expect(counts[i].completed, counts[i - 1].completed! + 1);
          }
        }
        final warmClock = Stopwatch()..start();
        final repeated = await input
            .withAiScale(scale, model: model)
            .enhanceAsync();
        warmClock.stop();
        expect(repeated.rgb, result.rgb);
        expect((result.width, result.height), (120 * scale, 90 * scale));
        expect(result.temperatureField, measured.temperatureField);
        expect(result.normalizedField, measured.normalizedField);
        expect(result.thermalColorScaleRgb, measured.thermalColorScaleRgb);
        expect((result.tMin, result.tMax), (measured.tMin, measured.tMax));
        expect(source, Float32List.fromList(values));
        final regular = img.Image.fromBytes(
          width: measured.width,
          height: measured.height,
          bytes: measured.rgb.buffer,
          numChannels: 3,
        );
        final enhanced = img.Image.fromBytes(
          width: result.width,
          height: result.height,
          bytes: result.rgb.buffer,
          numChannels: 3,
        );
        double? cpuRgbMeanError;
        final baselineDir = Platform.environment['THERMAL_AI_BASELINE'];
        if (baselineDir != null) {
          final baseline = img.decodePng(
            await File('$baselineDir/${model.id}.png').readAsBytes(),
          )!;
          expect(
            (baseline.width, baseline.height),
            (result.width, result.height),
          );
          final rgb = baseline.getBytes(order: img.ChannelOrder.rgb);
          var difference = 0;
          for (var i = 0; i < rgb.length; i++) {
            difference += (rgb[i] - result.rgb[i]).abs();
          }
          cpuRgbMeanError = difference / rgb.length;
          expect(
            cpuRgbMeanError,
            lessThan(1),
            reason: 'CUDA should preserve FP32 display output',
          );
        }
        await File(
          '${dir.path}/${model.id}.png',
        ).writeAsBytes(img.encodePng(enhanced));
        await File(
          '${dir.path}/regular${scale}x.png',
        ).writeAsBytes(img.encodePng(regular));
        final y = models.indexOf(model) * 390;
        img.drawString(
          canvas,
          'Regular ${scale}x',
          font: img.arial14,
          x: 8,
          y: y + 7,
        );
        img.drawString(
          canvas,
          '${model.id} ${scale}x - ${clock.elapsedMilliseconds} ms',
          font: img.arial14,
          x: 488,
          y: y + 7,
        );
        img.compositeImage(
          canvas,
          img.copyResize(regular, width: 480, height: 360),
          dstY: y + 30,
        );
        img.compositeImage(
          canvas,
          img.copyResize(enhanced, width: 480, height: 360),
          dstX: 480,
          dstY: y + 30,
        );
        records.add({
          'model': model.id,
          'scale': scale,
          'pipelineMs': clock.elapsedMilliseconds,
          'warmPipelineMs': warmClock.elapsedMilliseconds,
          'device': events.last.device ?? 'unknown',
          'progressEvents': events.length,
          'cpuRgbMeanAbsoluteError': ?cpuRgbMeanError,
          'temperatureUnchanged': true,
        });
        // Persist progress even if another model fails later.
        await File('${dir.path}/results.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'source': sourcePath,
            'device': expectedDevice ?? 'auto',
            'results': records,
          }),
        );
        // ignore: avoid_print
        print(
          '${model.id}: ${clock.elapsedMilliseconds} ms, warm ${warmClock.elapsedMilliseconds} ms, ${events.last.device}',
        );
      }
      await File(
        '${dir.path}/comparison.png',
      ).writeAsBytes(img.encodePng(canvas));
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
