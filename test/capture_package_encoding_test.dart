import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:banana_thermal/storage/capture_package.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('capture-encoding-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  const place = '中国 浙江省 杭州市 西湖区 · Zürich 📍';
  const note = '中文备注：温度 36°C 🌡️';
  final values = Float32List.fromList([26.5, 37.25]);

  Future<String> createPackage(int type) async {
    final path = '${directory.path}/$type.btpkg';
    final writer = await CapturePackageWriter.create(
      path: path,
      type: type,
      meta: CaptureMeta(
        createdAt: DateTime.utc(2026, 11, 24),
        place: place,
        note: note,
        deviceSn: '设备-001',
        thermalW: 2,
        thermalH: 1,
        renderParams: const {'label': '中文参数'},
      ),
    );
    await writer.appendFrame(CaptureFrame(tsMs: 0, thermal: values));
    if (type == CapturePackageHeader.typeVideo) {
      await writer.appendFrame(CaptureFrame(tsMs: 33, thermal: values));
    }
    await writer.close();
    return path;
  }

  for (final type in [
    CapturePackageHeader.typePhoto,
    CapturePackageHeader.typeVideo,
  ]) {
    test(
      'package type $type reads UTF-8 metadata without changing the file',
      () async {
        final path = await createPackage(type);
        final before = await File(path).readAsBytes();
        final reader = await CapturePackageReader.open(path);
        expect(reader.meta.place, place);
        expect(reader.meta.note, note);
        expect(reader.meta.deviceSn, '设备-001');
        expect(reader.meta.renderParams, {'label': '中文参数'});
        expect(
          reader.frameCount,
          type == CapturePackageHeader.typePhoto ? 1 : 2,
        );
        expect((await reader.readFrame(reader.frameCount - 1)).thermal, values);
        expect(await File(path).readAsBytes(), before);
      },
    );
  }

  test(
    'repeated note edits preserve other UTF-8 metadata and frame bytes',
    () async {
      final path = await createPackage(CapturePackageHeader.typeVideo);
      final before = await File(path).readAsBytes();
      final metaLength = ByteData.sublistView(
        before,
      ).getUint32(8, Endian.little);
      final original =
          jsonDecode(utf8.decode(before.sublist(12, 12 + metaLength))) as Map;

      for (final newNote in ['新的中文备注 📝', '再次编辑 café', '']) {
        await CapturePackageReader.editNote(path, newNote);
        final after = await File(path).readAsBytes();
        final metadata =
            jsonDecode(utf8.decode(after.sublist(12, 12 + metaLength))) as Map;
        expect(metadata, {...original, 'note': newNote});
        expect(after.sublist(0, 12), before.sublist(0, 12));
        expect(after.sublist(12 + metaLength), before.sublist(12 + metaLength));
        final reader = await CapturePackageReader.open(path);
        expect(reader.meta.place, place);
        expect(reader.meta.note, newNote);
        expect((await reader.readFrame(1)).thermal, values);
      }
    },
  );
}
