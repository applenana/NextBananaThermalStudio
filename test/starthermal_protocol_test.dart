import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/starthermal/protocol.dart';
import 'package:banana_thermal/starthermal/client.dart';
import 'package:banana_thermal/starthermal/cache.dart';

Uint8List response(
  String api,
  dynamic json, [
  List<int> binary = const [],
  int session = 7,
  bool ok = true,
]) {
  final j = utf8.encode(jsonEncode(json));
  final body = [...j, ...binary];
  return Uint8List.fromList([
    ...utf8.encode(
      '\r\n${jsonEncode({'api': api, 'ok': ok, 'jsonLength': j.length, 'binaryLength': binary.length, 'crc32': crcHex(body), 'sessionId': session, 'bootId': 3})}\r\n',
    ),
    ...body,
  ]);
}

Uint8List frame(Uint8List payload, Uint8List decoded) {
  final checksum = ByteData(4)..setUint32(0, crc32(decoded), Endian.little);
  return Uint8List.fromList([
    ...ascii.encode('Y16F'),
    payload.length & 255,
    payload.length >> 8,
    ...payload,
    ...checksum.buffer.asUint8List(),
  ]);
}

void main() {
  test('standard CRC32 vector', () {
    expect(crcHex(ascii.encode('123456789')), 'CBF43926');
  });
  test('v2 exact framing handles arbitrary binary and every byte boundary', () {
    final binary = Uint8List.fromList([
      ...ascii.encode('\nY16F\n{"api":"GetSysInfo"}\r\n'),
      0,
      255,
    ]);
    final bytes = response('GetPicWithID', {'id': '00000001'}, binary);
    final parser = ResponseParser();
    DeviceResponse? received;
    for (final byte in bytes) {
      parser.add([byte]);
      received ??= parser.next();
    }
    expect(received!.object['id'], '00000001');
    expect(received.binary, binary);
    parser.add(response('GetPicList', []));
    expect(parser.next()!.json, isEmpty);
  });
  test(
    'v2 probe accepts no newline after sysinfo body; legacy still works',
    () {
      final p = IdentityProbe();
      expect(
        p.add(
          response('GetSysInfo', {
            'deviceModel': 'StarThermal',
            'protocolVersion': 2,
          }),
        ),
        containsPair('deviceModel', 'StarThermal'),
      );
      expect(
        IdentityProbe().add(
          Uint8List.fromList(
            ascii.encode('{"SerialNum":"old","isActivated":true}\n'),
          ),
        ),
        containsPair('SerialNum', 'old'),
      );
    },
  );
  test('truncated response waits and corrupt response fails', () {
    final p = ResponseParser();
    final b = response('GetPicList', []);
    p.add(b.sublist(0, b.length - 1));
    expect(p.next(), isNull);
    p.add([0]);
    expect(p.next, throwsFormatException);
  });
  test('BP64 constant, signed extrema/raw fallback, invalid tags', () {
    final payload = Uint8List.fromList(
      List.generate(169, (_) => [0, 0, 128]).expand((v) => v).toList(),
    );
    final decoded = decodeBp64(payload);
    expect(ByteData.sublistView(decoded).getInt16(0, Endian.little), -32768);
    final raw = ByteData(21600);
    for (var i = 0; i < 10800; i++) {
      raw.setInt16(i * 2, i.isEven ? -32768 : 32767, Endian.little);
    }
    final blocks = <int>[];
    for (var i = 0; i < 10800; i += 64) {
      blocks.add(16);
      blocks.addAll(
        raw.buffer.asUint8List().sublist(i * 2, (i + 64).clamp(0, 10800) * 2),
      );
    }
    expect(decodeBp64(Uint8List.fromList(blocks)), raw.buffer.asUint8List());
    expect(() => decodeBp64(Uint8List.fromList([17])), throwsFormatException);
    expect(
      () => decodeBp64(Uint8List.fromList([...payload, 0])),
      throwsFormatException,
    );
  });
  test('BP64 packed deltas cross byte boundaries and last partial block', () {
    for (var width = 1; width <= 15; width++) {
      final encoded = <int>[];
      final expected = ByteData(21600);
      var index = 0;
      while (index < 10800) {
        final count = (10800 - index).clamp(0, 64);
        encoded.addAll([width, 0, 128]);
        var bits = 0, n = 0;
        for (var i = 0; i < count; i++) {
          final delta = (i * 997) & ((1 << width) - 1);
          expected.setInt16(index++ * 2, -32768 + delta, Endian.little);
          bits |= delta << n;
          n += width;
          while (n >= 8) {
            encoded.add(bits & 255);
            bits >>>= 8;
            n -= 8;
          }
        }
        if (n > 0) encoded.add(bits);
      }
      expect(
        decodeBp64(Uint8List.fromList(encoded)),
        expected.buffer.asUint8List(),
      );
    }
  });
  test('Y16 resynchronizes after corrupt frame and embedded magic', () {
    final y = Uint8List(21600);
    y.setRange(50, 54, ascii.encode('Y16F'));
    final valid = frame(y, y), corrupt = Uint8List.fromList(valid);
    corrupt[10] ^= 1;
    final p = Y16Parser('RAW16');
    Uint8List? received;
    final all = Uint8List.fromList([...corrupt, ...valid]);
    for (var at = 0; at < all.length; at += 71) {
      received =
          p.add(
            Uint8List.sublistView(all, at, (at + 71).clamp(0, all.length)),
          ) ??
          received;
    }
    expect(received, y);
    expect(p.frames, 1);
    expect(p.errors, greaterThan(0));
  });
  test(
    'start ACK and first frame in one chunk are routed without loss',
    () async {
      final stream = <int>[];
      late StarThermalClient c;
      c = StarThermalClient(
        baud: 2000000,
        setHostBaud: (_) async {},
        onStream: stream.addAll,
        write: (s) async {
          c.feed(
            Uint8List.fromList([
              ...response('StartY16Stream', {'active': true}),
              1,
              2,
              3,
            ]),
          );
        },
      );
      await c.once('StartY16Stream BP64');
      expect(stream, [1, 2, 3]);
      c.close();
    },
  );
  test('changed session aborts deletion without retry', () async {
    var requests = 0;
    late StarThermalClient c;
    c = StarThermalClient(
      baud: 2000000,
      setHostBaud: (_) async {},
      onStream: (_) {},
      write: (s) async {
        requests++;
        c.feed(
          response(
            'DeletePicWithID',
            {'id': '00000001', 'deleted': true},
            [],
            8,
          ),
        );
      },
    );
    c.sessionId = 7;
    c.bootId = 3;
    await expectLater(
      c.request('DeletePicWithID 00000001'),
      throwsA(isA<SessionChanged>()),
    );
    expect(requests, 1);
    c.close();
  });
  test('curve content mutation invalidates same-SN cached collection', () {
    final data = ByteData(2402);
    for (var d = 0; d < 2; d++) {
      for (var i = 0; i < 600; i++) {
        data.setUint16(d * 1200 + i * 2, i, Endian.little);
      }
    }
    final blob = data.buffer.asUint8List();
    final crc = crcHex(blob);
    final meta = {
      'schema_version': 1,
      'node_count': 1,
      'points_per_curve': 600,
      'distance_count': 2,
      'encoding': 'u16le',
      'layout': 'node-near-far-then-i16le-knots',
      'crc32': crc,
      'nodes': [
        {'index': 0, 'knot_centi_c': 0, 'near_valid': true, 'far_valid': true},
      ],
    };
    validateCurves(meta, blob, crc);
    blob[10] ^= 1;
    expect(() => validateCurves(meta, blob, crc), throwsFormatException);
  });
}
