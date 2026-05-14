/// 协议帧解析器 (Dart 端实现, 与 frame_parser.py 字节级一致).
///
/// 与设备固件 src/streaming.h 约定:
///
/// 热帧 (3092 B):
///   "BEGIN" + T_max(4B f32 LE) + T_min(4B f32 LE) + T_avg(4B f32 LE)
///         + 768 * f32 LE (24x32 行优先) + "END"
///
/// 可见光帧 (变长):
///   "VBEG" + width(4B u32 LE) + height(4B u32 LE) + len(4B u32 LE)
///         + RGB565 LE * len/2 + "VEND"
///
/// 使用:
/// ```dart
/// final p = FrameParser(
///   onThermal: (max, min, avg, frame) { ... },
///   onVisible: (w, h, rgb565) { ... },
/// );
/// p.feed(bytesFromSerial);
/// ```
library;

import 'dart:typed_data';

/// 热帧回调: (tMax, tMin, tAvg, 24x32 Float32List 摄氏度)
typedef ThermalCallback = void Function(
    double tMax, double tMin, double tAvg, Float32List frame);

/// 可见光回调: (width, height, height*width Uint16List RGB565)
typedef VisibleCallback = void Function(int width, int height, Uint16List frame);

/// 非帧字节回调: 收到的字节中确认不是帧的部分(被丢弃的前导/无效区段),
/// 通常是设备的 ASCII 响应文本. 上层可用于命令行回显.
typedef PassthroughCallback = void Function(Uint8List bytes);

class FrameParser {
  // 协议常量 (字节级与设备一致)
  static final Uint8List _thermalBegin = Uint8List.fromList('BEGIN'.codeUnits);
  static final Uint8List _thermalEnd = Uint8List.fromList('END'.codeUnits);
  static final Uint8List _visibleBegin = Uint8List.fromList('VBEG'.codeUnits);
  static final Uint8List _visibleEnd = Uint8List.fromList('VEND'.codeUnits);

  static const int thermalHeaderSize = 12; // 3 * f32
  static const int thermalPixelCount = 768; // 24 * 32
  static const int thermalPixelBytes = thermalPixelCount * 4;
  static const int thermalFrameTotal =
      5 + thermalHeaderSize + thermalPixelBytes + 3; // = 3092

  static const int visibleHeaderSize = 12; // 3 * u32
  static const int visibleMaxPayload = 120 * 160 * 2; // 38400

  final ThermalCallback? onThermal;
  final VisibleCallback? onVisible;
  final PassthroughCallback? onPassthrough;
  final int maxBuffer;

  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _bytes = Uint8List(0);

  int thermalFrames = 0;
  int visibleFrames = 0;
  int droppedBytes = 0;

  FrameParser({
    this.onThermal,
    this.onVisible,
    this.onPassthrough,
    this.maxBuffer = 512 * 1024,
  });

  /// 追加字节流并尝试提取所有完整帧.
  void feed(List<int> data) {
    if (data.isEmpty) return;
    _buf.add(data);
    _bytes = _buf.toBytes();
    _buf.clear();
    _buf.add(_bytes);

    if (_bytes.length > maxBuffer) {
      final drop = _bytes.length - maxBuffer;
      droppedBytes += drop;
      _consume(drop);
    }
    while (_tryExtractOne()) {}
  }

  /// 重置状态 (例如串口重连).
  void reset() {
    _buf.clear();
    _bytes = Uint8List(0);
    thermalFrames = 0;
    visibleFrames = 0;
    droppedBytes = 0;
  }

  // --------------------------------------------------------
  // 内部
  // --------------------------------------------------------

  /// 把前 n 字节从缓冲区消费掉.
  void _consume(int n) {
    if (n <= 0) return;
    if (n >= _bytes.length) {
      _buf.clear();
      _bytes = Uint8List(0);
      return;
    }
    final rest = _bytes.sublist(n);
    _buf.clear();
    _buf.add(rest);
    _bytes = rest;
  }

  /// 丢弃前 n 字节并把这些字节作为 passthrough 上抛(用于 ASCII 响应).
  void _passthroughAndConsume(int n) {
    if (n <= 0) return;
    final n2 = n > _bytes.length ? _bytes.length : n;
    if (onPassthrough != null) {
      onPassthrough!(Uint8List.fromList(_bytes.sublist(0, n2)));
    }
    droppedBytes += n2;
    _consume(n2);
  }

  bool _tryExtractOne() {
    final idxT = _indexOf(_bytes, _thermalBegin);
    final idxV = _indexOf(_bytes, _visibleBegin);

    if (idxT < 0 && idxV < 0) {
      // 保留 magic_len-1 字节防跨 chunk
      const keep = 4 - 1; // max(5,4) - 1 = 4, 但保 3 字节足以覆盖 VBEG/BEGIN 边界
      if (_bytes.length > keep) {
        final drop = _bytes.length - keep;
        _passthroughAndConsume(drop);
      }
      return false;
    }

    int idx;
    String kind;
    if (idxT < 0) {
      idx = idxV;
      kind = 'v';
    } else if (idxV < 0) {
      idx = idxT;
      kind = 't';
    } else if (idxT <= idxV) {
      idx = idxT;
      kind = 't';
    } else {
      idx = idxV;
      kind = 'v';
    }

    if (idx > 0) {
      _passthroughAndConsume(idx);
    }

    return kind == 't' ? _tryExtractThermal() : _tryExtractVisible();
  }

  bool _tryExtractThermal() {
    if (_bytes.length < thermalFrameTotal) return false;

    final endOff = _thermalBegin.length + thermalHeaderSize + thermalPixelBytes;
    if (!_equalsAt(_bytes, endOff, _thermalEnd)) {
      droppedBytes += 1;
      _consume(1);
      return true;
    }

    final bd = ByteData.sublistView(
        _bytes, _thermalBegin.length, _thermalBegin.length + thermalHeaderSize);
    final tMax = bd.getFloat32(0, Endian.little);
    final tMin = bd.getFloat32(4, Endian.little);
    final tAvg = bd.getFloat32(8, Endian.little);

    final pixOff = _thermalBegin.length + thermalHeaderSize;
    final pixView = ByteData.sublistView(
        _bytes, pixOff, pixOff + thermalPixelBytes);
    final pixels = Float32List(thermalPixelCount);
    for (int i = 0; i < thermalPixelCount; i++) {
      pixels[i] = pixView.getFloat32(i * 4, Endian.little);
    }

    _consume(thermalFrameTotal);
    thermalFrames++;
    onThermal?.call(tMax, tMin, tAvg, pixels);
    return true;
  }

  bool _tryExtractVisible() {
    final magicLen = _visibleBegin.length;
    if (_bytes.length < magicLen + visibleHeaderSize) return false;

    final bd = ByteData.sublistView(
        _bytes, magicLen, magicLen + visibleHeaderSize);
    final width = bd.getUint32(0, Endian.little);
    final height = bd.getUint32(4, Endian.little);
    final payloadLen = bd.getUint32(8, Endian.little);

    if (payloadLen <= 0 ||
        payloadLen > visibleMaxPayload ||
        payloadLen != width * height * 2) {
      droppedBytes += 1;
      _consume(1);
      return true;
    }

    final total =
        magicLen + visibleHeaderSize + payloadLen + _visibleEnd.length;
    if (_bytes.length < total) return false;

    final endOff = magicLen + visibleHeaderSize + payloadLen;
    if (!_equalsAt(_bytes, endOff, _visibleEnd)) {
      droppedBytes += 1;
      _consume(1);
      return true;
    }

    final payloadOff = magicLen + visibleHeaderSize;
    final payloadView =
        ByteData.sublistView(_bytes, payloadOff, payloadOff + payloadLen);
    final pixCount = width * height;
    final pixels = Uint16List(pixCount);
    for (int i = 0; i < pixCount; i++) {
      pixels[i] = payloadView.getUint16(i * 2, Endian.little);
    }

    _consume(total);
    visibleFrames++;
    onVisible?.call(width, height, pixels);
    return true;
  }

  // --------------------------------------------------------
  // 字节查找辅助 (避免 dart:io / dart:convert 依赖)
  // --------------------------------------------------------

  static int _indexOf(Uint8List haystack, Uint8List needle) {
    if (needle.isEmpty || haystack.length < needle.length) return -1;
    final first = needle[0];
    final last = haystack.length - needle.length;
    outer:
    for (int i = 0; i <= last; i++) {
      if (haystack[i] != first) continue;
      for (int j = 1; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static bool _equalsAt(Uint8List haystack, int offset, Uint8List needle) {
    if (offset < 0 || offset + needle.length > haystack.length) return false;
    for (int i = 0; i < needle.length; i++) {
      if (haystack[offset + i] != needle[i]) return false;
    }
    return true;
  }
}

/// RGB565 (uint16) → RGB888 (uint8 x 3). 行优先, 长度 = width*height*3.
Uint8List rgb565ToRgb888(Uint16List frame) {
  final out = Uint8List(frame.length * 3);
  for (int i = 0, j = 0; i < frame.length; i++, j += 3) {
    final v = frame[i];
    final r5 = (v >> 11) & 0x1F;
    final g6 = (v >> 5) & 0x3F;
    final b5 = v & 0x1F;
    out[j] = (r5 << 3) | (r5 >> 2);
    out[j + 1] = (g6 << 2) | (g6 >> 4);
    out[j + 2] = (b5 << 3) | (b5 >> 2);
  }
  return out;
}
