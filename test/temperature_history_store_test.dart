import 'dart:convert';
import 'dart:io';

import 'package:banana_thermal/temperature/temperature_history_store.dart';
import 'package:banana_thermal/temperature/temperature_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

TemperatureSample _sample(
  int sequence,
  DateTime timestamp, {
  String? deviceSerial = 'DEVICE-A',
  double maximum = 40,
  double minimum = 20,
  double average = 30,
}) {
  return TemperatureSample(
    sequence: sequence,
    timestamp: timestamp,
    deviceSerial: deviceSerial,
    maximum: maximum,
    minimum: minimum,
    average: average,
    singleTemperature: 31,
    multiPointAverage: 29,
    pointReadings: const [
      TemperaturePointReading(id: 1, x: 4, y: 5, temperature: 29),
    ],
  );
}

void main() {
  late Directory root;
  late TemperatureHistoryStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('banana-history-test-');
    store = TemperatureHistoryStore(
      rootDirectory: root,
      flushDelay: Duration.zero,
    );
    await store.initialize();
  });

  tearDown(() async {
    await store.flush();
    store.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('会话追加、统计、归档并可由新实例重新加载', () async {
    final start = DateTime.utc(2026, 7, 29, 8);
    store.appendSample(_sample(1, start), sampleIntervalMs: 1000);
    store.appendSample(
      _sample(
        2,
        start.add(const Duration(seconds: 1)),
        maximum: 45,
        minimum: 18,
        average: 32,
      ),
      sampleIntervalMs: 1000,
    );
    await store.finishActiveSession();

    expect(store.sessions, hasLength(1));
    final session = store.sessions.single;
    expect(session.active, isFalse);
    expect(session.sampleCount, 2);
    expect(session.maximum, 45);
    expect(session.minimum, 18);
    expect(session.average, 31);
    expect(session.pointCountPeak, 1);

    final reloaded = TemperatureHistoryStore(rootDirectory: root);
    await reloaded.initialize();
    addTearDown(reloaded.dispose);
    expect(reloaded.sessions.single.id, session.id);
    final samples = await reloaded.loadSamples(session.id);
    expect(samples, hasLength(2));
    expect(samples.last.maximum, 45);
    expect(samples.last.pointReadings.single.temperature, 29);
  });

  test('断流超过三十秒会自动切分会话', () async {
    final start = DateTime.utc(2026, 7, 29, 9);
    store.appendSample(_sample(1, start), sampleIntervalMs: 1000);
    expect(
      store.prepareForSample(
        timestamp: start.add(const Duration(seconds: 31)),
        deviceSerial: 'DEVICE-A',
      ),
      isTrue,
    );
    store.appendSample(
      _sample(1, start.add(const Duration(seconds: 31))),
      sampleIntervalMs: 1000,
    );
    await store.finishActiveSession();

    expect(store.sessions, hasLength(2));
    expect(store.sessions.every((session) => !session.active), isTrue);
    expect(store.sessions.map((session) => session.sampleCount), [1, 1]);
  });

  test('支持重命名、删除与导入现有 JSON 导出', () async {
    final start = DateTime.utc(2026, 7, 29, 10);
    final payload = jsonEncode({
      'format': 'banana_thermal_temperature_log',
      'version': 1,
      'samples': [
        _sample(1, start).toJson(),
        _sample(2, start.add(const Duration(seconds: 2))).toJson(),
      ],
    });
    final imported = await store.importJsonContent(payload, name: '实验室导入');
    expect(imported.imported, isTrue);
    expect(imported.sampleCount, 2);

    await store.renameSession(imported.id, '夜间稳定性测试');
    expect(store.sessions.single.name, '夜间稳定性测试');
    expect(await store.loadSamples(imported.id), hasLength(2));

    await store.deleteSession(imported.id);
    expect(store.sessions, isEmpty);
    expect(
      Directory(
        '${root.path}${Platform.pathSeparator}${imported.id}',
      ).existsSync(),
      isFalse,
    );
  });

  test('支持批量删除历史会话及其本地目录', () async {
    final start = DateTime.utc(2026, 7, 29, 11);
    for (var index = 0; index < 3; index++) {
      store.appendSample(
        _sample(1, start.add(Duration(minutes: index))),
        sampleIntervalMs: 1000,
      );
      if (index < 2) await store.finishActiveSession();
    }

    final sessions = store.sessions;
    expect(sessions.first.active, isTrue);
    final deletedIds = [sessions[0].id, sessions[2].id];
    await store.deleteSessions(deletedIds);

    expect(store.activeSession, isNull);
    expect(store.sessions, hasLength(1));
    expect(store.sessions.single.id, sessions[1].id);
    for (final id in deletedIds) {
      expect(
        Directory('${root.path}${Platform.pathSeparator}$id').existsSync(),
        isFalse,
      );
    }
  });
}
