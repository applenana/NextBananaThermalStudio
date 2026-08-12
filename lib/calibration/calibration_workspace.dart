import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../protocol/temperature_calibration.dart';
import '../temperature/temperature_export_service.dart';
import 'piecewise_calibration_fit.dart';

class CalibrationDraft {
  final String deviceSerial;
  final int? baselineCrc32;
  final List<CalibrationSample> samples;
  final CalibrationFitOptions options;
  final CalibrationCurve? fittedCurve;
  final DateTime updatedAt;

  const CalibrationDraft({
    required this.deviceSerial,
    required this.baselineCrc32,
    required this.samples,
    required this.options,
    required this.fittedCurve,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'format': 'banana_thermal_calibration_draft',
    'version': 2,
    'device_serial': deviceSerial,
    'baseline_crc32': baselineCrc32,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'options': options.toJson(),
    'fitted_curve': fittedCurve?.toJson(),
    'samples': samples
        .map(
          (sample) => {
            'measured_c': sample.measured,
            'reference_c': sample.reference,
            'raw_input_c': sample.rawInput,
            'standard_deviation_c': sample.standardDeviation,
            'frame_count': sample.frameCount,
          },
        )
        .toList(),
  };

  static CalibrationDraft? tryParse(Object? value) {
    if (value is! Map ||
        value['format'] != 'banana_thermal_calibration_draft') {
      return null;
    }
    final serial = value['device_serial']?.toString();
    final values = value['samples'];
    if (serial == null || values is! List) return null;
    final samples = <CalibrationSample>[];
    for (final item in values) {
      if (item is! Map) return null;
      final measured = (item['measured_c'] as num?)?.toDouble();
      final reference = (item['reference_c'] as num?)?.toDouble();
      if (measured == null || reference == null) return null;
      samples.add(
        CalibrationSample(
          measured: measured,
          reference: reference,
          rawInput: (item['raw_input_c'] as num?)?.toDouble(),
          standardDeviation:
              (item['standard_deviation_c'] as num?)?.toDouble() ?? 0,
          frameCount: (item['frame_count'] as num?)?.toInt() ?? 1,
        ),
      );
    }
    return CalibrationDraft(
      deviceSerial: serial,
      baselineCrc32: (value['baseline_crc32'] as num?)?.toInt(),
      samples: samples,
      options: CalibrationFitOptions.fromJson(value['options']),
      fittedCurve: CalibrationCurve.tryParseJson(value['fitted_curve']),
      updatedAt:
          DateTime.tryParse(value['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class CalibrationDraftStore {
  const CalibrationDraftStore();

  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(p.join(root.path, 'calibration_drafts'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  String _safeSerial(String serial) =>
      serial.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<File> _file(String serial) async =>
      File(p.join((await _directory()).path, '${_safeSerial(serial)}.json'));

  Future<CalibrationDraft?> load(String serial) async {
    final file = await _file(serial);
    final candidates = [
      file,
      File('${file.path}.next'),
      File('${file.path}.bak'),
    ];
    CalibrationDraft? newest;
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      try {
        final draft = CalibrationDraft.tryParse(
          jsonDecode(await candidate.readAsString()),
        );
        if (draft != null &&
            (newest == null || draft.updatedAt.isAfter(newest.updatedAt))) {
          newest = draft;
        }
      } catch (_) {
        // A partial temporary file is ignored; another slot can still recover
        // the last complete per-device draft.
      }
    }
    return newest;
  }

  Future<void> save(CalibrationDraft draft) async {
    final file = await _file(draft.deviceSerial);
    final next = File('${file.path}.next');
    final backup = File('${file.path}.bak');
    await next.writeAsString(
      const JsonEncoder.withIndent('  ').convert(draft.toJson()),
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await next.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }
}

class CalibrationCsvImport {
  final List<CalibrationSample> samples;
  final Set<String> deviceSerials;
  final Set<int> baselineCrcs;

  const CalibrationCsvImport({
    required this.samples,
    required this.deviceSerials,
    required this.baselineCrcs,
  });
}

class CalibrationCsvService {
  const CalibrationCsvService._();

  static Future<CalibrationCsvImport?> pickAndRead() async {
    final result = await FilePicker.platform.pickFiles(
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : const ['csv'],
      withData: Platform.isAndroid,
    );
    if (result == null) return null;
    final picked = result.files.single;
    Uint8List? bytes = picked.bytes;
    if (bytes == null && picked.path != null) {
      bytes = await File(picked.path!).readAsBytes();
    }
    if (bytes == null) throw StateError('文件选择器未返回可读取的 CSV 数据');
    final text = utf8.decode(bytes, allowMalformed: false);
    return Isolate.run(() => parse(text));
  }

  static CalibrationCsvImport parse(String text) {
    final rows = _parseRows(text.replaceFirst('\ufeff', ''));
    if (rows.isEmpty) throw const FormatException('CSV 为空');
    final header = rows.first.map((cell) => cell.trim().toLowerCase()).toList();
    final measuredIndex = header.indexOf('measured_c');
    final referenceIndex = header.indexOf('reference_c');
    if (measuredIndex < 0 || referenceIndex < 0) {
      throw const FormatException('CSV 必须包含 measured_c 和 reference_c 列');
    }
    int column(String name) => header.indexOf(name);
    final rawIndex = column('raw_input_c');
    final deviationIndex = column('standard_deviation_c');
    final countIndex = column('frame_count');
    final serialIndex = column('device_sn');
    final crcIndex = column('baseline_crc');
    final samples = <CalibrationSample>[];
    final serials = <String>{};
    final crcs = <int>{};
    for (var rowIndex = 1; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      String value(int index) =>
          index < 0 || index >= row.length ? '' : row[index].trim();
      if (row.every((cell) => cell.trim().isEmpty)) continue;
      final measured = double.tryParse(value(measuredIndex));
      final reference = double.tryParse(value(referenceIndex));
      if (measured == null ||
          reference == null ||
          !measured.isFinite ||
          !reference.isFinite) {
        throw FormatException('CSV 第 ${rowIndex + 1} 行温度不是有效数字');
      }
      final rawText = value(rawIndex);
      final deviationText = value(deviationIndex);
      final countText = value(countIndex);
      final raw = rawText.isEmpty ? null : double.tryParse(rawText);
      final deviation = deviationText.isEmpty
          ? 0.0
          : double.tryParse(deviationText);
      final frameCount = countText.isEmpty ? 1 : int.tryParse(countText);
      if ((rawText.isNotEmpty && (raw == null || !raw.isFinite)) ||
          deviation == null ||
          !deviation.isFinite ||
          deviation < 0 ||
          frameCount == null ||
          frameCount < 1) {
        throw FormatException('CSV 第 ${rowIndex + 1} 行可选采样参数无效');
      }
      samples.add(
        CalibrationSample(
          measured: measured,
          reference: reference,
          rawInput: raw,
          standardDeviation: deviation,
          frameCount: frameCount,
        ),
      );
      final serial = value(serialIndex);
      if (serial.isNotEmpty) serials.add(serial);
      final crcText = value(crcIndex);
      final crc = int.tryParse(crcText);
      if (crcText.isNotEmpty && (crc == null || crc < 0 || crc > 0xffffffff)) {
        throw FormatException('CSV 第 ${rowIndex + 1} 行 baseline_crc 无效');
      }
      if (crc != null) crcs.add(crc);
    }
    if (samples.isEmpty) throw const FormatException('CSV 没有有效校准数据');
    return CalibrationCsvImport(
      samples: samples,
      deviceSerials: serials,
      baselineCrcs: crcs,
    );
  }

  static Future<String?> export({
    required List<CalibrationSample> samples,
    required String deviceSerial,
    required int? baselineCrc,
  }) {
    final rows = <String>[
      'measured_c,reference_c,raw_input_c,standard_deviation_c,frame_count,device_sn,baseline_crc',
      for (final sample in samples)
        [
          sample.measured.toStringAsFixed(4),
          sample.reference.toStringAsFixed(4),
          sample.rawInput?.toStringAsFixed(4) ?? '',
          sample.standardDeviation.toStringAsFixed(4),
          sample.frameCount,
          _csvCell(deviceSerial),
          baselineCrc ?? '',
        ].join(','),
    ];
    final bytes = Uint8List.fromList([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(rows.join('\r\n')),
    ]);
    return TemperatureExportService.saveBytes(
      bytes: bytes,
      fileName:
          'temperature_calibration_${DateTime.now().millisecondsSinceEpoch}.csv',
      extension: 'csv',
    );
  }

  static String _csvCell(String value) => value.contains(RegExp('[,"\\r\\n]'))
      ? '"${value.replaceAll('"', '""')}"'
      : value;

  static List<List<String>> _parseRows(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final character = text[i];
      if (quoted) {
        if (character == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(character);
        }
      } else if (character == '"') {
        quoted = true;
      } else if (character == ',') {
        row.add(cell.toString());
        cell.clear();
      } else if (character == '\n' || character == '\r') {
        if (character == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
          i++;
        }
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
      } else {
        cell.write(character);
      }
    }
    if (quoted) throw const FormatException('CSV 引号未闭合');
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows;
  }
}

class CalibrationFitTask {
  Isolate? _isolate;
  ReceivePort? _port;
  Completer<PiecewiseCalibrationFit?>? _completer;

  Future<PiecewiseCalibrationFit?> start({
    required CalibrationCurve currentCurve,
    required List<CalibrationSample> samples,
    required CalibrationFitOptions options,
  }) async {
    cancel();
    final port = ReceivePort();
    final completer = Completer<PiecewiseCalibrationFit?>();
    _port = port;
    _completer = completer;
    _isolate = await Isolate.spawn(_fitEntry, (
      port.sendPort,
      currentCurve,
      samples,
      options,
    ));
    port.listen((message) {
      if (!completer.isCompleted) {
        if (message is _FitFailure) {
          completer.completeError(StateError(message.message));
        } else {
          completer.complete(message as PiecewiseCalibrationFit?);
        }
      }
      _disposePort();
    });
    return completer.future;
  }

  void cancel() {
    _isolate?.kill(priority: Isolate.immediate);
    if (_completer != null && !_completer!.isCompleted) {
      _completer!.complete(null);
    }
    _disposePort();
  }

  void _disposePort() {
    _isolate = null;
    _port?.close();
    _port = null;
    _completer = null;
  }
}

class _FitFailure {
  final String message;
  const _FitFailure(this.message);
}

void _fitEntry(
  (SendPort, CalibrationCurve, List<CalibrationSample>, CalibrationFitOptions)
  message,
) {
  try {
    message.$1.send(
      fitPiecewiseTemperatureCalibration(
        currentCurve: message.$2,
        samples: message.$3,
        options: message.$4,
      ),
    );
  } catch (error, stack) {
    message.$1.send(_FitFailure('$error\n$stack'));
  }
}
