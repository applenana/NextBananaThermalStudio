import 'dart:typed_data';

import 'package:banana_thermal/app_state.dart' show PhotoMeta;
import 'package:banana_thermal/protocol/photo_cache_index.dart';
import 'package:banana_thermal/protocol/photo_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const meta = PhotoMeta(
    index: 1,
    filename: 'photo_1.dat',
    size: 0,
    mode: 'full_screen',
    dataFormat: 'HTPH',
  );

  test('HTPH v3 解出照片自带的热像缩放和偏移', () {
    final raw = _buildHtph(
      version: 3,
      scale: 1.6,
      xOffset: -17,
      yOffset: 23,
      withVisible: true,
    );

    final decoded = PhotoDecoder.decode(raw, meta);

    expect(decoded.format, PhotoFormat.v2Htph);
    expect(decoded.thermal, hasLength(32 * 24));
    expect(decoded.thermal!.first, closeTo(23.0, 0.0001));
    expect(decoded.visibleRgb, isNotNull);
    expect(decoded.visW, 1);
    expect(decoded.visH, 2);
    expect(decoded.thermalView, isNotNull);
    expect(decoded.thermalView!.enabled, isTrue);
    expect(decoded.thermalView!.scale, closeTo(1.6, 0.0001));
    expect(decoded.thermalView!.xOffset, -17);
    expect(decoded.thermalView!.yOffset, 23);
  });

  test('HTPH v2 继续按旧布局解码且不伪造热像视图', () {
    final raw = _buildHtph(version: 2);

    final decoded = PhotoDecoder.decode(raw, meta);

    expect(decoded.format, PhotoFormat.v2Htph);
    expect(decoded.thermal, hasLength(32 * 24));
    expect(decoded.thermalView, isNull);
    expect(decoded.thermal!.first, closeTo(23.0, 0.0001));
    expect(decoded.thermal!.last, closeTo(0.0, 0.0001));
  });

  test('HTPH v3 主体保持 v2 布局供旧读取端忽略尾部', () {
    final raw = _buildHtph(
      version: 3,
      withVisible: true,
      scale: 1.8,
      xOffset: 12,
      yOffset: -9,
    );
    // 模拟只理解 v2 的读取端：它会忽略版本 3 的尾部扩展。
    raw[4] = 2;

    final decoded = PhotoDecoder.decode(raw, meta);

    expect(decoded.thermal!.first, closeTo(23.0, 0.0001));
    expect(decoded.visibleRgb, isNotNull);
    expect(decoded.thermalView, isNull);
  });

  test('HTPH v3 对损坏的视图参数做安全钳制', () {
    final raw = _buildHtph(version: 3, scale: 9.0, xOffset: -300, yOffset: 300);

    final decoded = PhotoDecoder.decode(raw, meta);

    expect(decoded.thermalView!.scale, 2.0);
    expect(decoded.thermalView!.xOffset, -100);
    expect(decoded.thermalView!.yOffset, 100);
  });

  test('HTPH v3 缓存指纹包含文件尾视图参数', () {
    Uint8List sample(int tail) {
      final bytes = Uint8List(5000);
      bytes.setRange(0, 4, 'HTPH'.codeUnits);
      bytes[4] = 3;
      bytes[bytes.length - 1] = tail;
      return bytes;
    }

    final a = sample(1);
    final b = sample(2);

    expect(PhotoCacheIndex.requiresCompleteFile(a), isTrue);
    expect(
      PhotoCacheIndex.fingerprint(a),
      isNot(PhotoCacheIndex.fingerprint(b)),
    );
  });
}

Uint8List _buildHtph({
  required int version,
  double scale = 1.0,
  int xOffset = 0,
  int yOffset = 0,
  bool withVisible = false,
}) {
  const thermalPoints = 32 * 24;
  final headerSize = withVisible ? 18 : 14;
  final visibleSize = withVisible ? 4 : 0;
  final footerSize = version >= 3 ? 8 : 0;
  final raw = Uint8List(
    headerSize + thermalPoints * 4 + visibleSize + footerSize,
  );
  raw.setRange(0, 4, 'HTPH'.codeUnits);
  raw[4] = version;
  raw[5] = withVisible ? 0x03 : 0x01;
  final bd = ByteData.sublistView(raw);
  bd.setFloat32(6, 42.0, Endian.little);
  bd.setFloat32(10, 0.0, Endian.little);
  if (withVisible) {
    bd.setUint16(14, 2, Endian.little);
    bd.setUint16(16, 1, Endian.little);
  }
  var cursor = headerSize;
  for (var i = 0; i < thermalPoints; i++) {
    // 解码器垂直翻转: 首个输出应来自原始最后一行的第一个值 23.
    bd.setFloat32(cursor + i * 4, (i ~/ 32).toDouble(), Endian.little);
  }
  cursor += thermalPoints * 4;
  if (withVisible) {
    bd.setUint16(cursor, 0xF800, Endian.little);
    bd.setUint16(cursor + 2, 0x07E0, Endian.little);
    cursor += visibleSize;
  }
  if (version >= 3) {
    bd.setFloat32(cursor, scale, Endian.little);
    bd.setInt16(cursor + 4, xOffset, Endian.little);
    bd.setInt16(cursor + 6, yOffset, Endian.little);
  }
  return raw;
}
