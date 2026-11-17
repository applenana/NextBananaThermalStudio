import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/photo_ai_session.dart';
import 'package:banana_thermal/render/photo_ai_model.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';

PhotoRenderInput input(double offset) => PhotoRenderInput(
  temperatures: Float32List.fromList(List.generate(15, (i) => 20 + offset + i)),
  width: 5,
  height: 3,
  params: const RenderParams(upsampleScale: 2, bilateralEnabled: false),
);

void main() {
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
      expect(() => ai.setScale(8), throwsArgumentError);
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
      ai.setModel(PhotoAiModel.pbvs);
      expect(ai.scale, 8);
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

  test('bad AI inputs are rejected before native access', () {
    expect(() => espcnX2(Float32List(10), 5, 3), throwsFormatException);
    expect(
      () => espcnX2(Float32List.fromList([double.nan]), 1, 1),
      throwsFormatException,
    );
    expect(
      () => espcnX2(Float32List.fromList([26]), 1, 1),
      throwsFormatException,
    );
  });

  test(
    'cascade limits reject unsupported scales before rendering or native access',
    () {
      expect(photoAiScales.where((s) => supportsPhotoAiScale(120, 90, s)), [
        2,
        4,
        8,
      ]);
      expect(photoAiScales.where((s) => supportsPhotoAiScale(256, 192, s)), [
        2,
        4,
      ]);
      expect(supportsPhotoAiScale(512, 512, 2), isTrue);
      expect(supportsPhotoAiScale(513, 1, 2), isFalse);
      for (final scale in [0, 3, 16]) {
        expect(
          () => espcnUpscale(Float32List(15), 5, 3, scale),
          throwsFormatException,
        );
      }
      final oversized = PhotoRenderInput(
        temperatures: Float32List(256 * 192),
        width: 256,
        height: 192,
        params: const RenderParams(),
        aiScale: 8,
      );
      expect(oversized.enhance, throwsFormatException);
      final ai = PhotoAiSession();
      expect(() => ai.setScale(3), throwsArgumentError);
      ai.dispose();
    },
  );

  test(
    'changing scale discards stale output and export captures its own scale',
    () async {
      final jobs = <Completer<RenderedFrame>>[];
      final scales = <int>[];
      final ai = PhotoAiSession(
        infer: (input) {
          scales.add(input.aiScale);
          final done = Completer<RenderedFrame>();
          jobs.add(done);
          return done.future;
        },
      );
      final photo = input(0);
      ai.setScale(2);
      ai.preview(photo);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      ai.setScale(8);
      expect(ai.preview(photo).width, 40);
      jobs[0].complete(photo.render(scale: 2));
      await Future<void>.delayed(Duration.zero);
      expect(scales, [2, 8]);
      expect(ai.preview(photo).width, 40);
      final current = photo.render(scale: 8);
      jobs[1].complete(current);
      await Future<void>.delayed(Duration.zero);
      expect(identical(ai.preview(photo), current), isTrue);
      final exporting = ai.export(photo, scale: 4);
      ai.setScale(0);
      expect(scales, [2, 8, 4]);
      jobs[2].complete(photo.render(scale: 4));
      expect((await exporting).width, 20);
      expect((await ai.export(photo)).width, photo.render().width);
      ai.dispose();
    },
  );

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
        temperatures: Float32List(256 * 192),
        width: 256,
        height: 192,
        params: const RenderParams(upsampleScale: 1, bilateralEnabled: false),
      );
      ai.setScale(8);
      expect(ai.preview(photo).width, 256);
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
    ai.setScale(2);
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
      ai.setScale(2);
      ai.preview(photo);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(ai.error, contains('test failure'));
      expect(
        ai.preview(photo).temperatureField,
        photo.render().temperatureField,
      );
      await expectLater(ai.export(photo), throwsStateError);
      ai.setScale(0);
      expect(
        (await ai.export(photo)).temperatureField,
        photo.render().temperatureField,
      );
      await expectLater(ai.export(photo, scale: 2), throwsStateError);
      ai.dispose();
    },
  );

  test(
    'native ESPCN matches the independent OpenCV convolution reference',
    () {
      final fixture = jsonDecode(
        File('test/fixtures/espcn_x2_reference.json').readAsStringSync(),
      );
      final source = Float32List.fromList(
        (fixture['input'] as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList(),
      );
      final expected = (fixture['output'] as List).cast<num>();
      final actual = espcnX2(source, fixture['width'], fixture['height']);
      expect(actual.length, expected.length);
      for (var i = 0; i < actual.length; i++) {
        expect(actual[i], closeTo(expected[i], 0.00005));
      }
    },
    skip: Platform.environment['THERMAL_SR_LIBRARY'] == null
        ? 'Set THERMAL_SR_LIBRARY to the built inference library'
        : false,
  );
}
