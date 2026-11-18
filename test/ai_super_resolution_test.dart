import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/photo_ai_session.dart';
import 'package:banana_thermal/render/photo_ai_model.dart';
import 'package:banana_thermal/render/photo_ai_progress.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';

PhotoRenderInput input(double offset) => PhotoRenderInput(
  temperatures: Float32List.fromList(List.generate(15, (i) => 20 + offset + i)),
  width: 5,
  height: 3,
  params: const RenderParams(upsampleScale: 2, bilateralEnabled: false),
);

void main() {
  test('progress validates counts and distinguishes unknown stages', () {
    expect(
      PhotoAiProgress.fromJson({
        'stage': 'tiles',
        'completed': 2,
        'total': 4,
        'device': 'cuda',
      }).fraction,
      0.5,
    );
    expect(const PhotoAiProgress('loading').fraction, isNull);
    for (final counts in [(-1, 4), (5, 4), (0, 0)]) {
      expect(
        () => PhotoAiProgress.fromJson({
          'stage': 'tiles',
          'completed': counts.$1,
          'total': counts.$2,
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'stale preview progress is ignored and export progress clears on failure',
    () async {
      final callbacks = <PhotoAiProgressCallback>[];
      final jobs = <Completer<RenderedFrame>>[];
      final ai = PhotoAiSession(
        inferProgress: (_, callback) {
          callbacks.add(callback);
          final job = Completer<RenderedFrame>();
          jobs.add(job);
          return job.future;
        },
      );
      final photo = input(0);
      ai.setModel(PhotoAiModel.pftL1);
      ai.preview(photo);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      callbacks[0](
        const PhotoAiProgress('blocks', completed: 1, total: 5, device: 'cuda'),
      );
      expect(ai.progress!.fraction, 0.2);
      ai.setModel(PhotoAiModel.pftTv);
      ai.preview(photo);
      callbacks[0](const PhotoAiProgress('blocks', completed: 5, total: 5));
      expect(ai.progress!.stage, 'queued');
      jobs[0].complete(photo.render(scale: 3));
      await Future<void>.delayed(Duration.zero);
      callbacks[1](const PhotoAiProgress('blocks', completed: 2, total: 5));
      final export = ai.export(photo, model: PhotoAiModel.pftTv, scale: 3);
      final failure = expectLater(export, throwsStateError);
      callbacks[2](const PhotoAiProgress('loading', device: 'cuda'));
      callbacks[1](const PhotoAiProgress('blocks', completed: 3, total: 5));
      expect(ai.progress!.stage, 'loading');
      jobs[2].completeError(StateError('test failure'));
      await failure;
      expect(ai.progress!.fraction, 0.6);
      jobs[1].complete(photo.render(scale: 3));
      await Future<void>.delayed(Duration.zero);
      expect(ai.processing, isFalse);
      ai.dispose();
      callbacks[1](const PhotoAiProgress('complete'));
    },
  );

  test(
    'model switches invalidate same-scale results and exports capture the model',
    () async {
      final jobs = <Completer<RenderedFrame>>[];
      final selected = <PhotoAiModel>[];
      final ai = PhotoAiSession(
        infer: (input) {
          selected.add(input.aiModel);
          final job = Completer<RenderedFrame>();
          jobs.add(job);
          return job.future;
        },
      );
      final photo = input(0);
      ai.setModel(PhotoAiModel.pftL1);
      expect(ai.scale, 3);
      expect(() => ai.setScale(4), throwsArgumentError);
      expect(ai.preview(photo).width, 15);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      ai.setModel(PhotoAiModel.pftTv);
      ai.preview(photo);
      final stale = photo.render(scale: 3);
      jobs[0].complete(stale);
      await Future<void>.delayed(Duration.zero);
      expect(selected, [PhotoAiModel.pftL1, PhotoAiModel.pftTv]);
      expect(identical(ai.preview(photo), stale), isFalse);
      final current = photo.render(scale: 3);
      jobs[1].complete(current);
      await Future<void>.delayed(Duration.zero);
      expect(identical(ai.preview(photo), current), isTrue);
      final exporting = ai.export(photo, scale: 3, model: PhotoAiModel.pftL1);
      ai.setModel(PhotoAiModel.pftTv);
      expect(ai.scale, 3);
      expect(selected.last, PhotoAiModel.pftL1);
      jobs[2].complete(photo.render(scale: 3));
      expect((await exporting).width, 15);
      ai.dispose();
    },
  );

  test('AI display keeps all original measurement fields and bounds', () {
    final original = input(0).render();
    final enhanced = applyAiDisplay(
      original,
      Float32List.fromList(List.filled(60, 0.25)),
      const RenderParams(),
    );
    expect(
      identical(enhanced.temperatureField, original.temperatureField),
      isTrue,
    );
    expect(
      identical(enhanced.normalizedField, original.normalizedField),
      isTrue,
    );
    expect(
      identical(enhanced.thermalColorScaleRgb, original.thermalColorScaleRgb),
      isTrue,
    );
    expect(enhanced.tMin, original.tMin);
    expect(enhanced.tMax, original.tMax);
    expect(enhanced.rgb, isNot(original.rgb));
    expect(
      () => applyAiDisplay(original, Float32List(1), const RenderParams()),
      throwsFormatException,
    );
  });

  test('Thermal-PFT supports native 3x only and enforces output bounds', () {
    expect(PhotoAiModel.values, [PhotoAiModel.pftL1, PhotoAiModel.pftTv]);
    expect(PhotoAiModel.pftTv.scales, [3]);
    expect(PhotoAiModel.pftTv.supports(120, 90, 3), isTrue);
    expect(PhotoAiModel.pftTv.supports(120, 90, 2), isFalse);
    expect(PhotoAiModel.pftTv.supports(400, 400, 3), isFalse);
    final oversized = PhotoRenderInput(
      temperatures: Float32List(400 * 192),
      width: 400,
      height: 192,
      params: const RenderParams(),
      aiScale: 3,
    );
    expect(oversized.supportsAiScale, isFalse);
    final ai = PhotoAiSession();
    expect(() => ai.setScale(2), throwsArgumentError);
    ai.dispose();
  });

  test(
    'oversized photo keeps ordinary preview and export reports the limit',
    () async {
      var calls = 0;
      final ai = PhotoAiSession(
        infer: (input) async {
          calls++;
          return input.render();
        },
      );
      final photo = PhotoRenderInput(
        temperatures: Float32List(400 * 192),
        width: 400,
        height: 192,
        params: const RenderParams(upsampleScale: 1, bilateralEnabled: false),
      );
      ai.setScale(3);
      expect(ai.preview(photo).width, 400);
      expect(ai.error, contains('1024'));
      await expectLater(ai.export(photo), throwsFormatException);
      expect(calls, 0);
      ai.dispose();
    },
  );

  test('changing photo while inference runs discards the old result', () async {
    final jobs = <Completer<RenderedFrame>>[];
    final ai = PhotoAiSession(
      infer: (_) {
        final done = Completer<RenderedFrame>();
        jobs.add(done);
        return done.future;
      },
    );
    final first = input(0), second = input(10);
    ai.setScale(3);
    ai.preview(first);
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(jobs.length, 1);
    ai.preview(second);
    jobs.first.complete(first.render());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(jobs.length, 2);
    final current = second.render();
    jobs[1].complete(current);
    await Future<void>.delayed(Duration.zero);
    expect(identical(ai.preview(second), current), isTrue);
    expect(ai.preview(second).tMin, second.render().tMin);
    ai.dispose();
  });

  test(
    'failed inference retains ordinary preview; export reports failure',
    () async {
      final ai = PhotoAiSession(
        infer: (_) async => throw StateError('test failure'),
      );
      final photo = input(0);
      ai.setScale(3);
      ai.preview(photo);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(ai.error, contains('test failure'));
      expect(
        ai.preview(photo).temperatureField,
        photo.render(scale: 3).temperatureField,
      );
      await expectLater(ai.export(photo), throwsStateError);
      ai.setScale(0);
      expect(
        (await ai.export(photo)).temperatureField,
        photo.render().temperatureField,
      );
      await expectLater(ai.export(photo, scale: 2), throwsFormatException);
      ai.dispose();
    },
  );
}
