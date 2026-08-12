import 'dart:math' as math;

import '../protocol/temperature_calibration.dart';

class _GroupedPoint {
  _GroupedPoint({
    required this.x,
    required this.y,
    required this.weight,
    required this.uncertainty,
  });

  final double x;
  final double y;
  final double weight;
  final double uncertainty;
}

class _Regression {
  _Regression({
    required this.coefficients,
    required this.center,
    required this.scale,
    required this.breakpoints,
    required this.sse,
  });

  final List<double> coefficients;
  final double center;
  final double scale;
  final List<double> breakpoints;
  final double sse;

  double predict(double x) {
    final z = (x - center) / scale;
    var value = coefficients[0] + coefficients[1] * z;
    for (var i = 0; i < breakpoints.length; i++) {
      final knot = (breakpoints[i] - center) / scale;
      value += coefficients[i + 2] * math.max(0, z - knot);
    }
    return value;
  }
}

class _CandidateModel {
  _CandidateModel({
    required this.breakpoints,
    required this.regression,
    required this.score,
    required this.curve,
  });

  final List<double> breakpoints;
  final _Regression regression;
  final CalibrationModelScore score;
  final CalibrationCurve curve;
}

/// Fits a continuous, robust, piecewise-linear calibration curve.
///
/// Candidate models are nested by greedily adding the breakpoint with the
/// largest robust weighted residual reduction, then relocating every retained
/// breakpoint. Six or more independent temperatures use cross validation.
/// Sparse data uses an uncertainty-aware predictive risk: a breakpoint is
/// retained only when its error reduction pays for its complexity and short
/// temperature span. There is deliberately no points-per-segment rule.
PiecewiseCalibrationFit? fitPiecewiseTemperatureCalibration({
  required CalibrationCurve currentCurve,
  required List<CalibrationSample> samples,
  CalibrationFitOptions options = const CalibrationFitOptions(),
}) {
  if (samples.length < 2) return null;
  if (samples.any(
    (sample) => !sample.measured.isFinite || !sample.reference.isFinite,
  )) {
    return null;
  }

  final normalized = <CalibrationSample>[];
  for (final sample in samples) {
    final raw = sample.rawFor(currentCurve);
    if (!raw.isFinite) return null;
    normalized.add(sample.copyWith(rawInput: raw));
  }
  final grouped = _groupSamples(normalized);
  if (grouped.length < 2 || grouped.last.x - grouped.first.x < 1) return null;

  final fallbackRegression = _fitRegression(
    grouped,
    const [],
    // The compatibility line is also the only calibration understood by old
    // firmware, so keep it robust even if the advanced spline option is off.
    robust: true,
  );
  if (fallbackRegression == null) return null;
  final unconstrainedFallbackSlope =
      fallbackRegression.coefficients[1] / fallbackRegression.scale;
  final unconstrainedFallbackOffset =
      fallbackRegression.coefficients[0] -
      unconstrainedFallbackSlope * fallbackRegression.center;
  final unconstrainedFallback = TemperatureCalibration(
    gain: unconstrainedFallbackSlope,
    offset: unconstrainedFallbackOffset,
  );
  final fallback = _fitConstrainedCompatibilityLine(grouped);
  if (fallback == null) return null;
  final fallbackWasConstrained = !unconstrainedFallback.isWithinDeviceLimits;
  final fallbackErrors = _linearErrorMetrics(fallback, normalized);
  final validationMethod = grouped.length < 6
      ? CalibrationValidationMethod.uncertaintyPenalized
      : grouped.length < 10
      ? CalibrationValidationMethod.leaveOneOut
      : CalibrationValidationMethod.stratifiedFiveFold;

  final candidates = _candidateBreakpoints(grouped);
  final models = <_CandidateModel>[];
  if (options.manual) {
    final manual = options.manualBreakpoints.toSet().toList()..sort();
    if (!_breakpointsValid(grouped, manual)) return null;
    final regression = _fitRegression(grouped, manual, robust: options.robust);
    if (regression == null) return null;
    models.add(_buildCandidate(regression, grouped, options));
  } else {
    // A continuous spline with S segments has S+1 coefficients. Rank, not an
    // arbitrary count in each interval, is the only hard data-size bound.
    final maximumByRank = math.max(1, grouped.length - 1);
    final maximum = math.min(
      CalibrationCurve.maximumSegments,
      math.min(options.maximumSegments, maximumByRank),
    );
    var breakpoints = <double>[];
    for (var segments = 1; segments <= maximum; segments++) {
      final regression = _fitRegression(
        grouped,
        breakpoints,
        robust: options.robust,
      );
      if (regression == null) break;
      models.add(_buildCandidate(regression, grouped, options));
      if (segments == maximum) break;

      double? bestBreakpoint;
      var bestSse = double.infinity;
      for (final candidate in candidates) {
        if (breakpoints.any((value) => (value - candidate).abs() < 1e-9)) {
          continue;
        }
        final trial = [...breakpoints, candidate]..sort();
        if (!_breakpointsValid(grouped, trial)) continue;
        final fit = _fitRegression(grouped, trial, robust: options.robust);
        if (fit != null && fit.sse < bestSse) {
          bestSse = fit.sse;
          bestBreakpoint = candidate;
        }
      }
      if (bestBreakpoint == null) break;
      breakpoints = [...breakpoints, bestBreakpoint]..sort();
    }
  }
  if (models.isEmpty) return null;

  final validModels = models
      .where((model) => model.curve.validate().valid)
      .toList(growable: false);
  final selectable = validModels.isEmpty ? models : validModels;
  var best = selectable.first;
  for (final model in selectable.skip(1)) {
    if (model.score.validationRmse < best.score.validationRmse) best = model;
  }
  final tolerance =
      (1 - options.sensitivity.clamp(0, 100) / 100) *
      best.score.validationStandardError;
  final threshold = best.score.validationRmse + tolerance;
  for (final model in selectable) {
    if (model.score.validationRmse <= threshold) {
      best = model;
      break;
    }
  }

  if (!options.manual && best.breakpoints.isNotEmpty) {
    final refined = _refineBreakpoints(
      grouped,
      best.breakpoints,
      candidates,
      options,
    );
    final regression = _fitRegression(grouped, refined, robust: options.robust);
    if (regression != null) {
      final refinedModel = _buildCandidate(regression, grouped, options);
      if (refinedModel.curve.validate().valid &&
          refinedModel.score.validationRmse <= best.score.validationRmse) {
        best = refinedModel;
      }
    }
  }

  final residuals = <double>[];
  var squaredError = 0.0;
  var maximumAbsoluteError = 0.0;
  final referenceMean =
      normalized.fold<double>(0, (sum, item) => sum + item.reference) /
      normalized.length;
  var totalVariance = 0.0;
  for (final sample in normalized) {
    final residual = sample.reference - best.curve.correct(sample.rawInput!);
    residuals.add(residual);
    squaredError += residual * residual;
    maximumAbsoluteError = math.max(maximumAbsoluteError, residual.abs());
    final centered = sample.reference - referenceMean;
    totalVariance += centered * centered;
  }
  final rmse = math.sqrt(squaredError / normalized.length);
  final rSquared = totalVariance <= 1e-12
      ? (squaredError <= 1e-12 ? 1.0 : 0.0)
      : (1 - squaredError / totalVariance).clamp(0.0, 1.0);
  final residualScale = math.max(1e-6, 1.4826 * _medianAbsolute(residuals));
  final outliers = residuals
      .map((residual) => residual.abs() > 2.5 * residualScale)
      .toList(growable: false);

  final warnings = <String>[];
  if (grouped.length < 6) {
    warnings.add('独立温点少于 6 个，当前使用测量不确定度、误差收益和复杂度惩罚选择段数；建议继续采集以获得交叉验证证据。');
  }
  if (grouped.last.x - grouped.first.x < 10) {
    warnings.add('采样温跨小于 10℃，建议增加更高或更低的参考温点。');
  }
  if (outliers.any((value) => value)) {
    warnings.add('部分样本被识别为异常点，已降低其拟合权重，请核对。');
  }
  warnings.addAll(best.curve.validate().errors);
  if (fallbackWasConstrained) {
    warnings.add('兼容单直线已约束到旧设备可写范围；升级固件后可写入当前多段结果以降低误差。');
  }

  return PiecewiseCalibrationFit(
    curve: best.curve,
    fallbackLinear: fallback,
    rootMeanSquareError: rmse,
    validationRmse: best.score.validationRmse,
    validationStandardError: best.score.validationStandardError,
    maximumAbsoluteError: maximumAbsoluteError,
    rSquared: rSquared,
    fallbackRmse: fallbackErrors.$1,
    fallbackMaximumAbsoluteError: fallbackErrors.$2,
    fallbackWasConstrained: fallbackWasConstrained,
    validationMethod: validationMethod,
    residuals: residuals,
    outliers: outliers,
    modelScores: models.map((model) => model.score).toList(growable: false),
    independentPointCount: grouped.length,
    warnings: warnings,
  );
}

List<_GroupedPoint> _groupSamples(List<CalibrationSample> samples) {
  final sorted = [...samples]
    ..sort((left, right) => left.rawInput!.compareTo(right.rawInput!));
  final uncertainties = sorted
      .map((sample) {
        if (sample.standardDeviation <= 0) return 0.1;
        return math.max(
          0.01,
          sample.standardDeviation / math.sqrt(math.max(1, sample.frameCount)),
        );
      })
      .toList(growable: false);
  final rawWeights = uncertainties
      .map((uncertainty) => 1 / (uncertainty * uncertainty))
      .toList(growable: false);
  final minimumWeight = rawWeights.reduce(math.min);

  final result = <_GroupedPoint>[];
  var index = 0;
  while (index < sorted.length) {
    var end = index + 1;
    while (end < sorted.length &&
        sorted[end].rawInput! - sorted[end - 1].rawInput! <= 0.05) {
      end++;
    }
    var sumWeight = 0.0;
    var sumPrecision = 0.0;
    var sumX = 0.0;
    var sumY = 0.0;
    for (var i = index; i < end; i++) {
      final weight = (rawWeights[i] / minimumWeight).clamp(1.0, 16.0);
      sumWeight += weight;
      sumPrecision += rawWeights[i];
      sumX += sorted[i].rawInput! * weight;
      sumY += sorted[i].reference * weight;
    }
    result.add(
      _GroupedPoint(
        x: sumX / sumWeight,
        y: sumY / sumWeight,
        weight: sumWeight,
        uncertainty: math.max(0.005, math.sqrt(1 / sumPrecision)),
      ),
    );
    index = end;
  }
  final minimumGroupedWeight = result
      .map((point) => point.weight)
      .reduce(math.min);
  return result
      .map(
        (point) => _GroupedPoint(
          x: point.x,
          y: point.y,
          weight: (point.weight / minimumGroupedWeight).clamp(1.0, 16.0),
          uncertainty: point.uncertainty,
        ),
      )
      .toList(growable: false);
}

List<double> _candidateBreakpoints(List<_GroupedPoint> points) {
  final all = <double>[];
  for (var i = 0; i < points.length - 1; i++) {
    all.add((points[i].x + points[i + 1].x) / 2);
    if (i > 0) all.add(points[i].x);
  }
  all.sort();
  if (all.length <= 256) return all;
  final result = <double>[];
  for (var i = 0; i < 256; i++) {
    final index = (i * (all.length - 1) / 255).round();
    final value = all[index];
    if (result.isEmpty || value != result.last) result.add(value);
  }
  return result;
}

bool _breakpointsValid(List<_GroupedPoint> points, List<double> breakpoints) {
  if (breakpoints.length + 1 > CalibrationCurve.maximumSegments) return false;
  if (breakpoints.length > points.length - 2) return false;
  var previous = points.first.x;
  for (final breakpoint in breakpoints) {
    if (!breakpoint.isFinite ||
        breakpoint <= previous ||
        breakpoint >= points.last.x) {
      return false;
    }
    previous = breakpoint;
  }
  return true;
}

_CandidateModel _buildCandidate(
  _Regression regression,
  List<_GroupedPoint> points,
  CalibrationFitOptions options,
) {
  final curve = _curveFromRegression(regression, points);
  final validation = _crossValidate(points, regression.breakpoints, options);
  final totalWeight = points.fold<double>(
    0,
    (sum, point) => sum + point.weight,
  );
  var trainingError = 0.0;
  for (final point in points) {
    final residual = point.y - curve.correct(point.x);
    trainingError += point.weight * residual * residual;
  }
  return _CandidateModel(
    breakpoints: regression.breakpoints,
    regression: regression,
    curve: curve,
    score: CalibrationModelScore(
      segments: curve.segmentCount,
      trainingRmse: math.sqrt(trainingError / totalWeight),
      validationRmse: validation.$1,
      validationStandardError: validation.$2,
    ),
  );
}

(double, double) _crossValidate(
  List<_GroupedPoint> points,
  List<double> breakpoints,
  CalibrationFitOptions options,
) {
  if (points.length < 6) {
    final fit = _fitRegression(points, breakpoints, robust: options.robust);
    if (fit == null) return (double.infinity, 0);
    final curve = _curveFromRegression(fit, points);
    final trainingRmse = _weightedCurveRmse(curve, points);
    return (_predictionRisk(trainingRmse, points, breakpoints, options), 0);
  }
  final foldCount = points.length < 10 ? points.length : 5;
  final foldErrors = <double>[];
  for (var fold = 0; fold < foldCount; fold++) {
    final training = <_GroupedPoint>[];
    final validation = <_GroupedPoint>[];
    for (var i = 0; i < points.length; i++) {
      if (i % foldCount == fold) {
        validation.add(points[i]);
      } else {
        training.add(points[i]);
      }
    }
    final fit = _fitRegression(training, breakpoints, robust: options.robust);
    if (fit == null || validation.isEmpty) {
      return (double.infinity, double.infinity);
    }
    final curve = _curveFromRegression(fit, points);
    var error = 0.0;
    var totalWeight = 0.0;
    for (final point in validation) {
      final residual = point.y - curve.correct(point.x);
      error += point.weight * residual * residual;
      totalWeight += point.weight;
    }
    foldErrors.add(math.sqrt(error / totalWeight));
  }
  if (foldErrors.isEmpty) return (double.infinity, double.infinity);
  final mean = foldErrors.reduce((a, b) => a + b) / foldErrors.length;
  final risk = _predictionRisk(mean, points, breakpoints, options);
  if (foldErrors.length == 1) return (risk, 0);
  var variance = 0.0;
  for (final value in foldErrors) {
    final delta = value - mean;
    variance += delta * delta;
  }
  final standardError =
      math.sqrt(variance / (foldErrors.length - 1)) /
      math.sqrt(foldErrors.length);
  return (risk, standardError);
}

CalibrationCurve _curveFromRegression(
  _Regression regression,
  List<_GroupedPoint> domain,
) {
  final locations = [domain.first.x, ...regression.breakpoints, domain.last.x];
  final raw = locations.map((value) => (value * 1000).round()).toList();
  final desired = locations
      .map((value) => (regression.predict(value) * 1000).round())
      .toList();
  final lower = List<int>.generate(raw.length, (i) => raw[i] - 100000);
  final upper = List<int>.generate(raw.length, (i) => raw[i] + 100000);

  // Project the unconstrained spline onto the exact integer constraints used
  // by firmware. The feasible set always contains the identity curve.
  for (var i = raw.length - 2; i >= 0; i--) {
    final dx = raw[i + 1] - raw[i];
    final minimumRise = (dx + 1) ~/ 2;
    final maximumRise = (3 * dx) ~/ 2;
    lower[i] = math.max(lower[i], lower[i + 1] - maximumRise);
    upper[i] = math.min(upper[i], upper[i + 1] - minimumRise);
  }
  final corrected = List<int>.filled(raw.length, 0);
  corrected[0] = desired[0].clamp(lower[0], upper[0]);
  for (var i = 1; i < raw.length; i++) {
    final dx = raw[i] - raw[i - 1];
    final minimumRise = (dx + 1) ~/ 2;
    final maximumRise = (3 * dx) ~/ 2;
    final feasibleLower = math.max(lower[i], corrected[i - 1] + minimumRise);
    final feasibleUpper = math.min(upper[i], corrected[i - 1] + maximumRise);
    corrected[i] = desired[i].clamp(feasibleLower, feasibleUpper);
  }
  return CalibrationCurve.piecewise(
    List.generate(
      raw.length,
      (i) =>
          CalibrationKnot(raw: raw[i] / 1000, corrected: corrected[i] / 1000),
    ),
  );
}

double _weightedCurveRmse(CalibrationCurve curve, List<_GroupedPoint> points) {
  var error = 0.0;
  var totalWeight = 0.0;
  for (final point in points) {
    final residual = point.y - curve.correct(point.x);
    error += point.weight * residual * residual;
    totalWeight += point.weight;
  }
  return math.sqrt(error / totalWeight);
}

double _predictionRisk(
  double predictiveRmse,
  List<_GroupedPoint> points,
  List<double> breakpoints,
  CalibrationFitOptions options,
) {
  if (breakpoints.isEmpty) return predictiveRmse;
  var uncertaintySquared = 0.0;
  var totalWeight = 0.0;
  for (final point in points) {
    uncertaintySquared += point.weight * point.uncertainty * point.uncertainty;
    totalWeight += point.weight;
  }
  final noiseFloor = math.sqrt(uncertaintySquared / totalWeight);
  final sensitivityFactor = 1.25 - options.sensitivity.clamp(0, 100) / 100;
  final basePenalty = math.max(
    noiseFloor * 2,
    options.targetError * sensitivityFactor,
  );
  final boundaries = [points.first.x, ...breakpoints, points.last.x];
  var shortSpanSquared = 0.0;
  for (var i = 1; i < boundaries.length; i++) {
    final span = math.max(0.001, boundaries[i] - boundaries[i - 1]);
    final factor = math.max(1.0, options.minimumSegmentSpan / span);
    shortSpanSquared += factor * factor;
  }
  final shortSpanFactor = math.min(
    4.0,
    math.sqrt(shortSpanSquared / (boundaries.length - 1)),
  );
  final complexity =
      basePenalty * math.sqrt(breakpoints.length) * shortSpanFactor;
  return math.sqrt(predictiveRmse * predictiveRmse + complexity * complexity);
}

TemperatureCalibration? _fitConstrainedCompatibilityLine(
  List<_GroupedPoint> points,
) {
  if (points.length < 2) return null;
  const minimum = TemperatureCalibration.minimumGain;
  const maximum = TemperatureCalibration.maximumGain;
  const samples = 240;
  var bestGain = minimum;
  var best = _compatibilityLineAtGain(points, bestGain);
  var bestLoss = _robustLineLoss(points, best);
  for (var i = 1; i <= samples; i++) {
    final gain = minimum + (maximum - minimum) * i / samples;
    final line = _compatibilityLineAtGain(points, gain);
    final loss = _robustLineLoss(points, line);
    if (loss < bestLoss) {
      bestGain = gain;
      best = line;
      bestLoss = loss;
    }
  }

  var left = math.max(minimum, bestGain - (maximum - minimum) / samples);
  var right = math.min(maximum, bestGain + (maximum - minimum) / samples);
  for (var iteration = 0; iteration < 36; iteration++) {
    final first = left + (right - left) / 3;
    final second = right - (right - left) / 3;
    final firstLine = _compatibilityLineAtGain(points, first);
    final secondLine = _compatibilityLineAtGain(points, second);
    if (_robustLineLoss(points, firstLine) <=
        _robustLineLoss(points, secondLine)) {
      right = second;
      best = firstLine;
    } else {
      left = first;
      best = secondLine;
    }
  }
  return _compatibilityLineAtGain(points, (left + right) / 2);
}

TemperatureCalibration _compatibilityLineAtGain(
  List<_GroupedPoint> points,
  double gain,
) {
  var weights = points.map((point) => point.weight).toList(growable: false);
  var offset = 0.0;
  for (var iteration = 0; iteration < 5; iteration++) {
    var sum = 0.0;
    var total = 0.0;
    for (var i = 0; i < points.length; i++) {
      sum += weights[i] * (points[i].y - gain * points[i].x);
      total += weights[i];
    }
    offset = (sum / total).clamp(
      TemperatureCalibration.minimumOffset,
      TemperatureCalibration.maximumOffset,
    );
    if (iteration == 4) break;
    final residuals = points
        .map((point) => point.y - (gain * point.x + offset))
        .toList(growable: false);
    final sigma = math.max(0.02, 1.4826 * _medianAbsolute(residuals));
    final huber = 1.5 * sigma;
    weights = List.generate(points.length, (i) {
      final absolute = residuals[i].abs();
      return points[i].weight * (absolute <= huber ? 1 : huber / absolute);
    }, growable: false);
  }
  return TemperatureCalibration(gain: gain, offset: offset);
}

double _robustLineLoss(
  List<_GroupedPoint> points,
  TemperatureCalibration line,
) {
  final residuals = points
      .map((point) => point.y - line.correct(point.x))
      .toList(growable: false);
  final sigma = math.max(0.02, 1.4826 * _medianAbsolute(residuals));
  final huber = 1.5 * sigma;
  var loss = 0.0;
  for (var i = 0; i < points.length; i++) {
    final absolute = residuals[i].abs();
    final value = absolute <= huber
        ? 0.5 * absolute * absolute
        : huber * (absolute - 0.5 * huber);
    loss += points[i].weight * value;
  }
  return loss;
}

(double, double) _linearErrorMetrics(
  TemperatureCalibration line,
  List<CalibrationSample> samples,
) {
  var squared = 0.0;
  var maximum = 0.0;
  for (final sample in samples) {
    final residual = sample.reference - line.correct(sample.rawInput!);
    squared += residual * residual;
    maximum = math.max(maximum, residual.abs());
  }
  return (math.sqrt(squared / samples.length), maximum);
}

List<double> _refineBreakpoints(
  List<_GroupedPoint> points,
  List<double> initial,
  List<double> candidates,
  CalibrationFitOptions options,
) {
  var result = [...initial];
  for (var pass = 0; pass < 2; pass++) {
    for (var index = 0; index < result.length; index++) {
      var bestValue = result[index];
      var bestSse = double.infinity;
      for (final candidate in candidates) {
        final trial = [...result];
        trial[index] = candidate;
        trial.sort();
        if (trial.toSet().length != trial.length ||
            !_breakpointsValid(points, trial)) {
          continue;
        }
        final fit = _fitRegression(points, trial, robust: options.robust);
        if (fit != null && fit.sse < bestSse) {
          bestSse = fit.sse;
          bestValue = candidate;
        }
      }
      result[index] = bestValue;
      result.sort();
    }
  }
  return result;
}

_Regression? _fitRegression(
  List<_GroupedPoint> points,
  List<double> breakpoints, {
  required bool robust,
}) {
  if (points.length < 2) return null;
  final minimum = points.first.x;
  final maximum = points.last.x;
  final center = (minimum + maximum) / 2;
  final scale = math.max(1.0, (maximum - minimum) / 2);
  var weights = points.map((point) => point.weight).toList(growable: false);
  List<double>? coefficients;
  for (var iteration = 0; iteration < (robust ? 4 : 1); iteration++) {
    coefficients = _weightedLeastSquares(
      points,
      breakpoints,
      weights,
      center,
      scale,
    );
    if (coefficients == null) return null;
    if (!robust || iteration == 3) break;
    final residuals = <double>[];
    for (final point in points) {
      residuals.add(
        point.y - _predict(point.x, coefficients, breakpoints, center, scale),
      );
    }
    final sigma = math.max(1e-6, 1.4826 * _medianAbsolute(residuals));
    final huber = 1.5 * sigma;
    weights = List<double>.generate(points.length, (index) {
      final absolute = residuals[index].abs();
      final multiplier = absolute <= huber ? 1.0 : huber / absolute;
      return points[index].weight * multiplier;
    });
  }
  if (coefficients == null) return null;
  var sse = 0.0;
  for (var i = 0; i < points.length; i++) {
    final residual =
        points[i].y -
        _predict(points[i].x, coefficients, breakpoints, center, scale);
    sse += points[i].weight * residual * residual;
  }
  return _Regression(
    coefficients: coefficients,
    center: center,
    scale: scale,
    breakpoints: List.unmodifiable(breakpoints),
    sse: sse,
  );
}

List<double>? _weightedLeastSquares(
  List<_GroupedPoint> points,
  List<double> breakpoints,
  List<double> weights,
  double center,
  double scale,
) {
  final size = breakpoints.length + 2;
  final matrix = List.generate(size, (_) => List<double>.filled(size, 0));
  final vector = List<double>.filled(size, 0);
  for (var row = 0; row < points.length; row++) {
    final point = points[row];
    final z = (point.x - center) / scale;
    final features = <double>[1, z];
    for (final breakpoint in breakpoints) {
      features.add(math.max(0, z - (breakpoint - center) / scale));
    }
    final weight = weights[row];
    for (var i = 0; i < size; i++) {
      vector[i] += weight * features[i] * point.y;
      for (var j = 0; j < size; j++) {
        matrix[i][j] += weight * features[i] * features[j];
      }
    }
  }
  for (var i = 1; i < size; i++) {
    matrix[i][i] += 1e-10;
  }
  return _solve(matrix, vector);
}

List<double>? _solve(List<List<double>> matrix, List<double> vector) {
  final size = vector.length;
  for (var column = 0; column < size; column++) {
    var pivot = column;
    for (var row = column + 1; row < size; row++) {
      if (matrix[row][column].abs() > matrix[pivot][column].abs()) pivot = row;
    }
    if (matrix[pivot][column].abs() < 1e-12) return null;
    if (pivot != column) {
      final temporary = matrix[pivot];
      matrix[pivot] = matrix[column];
      matrix[column] = temporary;
      final value = vector[pivot];
      vector[pivot] = vector[column];
      vector[column] = value;
    }
    final divisor = matrix[column][column];
    for (var item = column; item < size; item++) {
      matrix[column][item] /= divisor;
    }
    vector[column] /= divisor;
    for (var row = 0; row < size; row++) {
      if (row == column) continue;
      final factor = matrix[row][column];
      if (factor == 0) continue;
      for (var item = column; item < size; item++) {
        matrix[row][item] -= factor * matrix[column][item];
      }
      vector[row] -= factor * vector[column];
    }
  }
  return vector;
}

double _predict(
  double x,
  List<double> coefficients,
  List<double> breakpoints,
  double center,
  double scale,
) {
  final z = (x - center) / scale;
  var value = coefficients[0] + coefficients[1] * z;
  for (var i = 0; i < breakpoints.length; i++) {
    final knot = (breakpoints[i] - center) / scale;
    value += coefficients[i + 2] * math.max(0, z - knot);
  }
  return value;
}

double _medianAbsolute(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = values.map((value) => value.abs()).toList()..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}
