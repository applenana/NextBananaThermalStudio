import 'dart:convert';
import 'dart:typed_data';

final _crcTable = List<int>.generate(256, (i) {
  var c = i;
  for (var n = 0; n < 8; n++) {
    c = (c & 1) != 0 ? (c >>> 1) ^ 0xedb88320 : c >>> 1;
  }
  return c;
});
int crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

String crcHex(List<int> bytes) =>
    crc32(bytes).toRadixString(16).padLeft(8, '0').toUpperCase();

class DeviceResponse {
  final Map<String, dynamic> header;
  final dynamic json;
  final Uint8List binary;
  DeviceResponse(this.header, this.json, this.binary);
  Map<String, dynamic> get object => (json as Map).cast<String, dynamic>();
}

/// Length framing only. Never interpret a binary body as lines or JSON.
class ResponseParser {
  final List<int> _bytes = [];
  Map<String, dynamic>? _header;
  void add(List<int> data) {
    _bytes.addAll(data);
    if (_bytes.length > 2 * 1024 * 1024) {
      reset();
      throw const FormatException('响应超过接收上限');
    }
  }

  void reset() {
    _bytes.clear();
    _header = null;
  }

  Uint8List takeRemaining() {
    final result = Uint8List.fromList(_bytes);
    reset();
    return result;
  }

  DeviceResponse? next() {
    while (_header == null) {
      final end = _bytes.indexOf(10);
      if (end < 0) return null;
      final line = utf8
          .decode(_bytes.sublist(0, end), allowMalformed: true)
          .trim();
      _bytes.removeRange(0, end + 1);
      dynamic h;
      try {
        h = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (h is! Map || h['api'] is! String) continue;
      final j = h['jsonLength'], b = h['binaryLength'];
      if (j is! int || b is! int || j < 0 || b < 0 || j + b > 1024 * 1024) {
        throw const FormatException('无效响应长度');
      }
      _header = h.cast<String, dynamic>();
    }
    final h = _header!;
    final j = h['jsonLength'] as int, b = h['binaryLength'] as int;
    if (_bytes.length < j + b) return null;
    final body = Uint8List.fromList(_bytes.sublist(0, j + b));
    _bytes.removeRange(0, j + b);
    _header = null;
    if (crcHex(body) != h['crc32']) throw const FormatException('响应 CRC32 错误');
    return DeviceResponse(
      h,
      j == 0 ? null : jsonDecode(utf8.decode(body.sublist(0, j))),
      Uint8List.sublistView(body, j),
    );
  }
}

// Historical wire identity is accepted only for migration from installed firmware.
final legacyStarThermalModel = String.fromCharCodes([67, 66, 51, 54, 48]);
String publicStarThermalText(String text) => text.replaceAll(
  RegExp(legacyStarThermalModel, caseSensitive: false),
  'StarThermal',
);
bool isStarThermalInfo(Map<String, dynamic> info) =>
    (info['deviceModel'] == 'StarThermal' ||
        info['deviceModel'] == legacyStarThermalModel) &&
    info['protocolVersion'] == 2;

/// Used by both desktop and Android probes; v2 body need not end in newline.
class IdentityProbe {
  final ResponseParser _v2 = ResponseParser();
  final List<int> _legacy = [];
  Map<String, dynamic>? add(Uint8List data) {
    _v2.add(data);
    try {
      final response = _v2.next();
      if (response != null &&
          response.header['ok'] == true &&
          response.json is Map &&
          isStarThermalInfo(response.object)) {
        return response.object;
      }
    } on FormatException {
      _v2.reset();
    }
    _legacy.addAll(data);
    while (_legacy.contains(10)) {
      final end = _legacy.indexOf(10);
      final line = utf8
          .decode(_legacy.sublist(0, end), allowMalformed: true)
          .trim();
      _legacy.removeRange(0, end + 1);
      try {
        final j = jsonDecode(line);
        if (j is Map<String, dynamic> &&
            !j.containsKey('api') &&
            (j.containsKey('Serial') ||
                j.containsKey('SerialNum') ||
                j.containsKey('Activated') ||
                j.containsKey('isActivated'))) {
          return j;
        }
      } catch (_) {}
    }
    if (_legacy.length > 8192) _legacy.clear();
    return null;
  }
}

Uint8List decodeBp64(Uint8List payload) {
  final out = ByteData(21600);
  final input = ByteData.sublistView(payload);
  var at = 0, pixel = 0;
  int byte() {
    if (at >= payload.length) throw const FormatException('BP64 截断');
    return payload[at++];
  }

  int signed() {
    final v = byte() | byte() << 8;
    return v >= 32768 ? v - 65536 : v;
  }

  while (pixel < 10800) {
    final count = (10800 - pixel).clamp(0, 64);
    final tag = byte();
    if (tag > 16) throw const FormatException('BP64 tag 错误');
    if (tag == 16) {
      for (var i = 0; i < count; i++) {
        out.setInt16(2 * pixel++, signed(), Endian.little);
      }
      continue;
    }
    final min = signed();
    final length = (count * tag + 7) ~/ 8;
    if (at + length > input.lengthInBytes) {
      throw const FormatException('BP64 数据截断');
    }
    var bits = 0, available = 0;
    for (var i = 0; i < count; i++) {
      while (available < tag) {
        bits |= byte() << available;
        available += 8;
      }
      final value = min + (bits & ((1 << tag) - 1));
      bits >>>= tag;
      available -= tag;
      if (value > 32767) throw const FormatException('BP64 像素溢出');
      out.setInt16(2 * pixel++, value, Endian.little);
    }
    if (bits != 0) throw const FormatException('BP64 非零补齐位');
  }
  if (at != payload.length) throw const FormatException('BP64 尾部数据');
  return out.buffer.asUint8List();
}

class Y16Parser {
  final String codec;
  final List<int> _bytes = [];
  int frames = 0, errors = 0, payloadBytes = 0;
  Y16Parser(this.codec);
  Uint8List? add(Uint8List chunk) {
    _bytes.addAll(chunk);
    Uint8List? latest;
    while (_bytes.length >= 6) {
      if (_bytes[0] != 89 ||
          _bytes[1] != 49 ||
          _bytes[2] != 54 ||
          _bytes[3] != 70) {
        _bytes.removeAt(0);
        continue;
      }
      final length = _bytes[4] | _bytes[5] << 8;
      if ((codec == 'RAW16' && length != 21600) ||
          length < 507 ||
          length > 21769) {
        errors++;
        _bytes.removeAt(0);
        continue;
      }
      if (_bytes.length < length + 10) break;
      try {
        final payload = Uint8List.fromList(_bytes.sublist(6, 6 + length));
        final decoded = codec == 'RAW16' ? payload : decodeBp64(payload);
        final expected = ByteData.sublistView(
          Uint8List.fromList(_bytes.sublist(6 + length, 10 + length)),
        ).getUint32(0, Endian.little);
        if (crc32(decoded) != expected) {
          throw const FormatException('帧 CRC32 错误');
        }
        latest = decoded;
        frames++;
        payloadBytes += length;
        _bytes.removeRange(0, length + 10);
      } on FormatException {
        errors++;
        _bytes.removeAt(0);
      }
    }
    return latest;
  }
}

void validateCurves(
  Map<String, dynamic> meta,
  Uint8List blob,
  String expected,
) {
  final n = meta['node_count'];
  if (n is! int ||
      n < 1 ||
      n > 10 ||
      blob.length != n * 2402 ||
      meta['schema_version'] != 1 ||
      meta['points_per_curve'] != 600 ||
      meta['distance_count'] != 2 ||
      meta['encoding'] != 'u16le' ||
      meta['layout'] != 'node-near-far-then-i16le-knots' ||
      meta['crc32'] != expected ||
      crcHex(blob) != expected) {
    throw const FormatException('曲线集合校验失败');
  }
  final nodes = meta['nodes'] as List;
  if (nodes.length != n) throw const FormatException('曲线节点数量错误');
  final data = ByteData.sublistView(blob);
  for (var node = 0; node < n; node++) {
    if (nodes[node]['index'] != node ||
        nodes[node]['knot_centi_c'] !=
            data.getInt16(n * 2400 + node * 2, Endian.little)) {
      throw const FormatException('曲线节点温度错误');
    }
    for (var distance = 0; distance < 2; distance++) {
      final offset = node * 2400 + distance * 1200;
      var valid =
          data.getUint16(offset, Endian.little) <
          data.getUint16(offset + 1198, Endian.little);
      for (var i = 1; i < 600; i++) {
        if (data.getUint16(offset + i * 2, Endian.little) <
            data.getUint16(offset + (i - 1) * 2, Endian.little)) {
          valid = false;
        }
      }
      if (nodes[node][distance == 0 ? 'near_valid' : 'far_valid'] != valid) {
        throw const FormatException('曲线可用状态错误');
      }
    }
  }
}
