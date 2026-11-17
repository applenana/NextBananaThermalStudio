import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/render/ai_super_resolution.dart';
import 'package:banana_thermal/render/photo_ai_session.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';

PhotoRenderInput input(double offset) => PhotoRenderInput(
  temperatures: Float32List.fromList(List.generate(15, (i) => 20 + offset + i)),
  width: 5,
  height: 3,
  params: const RenderParams(upsampleScale: 2, bilateralEnabled: false),
);

void main() {
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
    ai.setEnabled(true);
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
      ai.setEnabled(true);
      ai.preview(photo);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(ai.error, contains('test failure'));
      expect(
        ai.preview(photo).temperatureField,
        photo.render().temperatureField,
      );
      await expectLater(ai.export(photo), throwsStateError);
      ai.setEnabled(false);
      expect(
        (await ai.export(photo)).temperatureField,
        photo.render().temperatureField,
      );
      await expectLater(ai.export(photo, enabled: true), throwsStateError);
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
