import 'dart:typed_data';

import 'package:banana_thermal/protocol/temperature_calibration.dart';
import 'package:banana_thermal/ui/temperature_calibration_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TemperatureCalibration protocol', () {
    test('parses a firmware v1 response', () {
      final calibration = TemperatureCalibration.tryParse({
        'type': 'temperature_calibration',
        'version': 1,
        'operation': 'get',
        'gain': 1.0125,
        'offset': -0.42,
        'persisted': true,
      });

      expect(calibration, isNotNull);
      expect(calibration!.gain, 1.0125);
      expect(calibration.offset, -0.42);
      expect(calibration.persisted, isTrue);
      expect(calibration.operation, 'get');
      expect(calibration.protocol, TemperatureCalibrationProtocol.atomicV1);
    });

    test('parses a legacy Chinese response', () {
      final calibration = TemperatureCalibration.tryParseLegacy(
        '曲线信息: 权重1.02, 偏移-0.35',
      );

      expect(calibration, isNotNull);
      expect(calibration!.gain, 1.02);
      expect(calibration.offset, -0.35);
      expect(calibration.persisted, isFalse);
      expect(calibration.protocol, TemperatureCalibrationProtocol.legacy);
    });

    test('parses an ASCII-stripped legacy response only when enabled', () {
      expect(TemperatureCalibration.tryParseLegacy(': 1.00, -2.50'), isNull);
      final calibration = TemperatureCalibration.tryParseLegacy(
        ': 1.00, -2.50',
        allowAsciiOnly: true,
      );

      expect(calibration, isNotNull);
      expect(calibration!.gain, 1);
      expect(calibration.offset, -2.5);
    });

    test('rejects malformed and unknown responses', () {
      expect(
        TemperatureCalibration.tryParse({
          'type': 'temperature_calibration',
          'version': 2,
          'gain': 1,
          'offset': 0,
        }),
        isNull,
      );
      expect(
        TemperatureCalibration.tryParse({
          'type': 'temperature_calibration',
          'version': 1,
          'gain': 0,
          'offset': 0,
        }),
        isNull,
      );
    });
  });

  group('fitTemperatureCalibration', () {
    test('fits an identity-based two-point calibration', () {
      final fit = fitTemperatureCalibration(
        currentCalibration: TemperatureCalibration.identity,
        samples: const [
          CalibrationSample(measured: 19, reference: 20),
          CalibrationSample(measured: 59, reference: 60),
        ],
      );

      expect(fit, isNotNull);
      expect(fit!.calibration.gain, closeTo(1, 1e-12));
      expect(fit.calibration.offset, closeTo(1, 1e-12));
      expect(fit.rootMeanSquareError, closeTo(0, 1e-12));
    });

    test('composes the fit with the current device coefficients', () {
      const current = TemperatureCalibration(gain: 1.1, offset: 2);
      final fit = fitTemperatureCalibration(
        currentCalibration: current,
        samples: const [
          CalibrationSample(measured: 13, reference: 10),
          CalibrationSample(measured: 35, reference: 30),
          CalibrationSample(measured: 57, reference: 50),
        ],
      );

      expect(fit, isNotNull);
      expect(fit!.relativeGain, closeTo(1 / 1.1, 1e-12));
      expect(fit.relativeOffset, closeTo(-2 / 1.1, 1e-12));
      expect(fit.calibration.gain, closeTo(1, 1e-12));
      expect(fit.calibration.offset, closeTo(0, 1e-12));
      expect(fit.rSquared, closeTo(1, 1e-12));
    });

    test('uses least squares for noisy multi-point data', () {
      final fit = fitTemperatureCalibration(
        currentCalibration: TemperatureCalibration.identity,
        samples: const [
          CalibrationSample(measured: 10, reference: 12.1),
          CalibrationSample(measured: 20, reference: 22.0),
          CalibrationSample(measured: 30, reference: 31.9),
          CalibrationSample(measured: 40, reference: 42.1),
        ],
      );

      expect(fit, isNotNull);
      expect(fit!.calibration.gain, closeTo(1, 0.02));
      expect(fit.calibration.offset, closeTo(2, 0.3));
      expect(fit.rSquared, greaterThan(0.999));
    });

    test('rejects duplicate or too-close measured points', () {
      expect(
        fitTemperatureCalibration(
          currentCalibration: TemperatureCalibration.identity,
          samples: const [
            CalibrationSample(measured: 25.0, reference: 20),
            CalibrationSample(measured: 25.5, reference: 40),
          ],
        ),
        isNull,
      );
    });
  });

  test('center ROI trimmed mean rejects edge pixels and isolated outliers', () {
    final frame = Float32List(32 * 24)..fillRange(0, 32 * 24, 5);
    for (var y = 8; y < 16; y++) {
      for (var x = 12; x < 20; x++) {
        frame[y * 32 + x] = 25;
      }
    }
    frame[8 * 32 + 12] = -40;
    frame[15 * 32 + 19] = 200;

    expect(centerRoiTrimmedMean(frame), closeTo(25, 1e-9));
  });
}
