import 'package:banana_thermal/calibration/piecewise_calibration_fit.dart';
import 'package:banana_thermal/calibration/calibration_workspace.dart';
import 'package:banana_thermal/protocol/temperature_calibration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CalibrationCurve', () {
    test(
      'interpolates, inverts and keeps endpoint correction outside range',
      () {
        final curve = CalibrationCurve.piecewise(const [
          CalibrationKnot(raw: 0, corrected: 1),
          CalibrationKnot(raw: 50, corrected: 51),
          CalibrationKnot(raw: 100, corrected: 111),
        ]);

        expect(curve.correct(75), closeTo(81, 1e-9));
        expect(curve.invert(81), closeTo(75, 1e-9));
        expect(curve.correct(-20), closeTo(-19, 1e-9));
        expect(curve.correct(150), closeTo(161, 1e-9));
        expect(curve.validate().valid, isTrue);
      },
    );

    test('rejects unsafe or non-monotonic segments', () {
      final curve = CalibrationCurve.piecewise(const [
        CalibrationKnot(raw: 0, corrected: 0),
        CalibrationKnot(raw: 10, corrected: 20),
      ]);
      expect(curve.validate().valid, isFalse);
      expect(curve.validate().errors, isNotEmpty);
    });

    test('validates the quantized millidegree curve sent to firmware', () {
      final curve = CalibrationCurve.piecewise(const [
        CalibrationKnot(raw: 0, corrected: 0),
        CalibrationKnot(raw: 0.0004, corrected: 0.0004),
      ]);
      expect(curve.validate().valid, isFalse);
    });

    test('parses a v2 device state', () {
      final state = CalibrationV2State.tryParse({
        'type': 'temperature_calibration',
        'version': 2,
        'operation': 'get',
        'tx': 12,
        'mode': 2,
        'points': 3,
        'segments': 2,
        'min_mc': -10000,
        'max_mc': 100000,
        'crc32': 4294967295,
        'gen': 4,
        'gain': 1.01,
        'offset': -0.2,
        'persisted': true,
      });
      expect(state, isNotNull);
      expect(state!.segmentCount, 2);
      expect(state.generation, 4);
      expect(state.crc32, 0xffffffff);
      expect(state.fallbackGain, 1.01);
    });

    test('accepts the hard limit of 128 active segments', () {
      final knots = List.generate(
        129,
        (index) =>
            CalibrationKnot(raw: index.toDouble(), corrected: index + 0.5),
      );
      final curve = CalibrationCurve.piecewise(knots);
      expect(curve.segmentCount, 128);
      expect(curve.validate().valid, isTrue);
      expect(curve.correct(64.25), closeTo(64.75, 1e-9));
    });

    test('CRC changes with quantized point data', () {
      const first = [
        CalibrationKnot(raw: 0, corrected: 1),
        CalibrationKnot(raw: 10, corrected: 11),
      ];
      const second = [
        CalibrationKnot(raw: 0, corrected: 1),
        CalibrationKnot(raw: 10, corrected: 11.001),
      ];
      expect(
        computeCalibrationCurveCrc32(first),
        computeCalibrationCurveCrc32(first),
      );
      expect(
        computeCalibrationCurveCrc32(first),
        isNot(computeCalibrationCurveCrc32(second)),
      );
      expect(
        computeCalibrationCurveCrc32(const [
          CalibrationKnot(raw: -20, corrected: -19),
          CalibrationKnot(raw: 0, corrected: 0.5),
          CalibrationKnot(raw: 50, corrected: 49),
        ]),
        0xB04DEEA4,
      );
    });

    test('v2 linear baseline preserves CRC and generation in drafts', () {
      final curve = CalibrationCurve.linear(
        gain: 1,
        offset: 0,
        persisted: true,
        crc32: 0,
        generation: 9,
      );
      final restored = CalibrationCurve.tryParseJson(curve.toJson());
      expect(restored, isNotNull);
      expect(restored!.crc32, 0);
      expect(restored.generation, 9);
    });
  });

  group('fitPiecewiseTemperatureCalibration', () {
    test('keeps genuinely linear data at one segment', () {
      final samples = List.generate(12, (index) {
        final measured = index * 10.0;
        return CalibrationSample(measured: measured, reference: measured + 2);
      });
      final fit = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.identity,
        samples: samples,
      );

      expect(fit, isNotNull);
      expect(fit!.curve.segmentCount, 1);
      expect(fit.rootMeanSquareError, lessThan(0.001));
      expect(fit.isWithinDeviceLimits, isTrue);
    });

    test('detects a supported change in slope', () {
      final samples = List.generate(12, (index) {
        final measured = index * 10.0;
        final reference = measured <= 50
            ? measured * 0.8 + 5
            : 45 + (measured - 50) * 1.2;
        return CalibrationSample(
          measured: measured,
          reference: reference,
          standardDeviation: 0.05,
          frameCount: 24,
        );
      });
      final fit = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.identity,
        samples: samples,
        options: const CalibrationFitOptions(
          maximumSegments: 4,
          sensitivity: 100,
        ),
      );

      expect(fit, isNotNull);
      expect(fit!.curve.segmentCount, greaterThanOrEqualTo(2));
      expect(fit.rootMeanSquareError, lessThan(0.2));
    });

    test(
      'three nonlinear temperatures split when error reduction is large',
      () {
        const samples = [
          CalibrationSample(measured: 0, reference: 0),
          CalibrationSample(measured: 10, reference: 14),
          CalibrationSample(measured: 20, reference: 20),
        ];
        final fit = fitPiecewiseTemperatureCalibration(
          currentCurve: CalibrationCurve.identity,
          samples: samples,
        );

        expect(fit, isNotNull);
        expect(
          fit!.validationMethod,
          CalibrationValidationMethod.uncertaintyPenalized,
        );
        expect(fit.curve.segmentCount, 2);
        expect(fit.rootMeanSquareError, lessThan(0.01));
      },
    );

    test('three nearly linear temperatures remain one segment', () {
      const samples = [
        CalibrationSample(measured: 0, reference: 0),
        CalibrationSample(measured: 10, reference: 10.05),
        CalibrationSample(measured: 20, reference: 20),
      ];
      final fit = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.identity,
        samples: samples,
      );

      expect(fit, isNotNull);
      expect(fit!.curve.segmentCount, 1);
    });

    test('target error changes the sparse-data complexity tradeoff', () {
      const samples = [
        CalibrationSample(measured: 0, reference: 0),
        CalibrationSample(measured: 10, reference: 10.8),
        CalibrationSample(measured: 20, reference: 20),
      ];
      final precisionFirst = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.identity,
        samples: samples,
        options: const CalibrationFitOptions(targetError: 0.05),
      );
      final simplicityFirst = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.identity,
        samples: samples,
        options: const CalibrationFitOptions(targetError: 2),
      );

      expect(precisionFirst, isNotNull);
      expect(simplicityFirst, isNotNull);
      expect(precisionFirst!.curve.segmentCount, 2);
      expect(simplicityFirst!.curve.segmentCount, 1);
    });

    test('short temperature spans are a soft penalty, not a rejection', () {
      const samples = [
        CalibrationSample(measured: 0, reference: 0),
        CalibrationSample(measured: 3, reference: 4.4),
        CalibrationSample(measured: 6, reference: 6),
      ];
      final fit = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.identity,
        samples: samples,
        options: const CalibrationFitOptions(
          minimumSegmentSpan: 5,
          targetError: 0.1,
        ),
      );

      expect(fit, isNotNull);
      expect(fit!.curve.segmentCount, 2);
    });

    test(
      'old devices receive an optimized line constrained to safe limits',
      () {
        const samples = [
          CalibrationSample(measured: 0, reference: 0),
          CalibrationSample(measured: 5, reference: 10),
          CalibrationSample(measured: 8, reference: 12),
        ];
        final fit = fitPiecewiseTemperatureCalibration(
          currentCurve: CalibrationCurve.identity,
          samples: samples,
        );

        expect(fit, isNotNull);
        expect(fit!.fallbackWasConstrained, isTrue);
        expect(fit.fallbackLinear.gain, inInclusiveRange(0.5, 1.5));
        expect(fit.fallbackLinear.offset, inInclusiveRange(-100, 100));
        expect(fit.canWriteToDevice(supportsPiecewise: false), isTrue);
      },
    );

    test('manual breakpoints remain fixed while coefficients are fitted', () {
      final samples = List.generate(12, (index) {
        final measured = index * 10.0;
        return CalibrationSample(
          measured: measured,
          reference: measured <= 50
              ? measured * 0.9 + 1
              : 46 + (measured - 50) * 1.1,
        );
      });
      final fit = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.identity,
        samples: samples,
        options: const CalibrationFitOptions(
          manualMode: true,
          manualBreakpoints: [55],
        ),
      );

      expect(fit, isNotNull);
      expect(fit!.curve.segmentCount, 2);
      expect(fit.curve.knots[1].raw, 55);
    });

    test('normalizes samples through the currently active calibration', () {
      final samples = List.generate(8, (index) {
        final raw = index * 10.0;
        return CalibrationSample(measured: raw * 1.1 + 2, reference: raw + 1);
      });
      final fit = fitPiecewiseTemperatureCalibration(
        currentCurve: CalibrationCurve.linear(gain: 1.1, offset: 2),
        samples: samples,
      );

      expect(fit, isNotNull);
      expect(fit!.curve.correct(30), closeTo(31, 0.01));
    });

    test(
      'duplicates, noise and an outlier do not create many short segments',
      () {
        final samples = <CalibrationSample>[];
        for (var index = 0; index < 12; index++) {
          final measured = index * 10.0;
          for (var duplicate = 0; duplicate < 3; duplicate++) {
            final noise = (duplicate - 1) * 0.04;
            samples.add(
              CalibrationSample(
                measured: measured + duplicate * 0.01,
                reference:
                    measured +
                    1 +
                    noise +
                    (index == 6 && duplicate == 2 ? 5 : 0),
                standardDeviation: duplicate == 2 ? 0.3 : 0.05,
                frameCount: 24,
              ),
            );
          }
        }
        final fit = fitPiecewiseTemperatureCalibration(
          currentCurve: CalibrationCurve.identity,
          samples: samples,
          options: const CalibrationFitOptions(maximumSegments: 12),
        );

        expect(fit, isNotNull);
        expect(fit!.independentPointCount, 12);
        expect(fit.curve.segmentCount, lessThanOrEqualTo(2));
        expect(fit.outliers.any((value) => value), isTrue);
      },
    );

    test(
      'higher sensitivity never selects fewer segments than zero sensitivity',
      () {
        final samples = List.generate(15, (index) {
          final measured = index * 8.0;
          final reference = measured <= 56
              ? measured * 0.94 + 2
              : 54.64 + (measured - 56) * 1.08;
          final noise = (index % 3 - 1) * 0.08;
          return CalibrationSample(
            measured: measured,
            reference: reference + noise,
            standardDeviation: 0.08,
            frameCount: 24,
          );
        });
        final conservative = fitPiecewiseTemperatureCalibration(
          currentCurve: CalibrationCurve.identity,
          samples: samples,
          options: const CalibrationFitOptions(
            maximumSegments: 5,
            sensitivity: 0,
          ),
        );
        final sensitive = fitPiecewiseTemperatureCalibration(
          currentCurve: CalibrationCurve.identity,
          samples: samples,
          options: const CalibrationFitOptions(
            maximumSegments: 5,
            sensitivity: 100,
          ),
        );

        expect(conservative, isNotNull);
        expect(sensitive, isNotNull);
        expect(
          sensitive!.curve.segmentCount,
          greaterThanOrEqualTo(conservative!.curve.segmentCount),
        );
      },
    );

    test(
      'unsafe fallback line prevents a piecewise result from being written',
      () {
        final fit = PiecewiseCalibrationFit(
          curve: CalibrationCurve.piecewise(const [
            CalibrationKnot(raw: 0, corrected: 0),
            CalibrationKnot(raw: 10, corrected: 10),
          ]),
          fallbackLinear: const TemperatureCalibration(gain: 2, offset: 0),
          rootMeanSquareError: 0,
          validationRmse: 0,
          validationStandardError: 0,
          maximumAbsoluteError: 0,
          rSquared: 1,
          fallbackRmse: 0,
          fallbackMaximumAbsoluteError: 0,
          fallbackWasConstrained: false,
          validationMethod: CalibrationValidationMethod.leaveOneOut,
          residuals: const [],
          outliers: const [],
          modelScores: const [],
          independentPointCount: 6,
          warnings: const [],
        );
        expect(fit.isWithinDeviceLimits, isFalse);
        expect(fit.canWriteToDevice(supportsPiecewise: false), isFalse);
      },
    );
  });

  group('Calibration workspace', () {
    test('imports required and optional CSV columns', () {
      final imported = CalibrationCsvService.parse(
        '\ufeffmeasured_c,reference_c,raw_input_c,standard_deviation_c,frame_count,device_sn,baseline_crc\r\n'
        '20.1,20,19.5,0.04,24,SN-1,123\r\n'
        '50.2,50,,,,SN-1,123',
      );
      expect(imported.samples, hasLength(2));
      expect(imported.samples.first.rawInput, 19.5);
      expect(imported.samples.last.rawInput, isNull);
      expect(imported.deviceSerials, {'SN-1'});
      expect(imported.baselineCrcs, {123});
    });

    test('rejects malformed optional CSV sampling data', () {
      expect(
        () => CalibrationCsvService.parse(
          'measured_c,reference_c,standard_deviation_c,frame_count\n'
          '20,21,not-a-number,0',
        ),
        throwsFormatException,
      );
    });

    test('draft JSON preserves samples, options and fitted curve', () {
      final draft = CalibrationDraft(
        deviceSerial: 'SN-1',
        baselineCrc32: 123,
        samples: const [
          CalibrationSample(measured: 20, reference: 21, rawInput: 19),
        ],
        options: const CalibrationFitOptions(
          maximumSegments: 12,
          manualMode: true,
          manualBreakpoints: [10],
        ),
        fittedCurve: CalibrationCurve.piecewise(const [
          CalibrationKnot(raw: 0, corrected: 1),
          CalibrationKnot(raw: 20, corrected: 21),
        ]),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final restored = CalibrationDraft.tryParse(draft.toJson());
      expect(restored, isNotNull);
      expect(restored!.samples.single.rawInput, 19);
      expect(restored.options.manual, isTrue);
      expect(restored.fittedCurve!.correct(10), closeTo(11, 1e-9));
    });

    test('draft keeps legacy point setting and restores target error', () {
      final options = CalibrationFitOptions.fromJson({
        'minimum_points_per_segment': 1,
        'target_error_c': 0.2,
      });
      expect(options.minimumPointsPerSegment, 3);
      expect(options.targetError, 0.2);
    });

    test('fit task runs in a cancellable isolate', () async {
      final task = CalibrationFitTask();
      final fit = await task.start(
        currentCurve: CalibrationCurve.identity,
        samples: List.generate(
          8,
          (index) => CalibrationSample(
            measured: index * 10,
            reference: index * 10 + 1,
          ),
        ),
        options: const CalibrationFitOptions(),
      );
      expect(fit, isNotNull);
      expect(fit!.curve.segmentCount, 1);
      task.cancel();
    });
  });
}
