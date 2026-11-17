import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/cb360/protocol.dart';
import 'package:banana_thermal/cb360/restore.dart';
import 'package:banana_thermal/cb360/temperature_context.dart';
import 'package:banana_thermal/storage/capture_package.dart';

Map<String, dynamic> snapshot({
  int fpa = 0,
  int manual = 0,
  bool farValid = true,
  String serial = 'test',
}) {
  final data = ByteData(4804);
  for (var node = 0; node < 2; node++) {
    for (var d = 0; d < 2; d++) {
      for (var i = 0; i < 600; i++) {
        data.setUint16(
          node * 2400 + d * 1200 + i * 2,
          d == 1 && !farValid ? 0 : node * 1000 + i,
          Endian.little,
        );
      }
    }
    data.setInt16(4800 + node * 2, node * 1000, Endian.little);
  }
  final blob = data.buffer.asUint8List();
  return {
    'device': {
      'thermalModuleSerialNumber': serial,
      'curvesCrc32': crcHex(blob),
    },
    'curves': {
      'node_count': 2,
      'schema_version': 1,
      'points_per_curve': 600,
      'distance_count': 2,
      'encoding': 'u16le',
      'layout': 'node-near-far-then-i16le-knots',
      'crc32': crcHex(blob),
      'nodes': List.generate(
        2,
        (i) => {
          'index': i,
          'knot_centi_c': i * 1000,
          'near_valid': true,
          'far_valid': farValid,
        },
      ),
    },
    'curves_binary': base64Encode(blob),
    'settings': {'temperature_curve_selection': manual, 'distance_mode': 'far'},
    'parameters': {'fpa_centi_c': fpa},
  };
}

void main() {
  test(
    'live curves obey manual selection, FPA knots, hysteresis and device changes',
    () {
      final selection = LiveCurveSelection();
      expect(selection.select(snapshot(fpa: 450)).index, 0);
      expect(selection.select(snapshot(fpa: 510)).index, 0);
      expect(selection.select(snapshot(fpa: 530)).index, 1);
      expect(selection.select(snapshot(fpa: 490)).index, 1);
      expect(selection.select(snapshot(fpa: 490, serial: 'other')).index, 0);
      expect(selection.select(snapshot(fpa: 0, manual: 2)).index, 1);
      expect(selection.select(snapshot(fpa: 0)).index, 0);
    },
  );
  test('unavailable far curve falls back to near with near parameter slot', () {
    final choice = LiveCurveSelection().select(snapshot(farValid: false));
    expect(choice.context['settings']['distance_mode'], 'near');
    expect(ByteData.sublistView(choice.curve).getUint16(2, Endian.little), 1);
  });
  test(
    'whole temperature frame preserves row order and signed Y16, without NUC',
    () {
      final lut = Int16List(65536);
      for (var i = 0; i < lut.length; i++) {
        lut[i] = (i - 32768) ~/ 2;
      }
      final pixels = ByteData(21600);
      pixels.setInt16(0, -32768, Endian.little);
      pixels.setInt16(2, 32767, Endian.little);
      pixels.setInt16(120 * 2, 2468, Endian.little);
      pixels.setInt16(21598, -2000, Endian.little);
      final temperatures = convertY16Temperatures(
        pixels.buffer.asUint8List(),
        lut,
      );
      expect(temperatures.length, 10800);
      expect(temperatures[0], closeTo(-163.84, 0.00001));
      expect(temperatures[1], closeTo(163.83, 0.00001));
      expect(temperatures[120], closeTo(12.34, 0.00001));
      expect(temperatures.last, -10);
    },
  );
  test(
    'software photo and video packages retain 120x90 temperature data',
    () async {
      final directory = await Directory.systemTemp.createTemp('cb360-capture-');
      try {
        for (final type in [
          CapturePackageHeader.typePhoto,
          CapturePackageHeader.typeVideo,
        ]) {
          final path = '${directory.path}/$type.btpkg';
          final writer = await CapturePackageWriter.create(
            path: path,
            type: type,
            meta: CaptureMeta(
              createdAt: DateTime.utc(2026),
              deviceSn: 'CB360-test',
              thermalW: 120,
              thermalH: 90,
            ),
          );
          final values = Float32List.fromList(
            List.generate(10800, (i) => i / 100),
          );
          await writer.appendFrame(CaptureFrame(tsMs: 0, thermal: values));
          if (type == CapturePackageHeader.typeVideo)
            await writer.appendFrame(CaptureFrame(tsMs: 100, thermal: values));
          await expectLater(
            writer.appendFrame(
              CaptureFrame(tsMs: 200, thermal: Float32List(768)),
            ),
            throwsArgumentError,
          );
          await writer.close();
          final reader = await CapturePackageReader.open(path);
          expect(reader.meta.thermalW, 120);
          expect(reader.meta.thermalH, 90);
          expect((await reader.readFrame(0)).thermal, values);
          if (type == CapturePackageHeader.typeVideo)
            expect((await reader.readFrame(1)).thermal, values);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
