/// Temperature linear-calibration protocol model and least-squares fitting.
library;

import 'dart:math' as math;

enum TemperatureCalibrationProtocol {
  /// Version 1 JSON protocol: gain and offset are validated, updated and saved
  /// as one operation.
  atomicV1,

  /// Historical text protocol using separate `cali -w0` / `cali -b0`
  /// commands followed by `save`.
  legacy,
}

class TemperatureCalibration {
  static const String responseType = 'temperature_calibration';
  static const int protocolVersion = 1;

  /// Device-side safety limits. Keep these in sync with the firmware handler.
  static const double minimumGain = 0.5;
  static const double maximumGain = 1.5;
  static const double minimumOffset = -100.0;
  static const double maximumOffset = 100.0;

  final double gain;
  final double offset;
  final bool persisted;
  final String? operation;
  final TemperatureCalibrationProtocol protocol;

  const TemperatureCalibration({
    required this.gain,
    required this.offset,
    this.persisted = false,
    this.operation,
    this.protocol = TemperatureCalibrationProtocol.atomicV1,
  });

  static const identity = TemperatureCalibration(gain: 1, offset: 0);

  double correct(double rawTemperature) => rawTemperature * gain + offset;

  bool get isWithinDeviceLimits =>
      gain >= minimumGain &&
      gain <= maximumGain &&
      offset >= minimumOffset &&
      offset <= maximumOffset;

  static TemperatureCalibration? tryParse(Map<String, dynamic> json) {
    if (json['type'] != responseType) return null;
    if ((json['version'] as num?)?.toInt() != protocolVersion) return null;
    final gain = (json['gain'] as num?)?.toDouble();
    final offset = (json['offset'] as num?)?.toDouble();
    if (gain == null ||
        offset == null ||
        !gain.isFinite ||
        !offset.isFinite ||
        gain.abs() < 1e-9) {
      return null;
    }
    return TemperatureCalibration(
      gain: gain,
      offset: offset,
      persisted: json['persisted'] == true,
      operation: json['operation']?.toString(),
      protocol: TemperatureCalibrationProtocol.atomicV1,
    );
  }

  /// Parses the response produced by the historical `cali -show` command:
  ///
  /// `曲线信息: 权重1.00, 偏移0.00`
  ///
  /// [text] may also be the ASCII-only form left after a transport strips the
  /// Chinese UTF-8 bytes (`: 1.00, 0.00`). Callers should only accept that
  /// relaxed form while a legacy query is pending.
  static TemperatureCalibration? tryParseLegacy(
    String text, {
    bool allowAsciiOnly = false,
  }) {
    const number = r'([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)';
    final chinese = RegExp(
      '曲线信息\\s*[:：]\\s*权重\\s*$number\\s*[,，]\\s*偏移\\s*$number',
    ).firstMatch(text);
    final ascii = allowAsciiOnly
        ? RegExp(
            '^\\s*[:：]\\s*$number\\s*[,，]\\s*$number\\s*\$',
          ).firstMatch(text)
        : null;
    final match = chinese ?? ascii;
    if (match == null) return null;

    final gain = double.tryParse(match.group(1)!);
    final offset = double.tryParse(match.group(2)!);
    if (gain == null ||
        offset == null ||
        !gain.isFinite ||
        !offset.isFinite ||
        gain.abs() < 1e-9) {
      return null;
    }
    return TemperatureCalibration(
      gain: gain,
      offset: offset,
      // The historical query exposes only live RAM values; it cannot prove
      // that a preceding `save` completed successfully.
      persisted: false,
      operation: 'legacy_get',
      protocol: TemperatureCalibrationProtocol.legacy,
    );
  }
}

class CalibrationSample {
  /// Temperature currently reported by the device for the center ROI.
  final double measured;

  /// Reference temperature supplied by the user.
  final double reference;

  /// Temporal standard deviation of the captured frame means.
  final double standardDeviation;
  final int frameCount;

  const CalibrationSample({
    required this.measured,
    required this.reference,
    this.standardDeviation = 0,
    this.frameCount = 1,
  });
}

class LinearCalibrationFit {
  /// Maps current device output to the supplied reference values.
  final double relativeGain;
  final double relativeOffset;

  /// New coefficients expressed against the sensor's original raw output.
  final TemperatureCalibration calibration;
  final double measuredSpan;
  final double referenceSpan;
  final double rootMeanSquareError;
  final double maximumAbsoluteError;
  final double rSquared;
  final List<double> residuals;

  const LinearCalibrationFit({
    required this.relativeGain,
    required this.relativeOffset,
    required this.calibration,
    required this.measuredSpan,
    required this.referenceSpan,
    required this.rootMeanSquareError,
    required this.maximumAbsoluteError,
    required this.rSquared,
    required this.residuals,
  });

  double predictReference(double currentOutput) =>
      currentOutput * relativeGain + relativeOffset;
}

/// Fits `reference = relativeGain * currentOutput + relativeOffset`, then
/// composes that mapping with [currentCalibration] so the returned device
/// coefficients continue to operate on the original sensor temperature.
///
/// Returns null for fewer than two samples or an ill-conditioned measured
/// range. A 1°C minimum keeps accidental duplicate points from producing a
/// wildly unstable slope; the UI recommends a substantially wider range.
LinearCalibrationFit? fitTemperatureCalibration({
  required TemperatureCalibration currentCalibration,
  required List<CalibrationSample> samples,
  double minimumMeasuredSpan = 1.0,
}) {
  if (samples.length < 2) return null;
  if (samples.any(
    (sample) => !sample.measured.isFinite || !sample.reference.isFinite,
  )) {
    return null;
  }

  final measuredValues = samples.map((sample) => sample.measured).toList();
  final referenceValues = samples.map((sample) => sample.reference).toList();
  final measuredMin = measuredValues.reduce(math.min);
  final measuredMax = measuredValues.reduce(math.max);
  final referenceMin = referenceValues.reduce(math.min);
  final referenceMax = referenceValues.reduce(math.max);
  final measuredSpan = measuredMax - measuredMin;
  if (measuredSpan < minimumMeasuredSpan) return null;

  final measuredMean =
      measuredValues.reduce((a, b) => a + b) / measuredValues.length;
  final referenceMean =
      referenceValues.reduce((a, b) => a + b) / referenceValues.length;

  var sumXX = 0.0;
  var sumXY = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final dx = measuredValues[i] - measuredMean;
    sumXX += dx * dx;
    sumXY += dx * (referenceValues[i] - referenceMean);
  }
  if (sumXX <= 1e-12) return null;

  final relativeGain = sumXY / sumXX;
  final relativeOffset = referenceMean - relativeGain * measuredMean;
  if (!relativeGain.isFinite || !relativeOffset.isFinite) return null;

  final newGain = relativeGain * currentCalibration.gain;
  final newOffset = relativeGain * currentCalibration.offset + relativeOffset;
  if (!newGain.isFinite || !newOffset.isFinite) return null;

  final residuals = <double>[];
  var squaredError = 0.0;
  var maximumAbsoluteError = 0.0;
  var totalReferenceVariance = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final predicted = measuredValues[i] * relativeGain + relativeOffset;
    final residual = referenceValues[i] - predicted;
    residuals.add(residual);
    squaredError += residual * residual;
    maximumAbsoluteError = math.max(maximumAbsoluteError, residual.abs());
    final centered = referenceValues[i] - referenceMean;
    totalReferenceVariance += centered * centered;
  }

  final rSquared = totalReferenceVariance <= 1e-12
      ? (squaredError <= 1e-12 ? 1.0 : 0.0)
      : (1 - squaredError / totalReferenceVariance).clamp(0.0, 1.0);

  return LinearCalibrationFit(
    relativeGain: relativeGain,
    relativeOffset: relativeOffset,
    calibration: TemperatureCalibration(gain: newGain, offset: newOffset),
    measuredSpan: measuredSpan,
    referenceSpan: referenceMax - referenceMin,
    rootMeanSquareError: math.sqrt(squaredError / samples.length),
    maximumAbsoluteError: maximumAbsoluteError,
    rSquared: rSquared,
    residuals: residuals,
  );
}
