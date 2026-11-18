// Real inference and native-resolution handoff check; no Flutter UI testing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/photo_ai_runtime.dart';
import 'package:banana_thermal/render/realtime_ai_session.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';

void main() {
  test(
    'real PFT live output reaches display at native 3x',
    () async {
      final path = Platform.environment['THERMAL_SR_SAMPLE']!;
      final values = (await File(path).readAsLines())
          .skip(1)
          .where((line) => line.isNotEmpty)
          .map((line) => double.parse(line.split(',')[2]))
          .toList();
      final input = PhotoRenderInput(
        temperatures: Float32List.fromList(values),
        width: 120,
        height: 90,
        params: const RenderParams(
          upsampleScale: 2,
          colormapName: 'plasma',
          bilateralEnabled: false,
        ),
      );
      final session = RealtimeAiSession();
      addTearDown(session.dispose);
      addTearDown(() => PhotoAiRuntime.shared.close());
      final completed = Completer<RenderedFrame>();
      session.addListener(() {
        if (completed.isCompleted) return;
      if (session.error != null) {
          completed.completeError(StateError(session.error!));
      }
      if (session.enhancedFrame != null) {
          completed.complete(session.enhancedFrame!);
      }
      });
      session.setEnabled(true);
      session.submit(input);
      final enhanced = await completed.future;
      final ordinary = input.render();
      final ordinary3x = input.render(scale: 3);
      expect((enhanced.width, enhanced.height), (360, 270));
      expect(identical(session.enhancedFrame, enhanced), isTrue);
      expect(enhanced.temperatureField, ordinary3x.temperatureField);
      expect(enhanced.normalizedField, ordinary3x.normalizedField);
      expect(enhanced.thermalColorScaleRgb, ordinary3x.thermalColorScaleRgb);
      var changed = 0, totalError = 0;
      for (var i = 0; i < enhanced.rgb.length; i++) {
        final difference = (enhanced.rgb[i] - ordinary3x.rgb[i]).abs();
        totalError += difference;
        if (difference != 0) changed++;
      }
      expect(changed, greaterThan(0), reason: 'Must not return ordinary RGB');
      final expectedDevice = Platform.environment['THERMAL_AI_EXPECT_DEVICE'];
    if (expectedDevice != null) {
        expect(session.progress?.device, expectedDevice);
    }
      img.Image image(RenderedFrame frame) => img.Image.fromBytes(
        width: frame.width,
        height: frame.height,
        bytes: frame.rgb.buffer,
        bytesOffset: frame.rgb.offsetInBytes,
        numChannels: 3,
      );
      final directory = await Directory(
        Platform.environment['THERMAL_AI_RESULTS'] ??
            'build/live-ai-display-check',
      ).create(recursive: true);
      final comparison = img.Image(width: 1440, height: 574);
      img.drawString(
        comparison,
        'Ordinary 2x / nearest screen scaling',
        font: img.arial14,
        x: 12,
        y: 10,
      );
      img.drawString(
        comparison,
        'PFT TV native 3x / linear screen scaling',
        font: img.arial14,
        x: 732,
        y: 10,
      );
      img.compositeImage(
        comparison,
        img.copyResize(
          image(ordinary),
          width: 720,
          height: 540,
          interpolation: img.Interpolation.nearest,
        ),
        dstY: 34,
      );
      img.compositeImage(
        comparison,
        img.copyResize(
          image(enhanced),
          width: 720,
          height: 540,
          interpolation: img.Interpolation.linear,
        ),
        dstX: 720,
        dstY: 34,
      );
      await File(
        '${directory.path}/comparison.png',
      ).writeAsBytes(img.encodePng(comparison));
      // Same-size comparison isolates model changes from display filtering.
      await File(
        '${directory.path}/ordinary3x.png',
      ).writeAsBytes(img.encodePng(image(ordinary3x)));
      await File(
        '${directory.path}/pft3x.png',
      ).writeAsBytes(img.encodePng(image(enhanced)));
      await File('${directory.path}/results.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'source': path,
          'device': session.progress?.device,
          'pipelineMs': session.elapsedMs,
          'width': enhanced.width,
          'height': enhanced.height,
          'changedChannelFraction': changed / enhanced.rgb.length,
          'meanAbsoluteRgbDifferenceVsOrdinary3x':
              totalError / enhanced.rgb.length,
          'temperatureUnchanged': true,
        }),
      );
      session.setEnabled(false);
      expect(session.enhancedFrame, isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
