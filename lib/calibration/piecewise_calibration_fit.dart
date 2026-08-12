import 'dart:math' as math;

import '../protocol/temperature_calibration.dart';

class _GroupedPoint {
  _GroupedPoint({required this.x, required this.y, required this.weight});

  final double x;
  final double y;
  final double weight;
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
/// largest weighted residual reduction. The final segment count is selected by
/// temperature-stratified cross validation. A sensitivity of 0/50/100 chooses
/// the smallest model within 1/0.5/0 standard errors of the best validation
/// score respectively.
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
  final fallbackSlope =
      fallbackRegression.coefficients[1] / fallbackRegression.scale;
  final fallbackOffset =
      fallbackRegression.coefficients[0] -
      fallbackSlope * fallbackRegression.center;
  final fallback = TemperatureCalibration(
    gain: fallbackSlope,
    offset: fallbackOffset,
  );

  final candidates = _candidateBreakpoints(grouped);
  final models = <_CandidateModel>[];
  if (options.manual) {
    final manual = options.manualBreakpoints.toSet().toList()..sort();
    if (!_breakpointsValid(grouped, manual, options)) return null;
    final regression = _fitRegression(grouped, manual, robust: options.robust);
    if (regression == null) return null;
    models.add(_buildCandidate(regression, grouped, options));
  } else {
    final maximumByPoints = math.max(
      1,
      grouped.length ~/ options.minimumPointsPerSegment,
    );
    final maximum = math.min(
      CalibrationCurve.maximumSegments,
      math.min(options.maximumSegments, maximumByPoints),
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
      if (segments == maximum || grouped.length < 6) break;

      double? bestBreakpoint;
      var bestSse = double.infinity;
      for (final candidate in candidates) {
        if (breakpoints.any((value) => (value - candidate).abs() < 1e-9)) {
          continue;
        }
        final trial = [...breakpoints, candidate]..sort();
        if (!_breakpointsValid(grouped, trial, options)) continue;
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
  if (grouped.length < 6) warnings.add('独立温点少于 6 个，自动模式仅使用一段。');
  if (grouped.last.x - grouped.first.x < 10) {
    warnings.add('采样温跨小于 10℃，建议增加更高或更低的参考温点。');
  }
  if (outliers.any((value) => value)) {
    warnings.add('部分样本被识别为异常点，已降低其拟合权重，请核对。');
  }
  warnings.addAll(best.curve.validate().errors);
  if (!fallback.isWithinDeviceLimits) {
    warnings.add('最佳全局直线超出固件限制，无法写入；请检查异常样本或扩大有效温区。');
  }

  return PiecewiseCalibrationFit(
    curve: best.curve,
    fallbackLinear: fallback,
    rootMeanSquareError: rmse,
    validationRmse: best.score.validationRmse,
    validationStandardError: best.score.validationStandardError,
    maximumAbsoluteError: maximumAbsoluteError,
    rSquared: rSquared,
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
  final rawWeights = sorted
      .map((sample) {
        if (sample.standardDeviation <= 0) return 1.0;
        final variance = math.max(
          0.0025,
          sample.standardDeviation * sample.standardDeviation,
        );
        return math.max(1, sample.frameCount) / variance;
      })
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
    var sumX = 0.0;
    var sumY = 0.0;
    for (var i = index; i < end; i++) {
      final weight = (rawWeights[i] / minimumWeight).clamp(1.0, 16.0);
      sumWeight += weight;
      sumX += sorted[i].rawInput! * weight;
      sumY += sorted[i].reference * weight;
    }
    result.add(
      _GroupedPoint(
        x: sumX / sumWeight,
        y: sumY / sumWeight,
        weight: sumWeight,
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

bool _breakpointsValid(
  List<_GroupedPoint> points,
  List<double> breakpoints,
  CalibrationFitOptions options,
) {
  if (breakpoints.length + 1 > CalibrationCurve.maximumSegments) return false;
  final boundaries = [points.first.x, ...breakpoints, points.last.x];
  for (var segment = 0; segment < boundaries.length - 1; segment++) {
    if (boundaries[segment + 1] - boundaries[segment] <
        options.minimumSegmentSpan) {
      return false;
    }
    var count = 0;
    for (final point in points) {
      final afterLower = segment == 0
          ? point.x >= boundaries[segment]
          : point.x > boundaries[segment];
      if (afterLower && point.x <= boundaries[segment + 1]) count++;
    }
    if (count < options.minimumPointsPerSegment) return false;
  }
  return true;
}

_CandidateModel _buildCandidate(
  _Regression regression,
  List<_GroupedPoint> points,
  CalibrationFitOptions options,
) {
  final locations = [points.first.x, ...regression.breakpoints, points.last.x];
  final knots = locations
      .map(
        (x) => CalibrationKnot(
          raw: (x * 1000).round() / 1000,
          corrected: (regression.predict(x) * 1000).round() / 1000,
        ),
      )
      .toList(growable: false);
  final curve = CalibrationCurve.piecewise(knots);
  final validation = _crossValidate(points, regression.breakpoints, options);
  final totalWeight = points.fold<double>(
    0,
    (sum, point) => sum + point.weight,
  );
  return _CandidateModel(
    breakpoints: regression.breakpoints,
    regression: regression,
    curve: curve,
    score: CalibrationModelScore(
      segments: knots.length - 1,
      trainingRmse: math.sqrt(regression.sse / totalWeight),
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
    return (
      fit == null ? double.infinity : math.sqrt(fit.sse / points.length),
      0,
    );
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
    var error = 0.0;
    var totalWeight = 0.0;
    for (final point in validation) {
      final residual = point.y - fit.predict(point.x);
      error += point.weight * residual * residual;
      totalWeight += point.weight;
    }
    foldErrors.add(math.sqrt(error / totalWeight));
  }
  if (foldErrors.isEmpty) return (double.infinity, double.infinity);
  final mean = foldErrors.reduce((a, b) => a + b) / foldErrors.length;
  if (foldErrors.length == 1) return (mean, 0);
  var variance = 0.0;
  for (final value in foldErrors) {
    final delta = value - mean;
    variance += delta * delta;
  }
  final standardError =
      math.sqrt(variance / (foldErrors.length - 1)) /
      math.sqrt(foldErrors.length);
  return (mean, standardError);
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
            !_breakpointsValid(points, trial, options)) {
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
