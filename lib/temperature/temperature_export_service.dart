/// 温度记录导出：CSV / JSON 数据编码与跨平台文件保存。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';

import 'temperature_recorder.dart';

class TemperatureExportService {
  const TemperatureExportService._();

  static String timestampedBaseName([DateTime? now]) {
    final t = (now ?? DateTime.now()).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'temperature_${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static Uint8List buildCsv(List<TemperatureSample> samples) {
    final pointIds = <int>{};
    for (final sample in samples) {
      for (final reading in sample.pointReadings) {
        pointIds.add(reading.id);
      }
    }
    final sortedPointIds = pointIds.toList()..sort();
    final header = <String>[
      'sequence',
      'timestamp',
      'elapsed_ms',
      'device_serial',
      'maximum_c',
      'minimum_c',
      'average_c',
      'single_point_c',
      'multi_point_average_c',
      for (final id in sortedPointIds) ...[
        'point_${id}_x',
        'point_${id}_y',
        'point_${id}_c',
      ],
    ];
    final rows = <String>[header.map(_csvCell).join(',')];
    final start = samples.isEmpty ? null : samples.first.timestamp;
    for (final sample in samples) {
      final byId = {
        for (final reading in sample.pointReadings) reading.id: reading,
      };
      final values = <Object?>[
        sample.sequence,
        sample.timestamp.toIso8601String(),
        start == null ? 0 : sample.timestamp.difference(start).inMilliseconds,
        sample.deviceSerial,
        sample.maximum,
        sample.minimum,
        sample.average,
        sample.singleTemperature,
        sample.multiPointAverage,
        for (final id in sortedPointIds) ...[
          byId[id]?.x,
          byId[id]?.y,
          byId[id]?.temperature,
        ],
      ];
      rows.add(values.map(_csvCell).join(','));
    }
    // UTF-8 BOM 让 Windows Excel 能直接识别中文和 UTF-8。
    return Uint8List.fromList([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(rows.join('\r\n')),
    ]);
  }

  static Uint8List buildJson(List<TemperatureSample> samples) {
    final payload = {
      'format': 'banana_thermal_temperature_log',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'sample_count': samples.length,
      'samples': [for (final sample in samples) sample.toJson()],
    };
    return Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
    );
  }

  static String _csvCell(Object? value) {
    if (value == null) return '';
    final text = value is double ? value.toStringAsFixed(4) : value.toString();
    if (!text.contains(',') &&
        !text.contains('"') &&
        !text.contains('\n') &&
        !text.contains('\r')) {
      return text;
    }
    return '"${text.replaceAll('"', '""')}"';
  }

  /// 桌面端弹出保存路径后写文件；移动端把字节交给系统文件选择器保存。
  static Future<String?> saveBytes({
    required Uint8List bytes,
    required String fileName,
    required String extension,
    String? initialDirectory,
  }) async {
    final mobile = Platform.isAndroid || Platform.isIOS;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出温度数据',
      fileName: fileName,
      initialDirectory: initialDirectory,
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: mobile ? bytes : null,
      lockParentWindow: Platform.isWindows,
    );
    if (path == null || path.isEmpty) return null;
    if (!mobile) await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Android/iOS 图片直接进入系统相册；桌面端使用普通保存对话框。
  static Future<String?> savePng({
    required Uint8List bytes,
    required String fileName,
    String? initialDirectory,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      var hasAccess = await Gal.hasAccess();
      if (!hasAccess) hasAccess = await Gal.requestAccess();
      if (!hasAccess) throw StateError('没有系统相册写入权限');
      final name = fileName.endsWith('.png')
          ? fileName.substring(0, fileName.length - 4)
          : fileName;
      await Gal.putImageBytes(bytes, album: 'BananaThermal', name: name);
      return '系统相册/BananaThermal/$fileName';
    }
    return saveBytes(
      bytes: bytes,
      fileName: fileName,
      extension: 'png',
      initialDirectory: initialDirectory,
    );
  }
}
