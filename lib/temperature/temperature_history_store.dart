/// 跨端温度历史会话持久化。
///
/// 每个会话使用独立目录：
///   metadata.json  - 版本、设备、时间范围与聚合统计
///   samples.jsonl  - 每行一条 [TemperatureSample]，只追加不重写
///
/// 该格式不依赖原生数据库，在 Windows / Android 上行为一致；即使应用异常
/// 退出，也只可能丢失尚未到达短缓冲刷盘周期的少量采样。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'temperature_recorder.dart';

@immutable
class TemperatureHistorySession {
  static const int currentVersion = 1;

  final int version;
  final String id;
  final String name;
  final DateTime startedAt;
  final DateTime endedAt;
  final String? deviceSerial;
  final int sampleIntervalMs;
  final int sampleCount;
  final double maximum;
  final double minimum;
  final double averageSum;
  final int pointCountPeak;
  final bool active;
  final bool imported;

  const TemperatureHistorySession({
    this.version = currentVersion,
    required this.id,
    required this.name,
    required this.startedAt,
    required this.endedAt,
    required this.deviceSerial,
    required this.sampleIntervalMs,
    required this.sampleCount,
    required this.maximum,
    required this.minimum,
    required this.averageSum,
    required this.pointCountPeak,
    required this.active,
    this.imported = false,
  });

  Duration get duration => endedAt.difference(startedAt);
  double get average => sampleCount == 0 ? 0 : averageSum / sampleCount;

  TemperatureHistorySession copyWith({
    String? name,
    DateTime? endedAt,
    String? deviceSerial,
    int? sampleIntervalMs,
    int? sampleCount,
    double? maximum,
    double? minimum,
    double? averageSum,
    int? pointCountPeak,
    bool? active,
  }) {
    return TemperatureHistorySession(
      version: version,
      id: id,
      name: name ?? this.name,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      deviceSerial: deviceSerial ?? this.deviceSerial,
      sampleIntervalMs: sampleIntervalMs ?? this.sampleIntervalMs,
      sampleCount: sampleCount ?? this.sampleCount,
      maximum: maximum ?? this.maximum,
      minimum: minimum ?? this.minimum,
      averageSum: averageSum ?? this.averageSum,
      pointCountPeak: pointCountPeak ?? this.pointCountPeak,
      active: active ?? this.active,
      imported: imported,
    );
  }

  Map<String, dynamic> toJson() => {
    'format': 'banana_thermal_temperature_history',
    'version': version,
    'id': id,
    'name': name,
    'started_at': startedAt.toIso8601String(),
    'ended_at': endedAt.toIso8601String(),
    'device_serial': deviceSerial,
    'sample_interval_ms': sampleIntervalMs,
    'sample_count': sampleCount,
    'maximum_c': maximum,
    'minimum_c': minimum,
    'average_sum_c': averageSum,
    'average_c': average,
    'point_count_peak': pointCountPeak,
    'active': active,
    'imported': imported,
  };

  factory TemperatureHistorySession.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? 0;
    if (version != currentVersion) {
      throw const FormatException('不支持的温度历史版本');
    }
    final sampleCount = (json['sample_count'] as num?)?.toInt() ?? 0;
    final averageSum =
        (json['average_sum_c'] as num?)?.toDouble() ??
        ((json['average_c'] as num?)?.toDouble() ?? 0) * sampleCount;
    return TemperatureHistorySession(
      version: version,
      id: json['id'] as String,
      name: json['name'] as String? ?? '未命名测温记录',
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: DateTime.parse(json['ended_at'] as String),
      deviceSerial: json['device_serial'] as String?,
      sampleIntervalMs: (json['sample_interval_ms'] as num?)?.toInt() ?? 1000,
      sampleCount: sampleCount,
      maximum: (json['maximum_c'] as num?)?.toDouble() ?? -double.infinity,
      minimum: (json['minimum_c'] as num?)?.toDouble() ?? double.infinity,
      averageSum: averageSum,
      pointCountPeak: (json['point_count_peak'] as num?)?.toInt() ?? 0,
      active: json['active'] as bool? ?? false,
      imported: json['imported'] as bool? ?? false,
    );
  }
}

class TemperatureHistoryStore extends ChangeNotifier {
  TemperatureHistoryStore({
    Directory? rootDirectory,
    Duration flushDelay = const Duration(milliseconds: 750),
  }) : _providedRoot = rootDirectory,
       _flushDelay = flushDelay;

  static final TemperatureHistoryStore instance = TemperatureHistoryStore();

  static const Duration automaticGap = Duration(seconds: 30);
  static const Duration maximumSessionDuration = Duration(hours: 24);
  static const int maximumSessionSamples = 100000;

  final Directory? _providedRoot;
  final Duration _flushDelay;
  Directory? _root;
  final List<TemperatureHistorySession> _sessions = [];
  TemperatureHistorySession? _activeSession;
  String? _pendingSessionId;
  StringBuffer _pendingLines = StringBuffer();
  Timer? _flushTimer;
  Future<void> _writeQueue = Future<void>.value();
  bool _initialized = false;
  bool _busy = false;
  String? _lastError;

  bool get initialized => _initialized;
  bool get busy => _busy;
  String? get lastError => _lastError;
  String? get storagePath => _root?.path;
  TemperatureHistorySession? get activeSession => _activeSession;
  List<TemperatureHistorySession> get sessions => List.unmodifiable(_sessions);

  Future<void> initialize() async {
    if (_initialized) return;
    _busy = true;
    _lastError = null;
    try {
      final root =
          _providedRoot ??
          Directory(
            p.join(
              (await getApplicationDocumentsDirectory()).path,
              'BananaThermalStudio',
              'TemperatureHistory',
            ),
          );
      _root = root;
      if (!await root.exists()) await root.create(recursive: true);

      final loaded = <TemperatureHistorySession>[];
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final metadata = File(p.join(entity.path, 'metadata.json'));
        if (!await metadata.exists()) continue;
        try {
          final json =
              jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
          var session = TemperatureHistorySession.fromJson(json);
          // 上一次进程未正常结束的活动会话在本次启动时自动归档。
          if (session.active) {
            session = session.copyWith(active: false);
            await _writeMetadata(session);
          }
          loaded.add(session);
        } catch (_) {
          // 单个损坏会话不会阻止其它历史记录加载。
        }
      }
      loaded.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      _sessions
        ..clear()
        ..addAll(loaded);
      _initialized = true;
    } catch (error) {
      _lastError = error.toString();
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 在写入新采样前检查是否应该切分会话。
  ///
  /// 返回 true 表示调用方应同步清空实时图表，下一条记录将成为新会话首条。
  bool prepareForSample({
    required DateTime timestamp,
    required String? deviceSerial,
  }) {
    final active = _activeSession;
    if (active == null) return false;
    final gap = timestamp.difference(active.endedAt);
    final deviceChanged =
        active.deviceSerial != null &&
        deviceSerial != null &&
        active.deviceSerial != deviceSerial;
    final shouldSplit =
        deviceChanged ||
        gap.isNegative ||
        gap > automaticGap ||
        timestamp.difference(active.startedAt) >= maximumSessionDuration ||
        active.sampleCount >= maximumSessionSamples;
    if (!shouldSplit) return false;
    _finalizeActiveSync();
    return true;
  }

  void appendSample(TemperatureSample sample, {required int sampleIntervalMs}) {
    if (!_initialized || _root == null) return;
    var active = _activeSession;
    if (active == null) {
      active = _createSessionForSample(sample, sampleIntervalMs);
      _activeSession = active;
      _sessions.insert(0, active);
      notifyListeners();
    }

    final updated = active.copyWith(
      endedAt: sample.timestamp,
      deviceSerial: active.deviceSerial ?? sample.deviceSerial,
      sampleIntervalMs: sampleIntervalMs,
      sampleCount: active.sampleCount + 1,
      maximum: active.sampleCount == 0
          ? sample.maximum
          : (sample.maximum > active.maximum ? sample.maximum : active.maximum),
      minimum: active.sampleCount == 0
          ? sample.minimum
          : (sample.minimum < active.minimum ? sample.minimum : active.minimum),
      averageSum: active.averageSum + sample.average,
      pointCountPeak: sample.pointReadings.length > active.pointCountPeak
          ? sample.pointReadings.length
          : active.pointCountPeak,
    );
    _activeSession = updated;
    _replaceSession(updated);

    _pendingSessionId ??= updated.id;
    if (_pendingSessionId != updated.id) {
      _flushPending();
      _pendingSessionId = updated.id;
    }
    _pendingLines.writeln(jsonEncode(sample.toJson()));
    _scheduleFlush();
  }

  Future<void> finishActiveSession() async {
    if (_activeSession == null) return;
    _finalizeActiveSync();
    await flush();
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushPending();
    await _writeQueue;
  }

  Future<List<TemperatureSample>> loadSamples(
    String sessionId, {
    DateTime? since,
    DateTime? until,
    int? maxSamples,
  }) async {
    final session = _sessionById(sessionId);
    if (session == null) return const [];
    if (_activeSession?.id == sessionId) await flush();
    final file = _samplesFile(sessionId);
    if (!await file.exists()) return const [];

    final samples = <TemperatureSample>[];
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        final sample = TemperatureSample.fromJson(
          jsonDecode(line) as Map<String, dynamic>,
        );
        if (since != null && sample.timestamp.isBefore(since)) continue;
        if (until != null && sample.timestamp.isAfter(until)) continue;
        samples.add(sample);
      } catch (_) {
        // 跳过单条损坏记录，保留其余可恢复数据。
      }
    }
    if (maxSamples != null && maxSamples > 1 && samples.length > maxSamples) {
      final lastIndex = samples.length - 1;
      return List<TemperatureSample>.generate(maxSamples, (index) {
        final source = (index * lastIndex / (maxSamples - 1)).round();
        return samples[source];
      }, growable: false);
    }
    return List.unmodifiable(samples);
  }

  Future<void> renameSession(String sessionId, String value) async {
    final clean = value.trim();
    if (clean.isEmpty) return;
    final current = _sessionById(sessionId);
    if (current == null) return;
    final renamed = current.copyWith(
      name: clean.length > 80 ? clean.substring(0, 80) : clean,
    );
    if (_activeSession?.id == sessionId) _activeSession = renamed;
    _replaceSession(renamed);
    notifyListeners();
    await _enqueue(() => _writeMetadata(renamed));
  }

  Future<void> deleteSession(String sessionId) async {
    final current = _sessionById(sessionId);
    if (current == null) return;
    if (_activeSession?.id == sessionId) {
      _finalizeActiveSync();
      await flush();
    }
    _sessions.removeWhere((session) => session.id == sessionId);
    notifyListeners();
    final directory = _sessionDirectory(sessionId);
    await _enqueue(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  }

  Future<void> deleteSessions(Iterable<String> sessionIds) async {
    final ids = sessionIds.toSet();
    final targets = _sessions
        .where((session) => ids.contains(session.id))
        .toList(growable: false);
    if (targets.isEmpty) return;

    if (targets.any((session) => session.id == _activeSession?.id)) {
      _finalizeActiveSync();
      await flush();
    }
    _sessions.removeWhere((session) => ids.contains(session.id));
    notifyListeners();
    await _enqueue(() async {
      for (final session in targets) {
        final directory = _sessionDirectory(session.id);
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
  }

  Future<TemperatureHistorySession> importJsonFile(String filePath) async {
    final source = File(filePath);
    return importJsonContent(
      await source.readAsString(),
      name: p.basenameWithoutExtension(source.path),
    );
  }

  Future<TemperatureHistorySession> importJsonContent(
    String contents, {
    required String name,
  }) async {
    final decoded = jsonDecode(contents);
    if (decoded is! Map) throw const FormatException('JSON 根节点必须是对象');
    final payload = Map<String, dynamic>.from(decoded);
    final rawSamples = payload['samples'];
    if (rawSamples is! List) {
      throw const FormatException('JSON 中没有 samples 数组');
    }
    final samples = <TemperatureSample>[
      for (final raw in rawSamples.whereType<Map>())
        TemperatureSample.fromJson(Map<String, dynamic>.from(raw)),
    ];
    if (samples.isEmpty) throw const FormatException('没有可导入的温度采样');
    return importSamples(samples, name: name);
  }

  Future<TemperatureHistorySession> importSamples(
    List<TemperatureSample> samples, {
    required String name,
  }) async {
    if (!_initialized) throw StateError('温度历史存储尚未初始化');
    if (samples.isEmpty) throw const FormatException('没有可导入的温度采样');
    final ordered = List<TemperatureSample>.from(samples)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final first = ordered.first;
    final last = ordered.last;
    var maximum = -double.infinity;
    var minimum = double.infinity;
    var averageSum = 0.0;
    var pointCountPeak = 0;
    for (final sample in ordered) {
      if (sample.maximum > maximum) maximum = sample.maximum;
      if (sample.minimum < minimum) minimum = sample.minimum;
      averageSum += sample.average;
      if (sample.pointReadings.length > pointCountPeak) {
        pointCountPeak = sample.pointReadings.length;
      }
    }
    final interval = ordered.length < 2
        ? 1000
        : ordered[1].timestamp
              .difference(ordered.first.timestamp)
              .inMilliseconds
              .clamp(100, 60000)
              .toInt();
    String? deviceSerial;
    for (final sample in ordered) {
      if (sample.deviceSerial != null && sample.deviceSerial!.isNotEmpty) {
        deviceSerial = sample.deviceSerial;
        break;
      }
    }
    final id = _newSessionId(first.timestamp);
    final session = TemperatureHistorySession(
      id: id,
      name: name.trim().isEmpty ? _defaultName(first.timestamp) : name.trim(),
      startedAt: first.timestamp,
      endedAt: last.timestamp,
      deviceSerial: deviceSerial,
      sampleIntervalMs: interval,
      sampleCount: ordered.length,
      maximum: maximum,
      minimum: minimum,
      averageSum: averageSum,
      pointCountPeak: pointCountPeak,
      active: false,
      imported: true,
    );
    final lines = StringBuffer();
    for (final sample in ordered) {
      lines.writeln(jsonEncode(sample.toJson()));
    }
    await _enqueue(() async {
      final directory = _sessionDirectory(id);
      await directory.create(recursive: true);
      await _samplesFile(id).writeAsString(lines.toString(), flush: true);
      await _writeMetadata(session);
    });
    _sessions.add(session);
    _sortSessions();
    notifyListeners();
    return session;
  }

  TemperatureHistorySession _createSessionForSample(
    TemperatureSample sample,
    int intervalMs,
  ) {
    return TemperatureHistorySession(
      id: _newSessionId(sample.timestamp),
      name: _defaultName(sample.timestamp),
      startedAt: sample.timestamp,
      endedAt: sample.timestamp,
      deviceSerial: sample.deviceSerial,
      sampleIntervalMs: intervalMs,
      sampleCount: 0,
      maximum: -double.infinity,
      minimum: double.infinity,
      averageSum: 0,
      pointCountPeak: 0,
      active: true,
    );
  }

  void _finalizeActiveSync() {
    final active = _activeSession;
    if (active == null) return;
    final finalized = active.copyWith(active: false);
    _activeSession = null;
    _replaceSession(finalized);
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushPending(metadataOverride: finalized);
    notifyListeners();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () {
      _flushTimer = null;
      _flushPending();
      notifyListeners();
    });
  }

  void _flushPending({TemperatureHistorySession? metadataOverride}) {
    final sessionId = _pendingSessionId;
    if (sessionId == null) {
      if (metadataOverride != null) {
        _enqueue(() => _writeMetadata(metadataOverride));
      }
      return;
    }
    final contents = _pendingLines.toString();
    final metadata =
        metadataOverride ?? _sessionById(sessionId) ?? _activeSession;
    _pendingSessionId = null;
    _pendingLines = StringBuffer();
    _enqueue(() async {
      final directory = _sessionDirectory(sessionId);
      await directory.create(recursive: true);
      if (contents.isNotEmpty) {
        await _samplesFile(
          sessionId,
        ).writeAsString(contents, mode: FileMode.append, flush: true);
      }
      if (metadata != null) await _writeMetadata(metadata);
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _writeQueue = _writeQueue.then((_) async {
      try {
        await action();
      } catch (error) {
        _lastError = error.toString();
        notifyListeners();
      }
    });
    return _writeQueue;
  }

  Future<void> _writeMetadata(TemperatureHistorySession session) async {
    final directory = _sessionDirectory(session.id);
    if (!await directory.exists()) await directory.create(recursive: true);
    await File(p.join(directory.path, 'metadata.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
      flush: true,
    );
  }

  Directory _sessionDirectory(String sessionId) {
    final root = _root;
    if (root == null) throw StateError('温度历史存储尚未初始化');
    return Directory(p.join(root.path, sessionId));
  }

  File _samplesFile(String sessionId) =>
      File(p.join(_sessionDirectory(sessionId).path, 'samples.jsonl'));

  TemperatureHistorySession? _sessionById(String id) {
    for (final session in _sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  void _replaceSession(TemperatureHistorySession session) {
    final index = _sessions.indexWhere((item) => item.id == session.id);
    if (index < 0) {
      _sessions.add(session);
    } else {
      _sessions[index] = session;
    }
    _sortSessions();
  }

  void _sortSessions() {
    _sessions.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  String _newSessionId(DateTime timestamp) {
    final base = '${timestamp.toUtc().microsecondsSinceEpoch}';
    var candidate = base;
    var suffix = 1;
    while (_sessionById(candidate) != null) {
      candidate = '${base}_${suffix++}';
    }
    return candidate;
  }

  static String _defaultName(DateTime timestamp) {
    final local = timestamp.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '测温 ${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}
