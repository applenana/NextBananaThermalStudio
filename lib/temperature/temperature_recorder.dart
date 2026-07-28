/// 实时温度会话记录器。
///
/// 记录设备最高/最低/平均温度，并按当前渲染坐标采集固定单点与所有多点
/// 测温数据。记录与具体页面生命周期解耦，普通视图、全屏视图和不同平台
/// 共用同一份会话。
library;

import 'package:flutter/foundation.dart';

import '../render/render_params.dart';
import '../render/render_pipeline.dart';

@immutable
class MeasurementPoint {
  final int id;
  final int x;
  final int y;

  const MeasurementPoint({required this.id, required this.x, required this.y});
}

@immutable
class TemperaturePointReading {
  final int id;
  final int x;
  final int y;
  final double temperature;

  const TemperaturePointReading({
    required this.id,
    required this.x,
    required this.y,
    required this.temperature,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'x': x,
    'y': y,
    'temperature_c': temperature,
  };

  factory TemperaturePointReading.fromJson(Map<String, dynamic> json) {
    return TemperaturePointReading(
      id: (json['id'] as num).toInt(),
      x: (json['x'] as num).toInt(),
      y: (json['y'] as num).toInt(),
      temperature: (json['temperature_c'] as num).toDouble(),
    );
  }
}

@immutable
class TemperatureSample {
  final int sequence;
  final DateTime timestamp;
  final String? deviceSerial;
  final double maximum;
  final double minimum;
  final double average;
  final double? singleTemperature;
  final double? multiPointAverage;
  final List<TemperaturePointReading> pointReadings;

  const TemperatureSample({
    required this.sequence,
    required this.timestamp,
    required this.deviceSerial,
    required this.maximum,
    required this.minimum,
    required this.average,
    required this.singleTemperature,
    required this.multiPointAverage,
    required this.pointReadings,
  });

  Map<String, dynamic> toJson() => {
    'sequence': sequence,
    'timestamp': timestamp.toIso8601String(),
    'device_serial': deviceSerial,
    'maximum_c': maximum,
    'minimum_c': minimum,
    'average_c': average,
    'single_point_c': singleTemperature,
    'multi_point_average_c': multiPointAverage,
    'points': [for (final reading in pointReadings) reading.toJson()],
  };

  factory TemperatureSample.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    return TemperatureSample(
      sequence: (json['sequence'] as num).toInt(),
      timestamp: DateTime.parse(json['timestamp'] as String),
      deviceSerial: json['device_serial'] as String?,
      maximum: (json['maximum_c'] as num).toDouble(),
      minimum: (json['minimum_c'] as num).toDouble(),
      average: (json['average_c'] as num).toDouble(),
      singleTemperature: (json['single_point_c'] as num?)?.toDouble(),
      multiPointAverage: (json['multi_point_average_c'] as num?)?.toDouble(),
      pointReadings: rawPoints is List
          ? List.unmodifiable(
              rawPoints.whereType<Map>().map(
                (point) => TemperaturePointReading.fromJson(
                  Map<String, dynamic>.from(point),
                ),
              ),
            )
          : const [],
    );
  }
}

class TemperatureRecorder extends ChangeNotifier {
  TemperatureRecorder({
    Duration sampleInterval = const Duration(seconds: 1),
    this.maxRecords = 86400,
  }) : _sampleInterval = sampleInterval;

  static final TemperatureRecorder instance = TemperatureRecorder();

  /// 默认每秒记录一次，最多保留 24 小时；导出或清空后可继续新会话。
  Duration _sampleInterval;
  final int maxRecords;

  final List<MeasurementPoint> _points = [];
  final List<TemperatureSample> _records = [];
  MeasurementPoint? _singlePoint;
  DateTime? _lastRecordedAt;
  int _nextPointId = 1;
  int _nextSequence = 1;

  List<MeasurementPoint> get points => List.unmodifiable(_points);
  MeasurementPoint? get singlePoint => _singlePoint;
  List<TemperatureSample> get records => List.unmodifiable(_records);
  TemperatureSample? get latestRecord =>
      _records.isEmpty ? null : _records.last;
  int get recordCount => _records.length;
  bool get hasSelection => _points.isNotEmpty || _singlePoint != null;
  Duration get sampleInterval => _sampleInterval;

  String get sampleIntervalLabel {
    final milliseconds = _sampleInterval.inMilliseconds;
    if (milliseconds > 0 && 1000 % milliseconds == 0) {
      return '${1000 ~/ milliseconds} 次/秒';
    }
    if (milliseconds >= 1000 && milliseconds % 1000 == 0) {
      return '每 ${milliseconds ~/ 1000} 秒一次';
    }
    return '每 $milliseconds 毫秒一次';
  }

  void setSampleInterval(Duration value) {
    final milliseconds = value.inMilliseconds.clamp(100, 60000);
    final next = Duration(milliseconds: milliseconds);
    if (next == _sampleInterval) return;
    _sampleInterval = next;
    // 频率切换从下一帧立即生效，不受旧间隔剩余时间影响。
    _lastRecordedAt = null;
    notifyListeners();
  }

  MeasurementPoint addPoint(int x, int y) {
    final point = MeasurementPoint(id: _nextPointId++, x: x, y: y);
    _points.add(point);
    return point;
  }

  void removePointAt(int index) {
    if (index < 0 || index >= _points.length) return;
    _points.removeAt(index);
  }

  void setSinglePoint(int x, int y) {
    _singlePoint = MeasurementPoint(id: 0, x: x, y: y);
  }

  void clearSelections() {
    _points.clear();
    _singlePoint = null;
  }

  void clearRecords() {
    if (_records.isEmpty) return;
    _records.clear();
    _lastRecordedAt = null;
    _nextSequence = 1;
    notifyListeners();
  }

  List<TemperatureSample> recentRecords([int limit = 100]) {
    if (_records.length <= limit) return List.unmodifiable(_records);
    return List.unmodifiable(_records.sublist(_records.length - limit));
  }

  /// 尝试写入一条记录；在 [sampleInterval] 内的额外帧会被跳过。
  ///
  /// 测温点采用与画面相同的渲染管线，因此设备缩放/偏移、插值和滤波都会
  /// 与用户实际看到的取温位置保持一致。
  bool recordFrame({
    required DateTime timestamp,
    required String? deviceSerial,
    required double maximum,
    required double minimum,
    required double average,
    required Float32List thermalFrame,
    required int srcWidth,
    required int srcHeight,
    required RenderParams renderParams,
  }) {
    final last = _lastRecordedAt;
    if (last != null && timestamp.difference(last) < _sampleInterval) {
      return false;
    }

    double? singleTemperature;
    double? multiPointAverage;
    var readings = const <TemperaturePointReading>[];
    if (_singlePoint != null || _points.isNotEmpty) {
      try {
        final rendered = renderPipeline(
          thermalFrame: thermalFrame,
          srcW: srcWidth,
          srcH: srcHeight,
          params: renderParams,
        );
        double? read(MeasurementPoint point) {
          if (point.x < 0 ||
              point.x >= rendered.width ||
              point.y < 0 ||
              point.y >= rendered.height) {
            return null;
          }
          return rendered.temperatureField[point.y * rendered.width + point.x];
        }

        final single = _singlePoint;
        if (single != null) singleTemperature = read(single);

        final mutableReadings = <TemperaturePointReading>[];
        var sum = 0.0;
        for (final point in _points) {
          final temperature = read(point);
          if (temperature == null || !temperature.isFinite) continue;
          mutableReadings.add(
            TemperaturePointReading(
              id: point.id,
              x: point.x,
              y: point.y,
              temperature: temperature,
            ),
          );
          sum += temperature;
        }
        readings = List.unmodifiable(mutableReadings);
        if (mutableReadings.isNotEmpty) {
          multiPointAverage = sum / mutableReadings.length;
        }
      } catch (_) {
        // 渲染参数暂时无效时仍保留三项基础温度，不中断整段记录。
      }
    }

    _records.add(
      TemperatureSample(
        sequence: _nextSequence++,
        timestamp: timestamp,
        deviceSerial: deviceSerial,
        maximum: maximum,
        minimum: minimum,
        average: average,
        singleTemperature: singleTemperature,
        multiPointAverage: multiPointAverage,
        pointReadings: readings,
      ),
    );
    _lastRecordedAt = timestamp;
    if (_records.length > maxRecords) {
      _records.removeRange(0, _records.length - maxRecords);
    }
    return true;
  }
}
