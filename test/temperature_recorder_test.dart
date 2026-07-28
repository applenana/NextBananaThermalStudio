import 'dart:convert';
import 'dart:typed_data';

import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/temperature/temperature_export_service.dart';
import 'package:banana_thermal/temperature/temperature_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const renderParams = RenderParams(
    upsampleScale: 1,
    upsampleMethod: UpsampleMethod.nearest,
    bilateralEnabled: false,
  );

  test('持续记录基础温度、固定单点、所有多点及多点平均值', () {
    final recorder = TemperatureRecorder(sampleInterval: Duration.zero);
    recorder.setSinglePoint(1, 0);
    recorder.addPoint(0, 0);
    recorder.addPoint(1, 1);

    final added = recorder.recordFrame(
      timestamp: DateTime.utc(2026, 7, 28, 10),
      deviceSerial: 'TEST-001',
      maximum: 40,
      minimum: 10,
      average: 25,
      thermalFrame: Float32List.fromList([10, 20, 30, 40]),
      srcWidth: 2,
      srcHeight: 2,
      renderParams: renderParams,
    );

    expect(added, isTrue);
    final sample = recorder.records.single;
    expect(sample.maximum, 40);
    expect(sample.minimum, 10);
    expect(sample.average, 25);
    expect(sample.singleTemperature, 20);
    expect(sample.pointReadings.map((reading) => reading.temperature), [
      10,
      40,
    ]);
    expect(sample.multiPointAverage, 25);
    expect(sample.deviceSerial, 'TEST-001');
  });

  test('默认采样间隔会跳过一秒内的额外帧', () {
    final recorder = TemperatureRecorder();
    final start = DateTime.utc(2026, 7, 28, 10);

    bool record(Duration offset) => recorder.recordFrame(
      timestamp: start.add(offset),
      deviceSerial: null,
      maximum: 30,
      minimum: 20,
      average: 25,
      thermalFrame: Float32List.fromList([25]),
      srcWidth: 1,
      srcHeight: 1,
      renderParams: renderParams,
    );

    expect(record(Duration.zero), isTrue);
    expect(record(const Duration(milliseconds: 999)), isFalse);
    expect(record(const Duration(seconds: 1)), isTrue);
    expect(recorder.recordCount, 2);
  });

  test('记录频率可以动态切换并从下一帧立即生效', () {
    final recorder = TemperatureRecorder();
    var notifications = 0;
    recorder.addListener(() => notifications++);
    recorder.setSampleInterval(const Duration(milliseconds: 200));

    expect(recorder.sampleInterval, const Duration(milliseconds: 200));
    expect(recorder.sampleIntervalLabel, '5 次/秒');
    expect(notifications, 1);

    final start = DateTime.utc(2026, 7, 28, 10);
    bool record(Duration offset) => recorder.recordFrame(
      timestamp: start.add(offset),
      deviceSerial: null,
      maximum: 30,
      minimum: 20,
      average: 25,
      thermalFrame: Float32List.fromList([25]),
      srcWidth: 1,
      srcHeight: 1,
      renderParams: renderParams,
    );
    expect(record(Duration.zero), isTrue);
    expect(record(const Duration(milliseconds: 199)), isFalse);
    expect(record(const Duration(milliseconds: 200)), isTrue);
  });

  test('CSV 和 JSON 导出包含测温点与结构化字段', () {
    final sample = TemperatureSample(
      sequence: 1,
      timestamp: DateTime.utc(2026, 7, 28, 10),
      deviceSerial: 'SN-A',
      maximum: 42.5,
      minimum: 18.25,
      average: 26.75,
      singleTemperature: 31.5,
      multiPointAverage: 29,
      pointReadings: const [
        TemperaturePointReading(id: 3, x: 12, y: 8, temperature: 29),
      ],
    );

    final csv = utf8.decode(
      TemperatureExportService.buildCsv([sample]).sublist(3),
    );
    expect(csv, contains('single_point_c'));
    expect(csv, contains('multi_point_average_c'));
    expect(csv, contains('point_3_x,point_3_y,point_3_c'));
    expect(csv, contains('SN-A'));

    final json =
        jsonDecode(utf8.decode(TemperatureExportService.buildJson([sample])))
            as Map<String, dynamic>;
    expect(json['version'], 1);
    expect(json['sample_count'], 1);
    final samples = json['samples'] as List<dynamic>;
    final first = samples.single as Map<String, dynamic>;
    expect(first['single_point_c'], 31.5);
    expect((first['points'] as List<dynamic>).single, isA<Map>());
  });
}
