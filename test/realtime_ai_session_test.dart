import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/realtime_ai_session.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';
import 'package:banana_thermal/render/photo_ai_progress.dart';

PhotoRenderInput input(
  double offset, {
  RenderParams? params,
}) => PhotoRenderInput(
  temperatures: Float32List.fromList(List.generate(15, (i) => 20 + offset + i)),
  width: 5,
  height: 3,
  params:
      params ?? const RenderParams(upsampleScale: 2, bilateralEnabled: false),
);

void main() {
  test(
    'continuous frames start immediately and only the latest pending runs',
    () async {
      final jobs = <Completer<RenderedFrame>>[];
      final inputs = <PhotoRenderInput>[];
      final callbacks = <PhotoAiProgressCallback>[];
      final ai = RealtimeAiSession(
        infer: (frame, progress) {
          inputs.add(frame);
          callbacks.add(progress);
          final job = Completer<RenderedFrame>();
          jobs.add(job);
          return job.future;
        },
      );
      addTearDown(ai.dispose);
      final first = input(0), middle = input(1), latest = input(2);
      ai.submit(first);
      expect(jobs, isEmpty);
      ai.setEnabled(true);
      ai.submit(first);
      ai.submit(middle);
      ai.submit(latest);
      expect(inputs, [first]);
      callbacks[0](const PhotoAiProgress('blocks', completed: 1, total: 5));
      expect(ai.progress!.fraction, .2);
      final enhanced = applyAiDisplay(
        first.render(scale: 3),
        Float32List.fromList(List.filled(135, .25)),
        first.params,
      );
      jobs[0].complete(enhanced);
      await Future<void>.delayed(Duration.zero);
      expect(inputs, [first, latest]);
      // AI RGB is resized without moving measurement/recorder coordinates.
      final measured = latest.render();
      final display = ai.display(measured);
      expect((display.width, display.height), (10, 6));
      expect(display.rgb.length, 180);
      expect(display.rgb, isNot(measured.rgb));
      expect(
        identical(display.temperatureField, measured.temperatureField),
        isTrue,
      );
      expect(
        identical(display.normalizedField, measured.normalizedField),
        isTrue,
      );
      expect(
        identical(display.thermalColorScaleRgb, measured.thermalColorScaleRgb),
        isTrue,
      );
      expect((display.tMin, display.tMax), (measured.tMin, measured.tMax));
      jobs[1].complete(latest.render(scale: 3));
      await Future<void>.delayed(Duration.zero);
      expect(ai.busy, isFalse);
      ai.submit(latest);
      expect(jobs.length, 2);
    },
  );

  test(
    'disable, reconnect and render settings discard obsolete jobs',
    () async {
      final jobs = <Completer<RenderedFrame>>[];
      final callbacks = <PhotoAiProgressCallback>[];
      final ai = RealtimeAiSession(
        infer: (_, progress) {
          callbacks.add(progress);
          final job = Completer<RenderedFrame>();
          jobs.add(job);
          return job.future;
        },
      );
      addTearDown(ai.dispose);
      final first = input(0), next = input(20);
      ai.setEnabled(true);
      ai.submit(first);
      ai.setEnabled(false);
      ai.setEnabled(true);
      ai.submit(next);
      callbacks[0](const PhotoAiProgress('blocks', completed: 5, total: 5));
      expect(ai.progress, isNull);
      jobs[0].complete(first.render(scale: 3));
      await Future<void>.delayed(Duration.zero);
      final measured = next.render();
      expect(identical(ai.display(measured), measured), isTrue);
      expect(jobs.length, 2);
      final changed = input(
        30,
        params: next.params.copyWith(colormapName: 'plasma'),
      );
      ai.submit(changed);
      jobs[1].complete(next.render(scale: 3));
      await Future<void>.delayed(Duration.zero);
      expect(identical(ai.display(measured), measured), isTrue);
      expect(jobs.length, 3);
      ai.clear(); // Stopped stream must not retain its last image.
      jobs[2].complete(changed.render(scale: 3));
      await Future<void>.delayed(Duration.zero);
      expect(identical(ai.display(measured), measured), isTrue);
    },
  );

  test(
    'failure restores ordinary display and does not retry every sensor frame',
    () async {
      var calls = 0;
      final ai = RealtimeAiSession(
        infer: (_, _) async {
          calls++;
          throw StateError('runtime failed');
        },
      );
      addTearDown(ai.dispose);
      ai.setEnabled(true);
      ai.submit(input(0));
      await Future<void>.delayed(Duration.zero);
      expect(ai.error, contains('runtime failed'));
      ai.submit(input(1));
      expect(calls, 1);
      final measured = input(2).render();
      expect(identical(ai.display(measured), measured), isTrue);
      ai.setEnabled(false);
      ai.setEnabled(true);
      ai.submit(input(3));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
    },
  );

  test('dispose safely ignores late completion', () async {
    final job = Completer<RenderedFrame>();
    final ai = RealtimeAiSession(infer: (_, _) => job.future);
    final frame = input(0);
    ai.setEnabled(true);
    ai.submit(frame);
    ai.dispose();
    job.complete(frame.render(scale: 3));
    await Future<void>.delayed(Duration.zero);
  });
}
