/// Temperature linear-calibration protocol model and least-squares fitting.
library;

import 'dart:math' as math;
import 'dart:typed_data';

enum TemperatureCalibrationProtocol {
  /// Version 1 JSON protocol: gain and offset are validated, updated and saved
  /// as one operation.
  atomicV1,

  /// Historical text protocol using separate `cali -w0` / `cali -b0`
  /// commands followed by `save`.
  legacy,
}

class CalibrationV2State {
  final String operation;
  final int transactionId;
  final int mode;
  final int pointCount;
  final int segmentCount;
  final int minimumMilliC;
  final int maximumMilliC;
  final int crc32;
  final int generation;
  final double fallbackGain;
  final double fallbackOffset;
  final bool persisted;

  const CalibrationV2State({
    required this.operation,
    required this.transactionId,
    required this.mode,
    required this.pointCount,
    required this.segmentCount,
    required this.minimumMilliC,
    required this.maximumMilliC,
    required this.crc32,
    required this.generation,
    required this.fallbackGain,
    required this.fallbackOffset,
    required this.persisted,
  });

  static CalibrationV2State? tryParse(Map<String, dynamic> json) {
    if (json['type'] != TemperatureCalibration.responseType ||
        (json['version'] as num?)?.toInt() != 2 ||
        json['error'] != null) {
      return null;
    }
    final operation = json['operation']?.toString();
    final tx = (json['tx'] as num?)?.toInt();
    final mode = (json['mode'] as num?)?.toInt();
    final points = (json['points'] as num?)?.toInt();
    final segments = (json['segments'] as num?)?.toInt();
    final minimum = (json['min_mc'] as num?)?.toInt();
    final maximum = (json['max_mc'] as num?)?.toInt();
    final crc = (json['crc32'] as num?)?.toInt();
    // Firmware uses the shorter `gen` key so the complete state response stays
    // within the existing 255-byte serial line limit. Accept the long key too
    // for compatibility with early v2 development builds.
    final generation = ((json['generation'] ?? json['gen']) as num?)?.toInt();
    final gain = (json['gain'] as num?)?.toDouble();
    final offset = (json['offset'] as num?)?.toDouble();
    if (operation == null ||
        tx == null ||
        mode == null ||
        points == null ||
        segments == null ||
        minimum == null ||
        maximum == null ||
        crc == null ||
        generation == null ||
        gain == null ||
        offset == null ||
        tx < 0 ||
        tx > 0xffffffff ||
        mode < 0 ||
        mode > 2 ||
        points < 0 ||
        points > CalibrationCurve.maximumPoints ||
        (mode == 2 && (points < 2 || segments != points - 1)) ||
        (mode != 2 && points != 0) ||
        !gain.isFinite ||
        !offset.isFinite ||
        gain < TemperatureCalibration.minimumGain ||
        gain > TemperatureCalibration.maximumGain ||
        offset < TemperatureCalibration.minimumOffset ||
        offset > TemperatureCalibration.maximumOffset ||
        crc < 0 ||
        crc > 0xffffffff ||
        generation < 0 ||
        generation > 0xffffffff) {
      return null;
    }
    return CalibrationV2State(
      operation: operation,
      transactionId: tx,
      mode: mode,
      pointCount: points,
      segmentCount: segments,
      minimumMilliC: minimum,
      maximumMilliC: maximum,
      crc32: crc & 0xffffffff,
      generation: generation,
      fallbackGain: gain,
      fallbackOffset: offset,
      persisted: json['persisted'] == true,
    );
  }
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
  final double? rawInput;

  const CalibrationSample({
    required this.measured,
    required this.reference,
    this.standardDeviation = 0,
    this.frameCount = 1,
    this.rawInput,
  });

  double rawFor(CalibrationCurve baseline) =>
      rawInput ?? baseline.invert(measured);

  CalibrationSample copyWith({
    double? measured,
    double? reference,
    double? standardDeviation,
    int? frameCount,
    double? rawInput,
  }) {
    return CalibrationSample(
      measured: measured ?? this.measured,
      reference: reference ?? this.reference,
      standardDeviation: standardDeviation ?? this.standardDeviation,
      frameCount: frameCount ?? this.frameCount,
      rawInput: rawInput ?? this.rawInput,
    );
  }
}

enum CalibrationCurveKind { identity, linear, piecewise }

class CalibrationKnot {
  final double raw;
  final double corrected;

  const CalibrationKnot({required this.raw, required this.corrected});

  int get rawMilliC => (raw * 1000).round();
  int get correctedMilliC => (corrected * 1000).round();
  double get correction => corrected - raw;

  Map<String, dynamic> toJson() => {
    'raw_mc': rawMilliC,
    'corrected_mc': correctedMilliC,
  };

  static CalibrationKnot? tryParse(Object? value) {
    if (value is! Map) return null;
    final raw = value['raw_mc'];
    final corrected = value['corrected_mc'];
    if (raw is! num || corrected is! num) return null;
    return CalibrationKnot(
      raw: raw.toInt() / 1000,
      corrected: corrected.toInt() / 1000,
    );
  }
}

class CalibrationCurveValidation {
  final bool valid;
  final List<String> errors;

  const CalibrationCurveValidation(this.valid, this.errors);
}

/// Maps sensor-domain temperature to the final reported temperature.
class CalibrationCurve {
  static const int maximumSegments = 128;
  static const int maximumPoints = maximumSegments + 1;
  static const double minimumSegmentGain = 0.5;
  static const double maximumSegmentGain = 1.5;
  static const double maximumCorrection = 100;

  final CalibrationCurveKind kind;
  final double gain;
  final double offset;
  final List<CalibrationKnot> knots;
  final bool persisted;
  final int? crc32;
  final int? generation;

  const CalibrationCurve._({
    required this.kind,
    required this.gain,
    required this.offset,
    required this.knots,
    this.persisted = false,
    this.crc32,
    this.generation,
  });

  static const identity = CalibrationCurve._(
    kind: CalibrationCurveKind.identity,
    gain: 1,
    offset: 0,
    knots: <CalibrationKnot>[],
  );

  factory CalibrationCurve.linear({
    required double gain,
    required double offset,
    bool persisted = false,
    int? crc32,
    int? generation,
  }) {
    return CalibrationCurve._(
      kind: gain == 1 && offset == 0
          ? CalibrationCurveKind.identity
          : CalibrationCurveKind.linear,
      gain: gain,
      offset: offset,
      knots: const [],
      persisted: persisted,
      crc32: crc32,
      generation: generation,
    );
  }

  factory CalibrationCurve.piecewise(
    List<CalibrationKnot> knots, {
    bool persisted = false,
    int? crc32,
    int? generation,
  }) {
    final copied = List<CalibrationKnot>.unmodifiable(knots);
    return CalibrationCurve._(
      kind: CalibrationCurveKind.piecewise,
      gain: 1,
      offset: 0,
      knots: copied,
      persisted: persisted,
      crc32: crc32 ?? computeCalibrationCurveCrc32(copied),
      generation: generation,
    );
  }

  int get segmentCount => kind == CalibrationCurveKind.piecewise
      ? math.max(0, knots.length - 1)
      : 1;

  double get rangeMinimum =>
      knots.isEmpty ? double.negativeInfinity : knots.first.raw;
  double get rangeMaximum => knots.isEmpty ? double.infinity : knots.last.raw;

  double correct(double rawTemperature) {
    if (kind != CalibrationCurveKind.piecewise || knots.length < 2) {
      return rawTemperature * gain + offset;
    }
    if (rawTemperature <= knots.first.raw) {
      return rawTemperature + knots.first.correction;
    }
    if (rawTemperature >= knots.last.raw) {
      return rawTemperature + knots.last.correction;
    }
    final index = _segmentForRaw(rawTemperature);
    final left = knots[index];
    final right = knots[index + 1];
    final ratio = (rawTemperature - left.raw) / (right.raw - left.raw);
    return left.corrected + ratio * (right.corrected - left.corrected);
  }

  double invert(double correctedTemperature) {
    if (kind != CalibrationCurveKind.piecewise || knots.length < 2) {
      if (gain.abs() < 1e-12) return correctedTemperature;
      return (correctedTemperature - offset) / gain;
    }
    if (correctedTemperature <= knots.first.corrected) {
      return correctedTemperature - knots.first.correction;
    }
    if (correctedTemperature >= knots.last.corrected) {
      return correctedTemperature - knots.last.correction;
    }
    var low = 0;
    var high = knots.length - 2;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (correctedTemperature < knots[middle].corrected) {
        high = middle - 1;
      } else if (correctedTemperature > knots[middle + 1].corrected) {
        low = middle + 1;
      } else {
        final left = knots[middle];
        final right = knots[middle + 1];
        final ratio =
            (correctedTemperature - left.corrected) /
            (right.corrected - left.corrected);
        return left.raw + ratio * (right.raw - left.raw);
      }
    }
    return correctedTemperature;
  }

  int _segmentForRaw(double value) {
    var low = 0;
    var high = knots.length - 2;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (value < knots[middle].raw) {
        high = middle - 1;
      } else if (value > knots[middle + 1].raw) {
        low = middle + 1;
      } else {
        return middle;
      }
    }
    return low.clamp(0, knots.length - 2);
  }

  CalibrationCurveValidation validate() {
    final errors = <String>[];
    if (!gain.isFinite || !offset.isFinite) errors.add('校准系数不是有限数值');
    if (kind != CalibrationCurveKind.piecewise) {
      if (gain < minimumSegmentGain || gain > maximumSegmentGain) {
        errors.add('全局斜率必须在 0.5 到 1.5 之间');
      }
      if (offset.abs() > maximumCorrection) {
        errors.add('全局偏移不得超过 ±100℃');
      }
      return CalibrationCurveValidation(errors.isEmpty, errors);
    }
    if (knots.length < 2 || knots.length > maximumPoints) {
      errors.add('分段曲线必须包含 2 到 $maximumPoints 个折点');
      return CalibrationCurveValidation(false, errors);
    }
    for (var i = 0; i < knots.length; i++) {
      final knot = knots[i];
      if (!knot.raw.isFinite || !knot.corrected.isFinite) {
        errors.add('第 ${i + 1} 个折点不是有限数值');
      }
      final rawMilliC = knot.rawMilliC;
      final correctedMilliC = knot.correctedMilliC;
      if (rawMilliC < -0x80000000 ||
          rawMilliC > 0x7fffffff ||
          correctedMilliC < -0x80000000 ||
          correctedMilliC > 0x7fffffff) {
        errors.add('第 ${i + 1} 个折点超出 int32 毫摄氏度范围');
      }
      if ((correctedMilliC - rawMilliC).abs() > 100000) {
        errors.add('第 ${i + 1} 个折点修正量超过 ±100℃');
      }
      if (i == 0) continue;
      final previous = knots[i - 1];
      final previousRawMilliC = previous.rawMilliC;
      final previousCorrectedMilliC = previous.correctedMilliC;
      if (rawMilliC <= previousRawMilliC) {
        errors.add('折点温度必须严格递增');
        continue;
      }
      if (correctedMilliC <= previousCorrectedMilliC) {
        errors.add('校准曲线必须严格单调递增');
        continue;
      }
      final slope =
          (correctedMilliC - previousCorrectedMilliC) /
          (rawMilliC - previousRawMilliC);
      if (slope < minimumSegmentGain - 1e-9 ||
          slope > maximumSegmentGain + 1e-9) {
        errors.add('第 $i 段斜率 ${slope.toStringAsFixed(4)} 超出 0.5–1.5');
      }
    }
    return CalibrationCurveValidation(errors.isEmpty, errors);
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'gain': gain,
    'offset': offset,
    'persisted': persisted,
    'crc32': crc32,
    'generation': generation,
    'knots': knots.map((knot) => knot.toJson()).toList(),
  };

  static CalibrationCurve? tryParseJson(Object? value) {
    if (value is! Map) return null;
    final kindName = value['kind']?.toString();
    if (kindName == CalibrationCurveKind.identity.name) {
      return CalibrationCurve.linear(
        gain: (value['gain'] as num?)?.toDouble() ?? 1,
        offset: (value['offset'] as num?)?.toDouble() ?? 0,
        persisted: value['persisted'] == true,
        crc32: (value['crc32'] as num?)?.toInt(),
        generation: (value['generation'] as num?)?.toInt(),
      );
    }
    if (kindName == CalibrationCurveKind.linear.name) {
      final gain = (value['gain'] as num?)?.toDouble();
      final offset = (value['offset'] as num?)?.toDouble();
      if (gain == null || offset == null) return null;
      return CalibrationCurve.linear(
        gain: gain,
        offset: offset,
        persisted: value['persisted'] == true,
        crc32: (value['crc32'] as num?)?.toInt(),
        generation: (value['generation'] as num?)?.toInt(),
      );
    }
    if (kindName != CalibrationCurveKind.piecewise.name) return null;
    final values = value['knots'];
    if (values is! List) return null;
    final knots = <CalibrationKnot>[];
    for (final item in values) {
      final knot = CalibrationKnot.tryParse(item);
      if (knot == null) return null;
      knots.add(knot);
    }
    return CalibrationCurve.piecewise(
      knots,
      persisted: value['persisted'] == true,
      crc32: (value['crc32'] as num?)?.toInt(),
      generation: (value['generation'] as num?)?.toInt(),
    );
  }
}

int computeCalibrationCurveCrc32(List<CalibrationKnot> knots) {
  final bytes = ByteData(2 + knots.length * 8);
  bytes.setUint16(0, knots.length, Endian.little);
  for (var i = 0; i < knots.length; i++) {
    bytes.setInt32(2 + i * 8, knots[i].rawMilliC, Endian.little);
    bytes.setInt32(6 + i * 8, knots[i].correctedMilliC, Endian.little);
  }
  var crc = 0xffffffff;
  for (final byte in bytes.buffer.asUint8List()) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

class CalibrationFitOptions {
  final int maximumSegments;
  final int minimumPointsPerSegment;
  final double minimumSegmentSpan;
  final double sensitivity;
  final bool robust;
  final bool manualMode;
  final List<double> manualBreakpoints;

  const CalibrationFitOptions({
    this.maximumSegments = 16,
    this.minimumPointsPerSegment = 3,
    this.minimumSegmentSpan = 5,
    this.sensitivity = 50,
    this.robust = true,
    this.manualMode = false,
    this.manualBreakpoints = const [],
  });

  bool get manual => manualMode;

  CalibrationFitOptions copyWith({
    int? maximumSegments,
    int? minimumPointsPerSegment,
    double? minimumSegmentSpan,
    double? sensitivity,
    bool? robust,
    bool? manualMode,
    List<double>? manualBreakpoints,
  }) {
    return CalibrationFitOptions(
      maximumSegments: maximumSegments ?? this.maximumSegments,
      minimumPointsPerSegment:
          minimumPointsPerSegment ?? this.minimumPointsPerSegment,
      minimumSegmentSpan: minimumSegmentSpan ?? this.minimumSegmentSpan,
      sensitivity: sensitivity ?? this.sensitivity,
      robust: robust ?? this.robust,
      manualMode: manualMode ?? this.manualMode,
      manualBreakpoints: manualBreakpoints ?? this.manualBreakpoints,
    );
  }

  Map<String, dynamic> toJson() => {
    'maximum_segments': maximumSegments,
    'minimum_points_per_segment': minimumPointsPerSegment,
    'minimum_segment_span': minimumSegmentSpan,
    'sensitivity': sensitivity,
    'robust': robust,
    'manual_mode': manualMode,
    'manual_breakpoints': manualBreakpoints,
  };

  static CalibrationFitOptions fromJson(Object? value) {
    if (value is! Map) return const CalibrationFitOptions();
    return CalibrationFitOptions(
      maximumSegments: ((value['maximum_segments'] as num?)?.toInt() ?? 16)
          .clamp(1, 128),
      minimumPointsPerSegment:
          ((value['minimum_points_per_segment'] as num?)?.toInt() ?? 3).clamp(
            3,
            20,
          ),
      minimumSegmentSpan:
          ((value['minimum_segment_span'] as num?)?.toDouble() ?? 5).clamp(
            0.5,
            50,
          ),
      sensitivity: ((value['sensitivity'] as num?)?.toDouble() ?? 50).clamp(
        0,
        100,
      ),
      robust: value['robust'] != false,
      manualMode: value['manual_mode'] == true,
      manualBreakpoints:
          (value['manual_breakpoints'] as List?)
              ?.whereType<num>()
              .map((item) => item.toDouble())
              .toList() ??
          const [],
    );
  }
}

class CalibrationModelScore {
  final int segments;
  final double trainingRmse;
  final double validationRmse;
  final double validationStandardError;

  const CalibrationModelScore({
    required this.segments,
    required this.trainingRmse,
    required this.validationRmse,
    required this.validationStandardError,
  });
}

class PiecewiseCalibrationFit {
  final CalibrationCurve curve;
  final TemperatureCalibration fallbackLinear;
  final double rootMeanSquareError;
  final double validationRmse;
  final double validationStandardError;
  final double maximumAbsoluteError;
  final double rSquared;
  final List<double> residuals;
  final List<bool> outliers;
  final List<CalibrationModelScore> modelScores;
  final int independentPointCount;
  final List<String> warnings;

  const PiecewiseCalibrationFit({
    required this.curve,
    required this.fallbackLinear,
    required this.rootMeanSquareError,
    required this.validationRmse,
    required this.validationStandardError,
    required this.maximumAbsoluteError,
    required this.rSquared,
    required this.residuals,
    required this.outliers,
    required this.modelScores,
    required this.independentPointCount,
    required this.warnings,
  });

  bool get isWithinDeviceLimits =>
      curve.validate().valid && fallbackLinear.isWithinDeviceLimits;
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
