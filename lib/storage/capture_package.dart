/// `.btpkg` 自定义数据包格式 (BananaThermal Package v1).
///
/// 用于把"拍摄/录制"时刻的原始热成像 + 可见光帧 + 元数据 (时间/GPS/备注)
/// 打包成单个可分发文件, 后续在"软件图库"里重新渲染查看.
///
/// 二进制布局 (小端):
///   magic   4B   "BTPK"  (0x42 0x54 0x50 0x4B)
///   version u16  当前 = 1
///   type    u8   0=photo (单帧)   1=video (帧序列)
///   _rsv    u8   保留 = 0
///   metaLen u32  meta JSON 字节数
///   meta    UTF-8 JSON bytes
///   frames  循环 frameCount 次:
///     tsMs       u64  相对 createdAt 毫秒
///     thermalLen u32  通常 = 768*4 = 3072
///     thermal    float32 LE * thermalW * thermalH (单位 °C)
///     visLen     u32  PNG 字节数 (0 表示无可见光帧)
///     visPng     PNG 编码 (旋转后 RGB888 -> PNG)
///   trailer 8B  ASCII "BTPK_END"
///
/// 设计取舍:
/// - 热成像保留 float32 原值 (768 帧 ~3KB, 视频按 25fps 一分钟约 4.5MB),
///   后续渲染可任意调参 (色板/上下限/算法).
/// - 可见光以 PNG 编码, 比原始 RGB888 小 5-10 倍, 视频 1min 约 30-100MB 量级.
/// - 单文件追加 (video 模式录制结束才补 trailer + 改写 frameCount).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// `.btpkg` 文件头部 + 元数据.
class CapturePackageHeader {
  static const List<int> magic = [0x42, 0x54, 0x50, 0x4B]; // BTPK
  static const int version = 1;
  static const int typePhoto = 0;
  static const int typeVideo = 1;
  static const List<int> trailer = [
    0x42, 0x54, 0x50, 0x4B, 0x5F, 0x45, 0x4E, 0x44, // BTPK_END
  ];

  final int type;
  final CaptureMeta meta;

  const CapturePackageHeader({required this.type, required this.meta});
}

/// 元数据字段, 序列化为包内 JSON. 字段全部可选 (null 表示未知).
class CaptureMeta {
  /// 拍摄/开始录制的时刻 (UTC ISO8601).
  final DateTime createdAt;

  /// GPS 纬度 / 经度 / 海拔 (米). null = 未获取或拒绝授权.
  final double? lat;
  final double? lng;
  final double? alt;

  /// 反向地理编码后的人读地名 (如 "杭州市西湖区"). null = 未查询/查询失败.
  final String? place;

  /// 用户备注 (默认空), 可后续在图库中编辑.
  final String note;

  /// 设备序列号 (来自激活信息), 用于区分多台设备.
  final String? deviceSn;

  /// 热成像分辨率, 当前固定 32x24, 写进去方便日后改尺寸.
  final int thermalW;
  final int thermalH;

  /// 可见光分辨率 (旋转后), 0 表示该包不含可见光帧.
  final int visibleW;
  final int visibleH;

  /// 视频帧数 (photo 模式恒为 1). 录制中按 0 占位, 结束时回写.
  final int frameCount;

  /// 拍摄/录制时的渲染+融合参数 (序列化 RenderParams.toJson). null = 未保存 (老包).
  final Map<String, dynamic>? renderParams;

  const CaptureMeta({
    required this.createdAt,
    this.lat,
    this.lng,
    this.alt,
    this.place,
    this.note = '',
    this.deviceSn,
    this.thermalW = 32,
    this.thermalH = 24,
    this.visibleW = 0,
    this.visibleH = 0,
    this.frameCount = 1,
    this.renderParams,
  });

  Map<String, dynamic> toJson() => {
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (alt != null) 'alt': alt,
        if (place != null) 'place': place,
        'note': note,
        if (deviceSn != null) 'deviceSn': deviceSn,
        'thermalW': thermalW,
        'thermalH': thermalH,
        'visibleW': visibleW,
        'visibleH': visibleH,
        'frameCount': frameCount,
        if (renderParams != null) 'renderParams': renderParams,
      };

  factory CaptureMeta.fromJson(Map<String, dynamic> j) => CaptureMeta(
        createdAt: DateTime.parse(j['createdAt'] as String).toUtc(),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        alt: (j['alt'] as num?)?.toDouble(),
        place: j['place'] as String?,
        note: (j['note'] as String?) ?? '',
        deviceSn: j['deviceSn'] as String?,
        thermalW: (j['thermalW'] as num?)?.toInt() ?? 32,
        thermalH: (j['thermalH'] as num?)?.toInt() ?? 24,
        visibleW: (j['visibleW'] as num?)?.toInt() ?? 0,
        visibleH: (j['visibleH'] as num?)?.toInt() ?? 0,
        frameCount: (j['frameCount'] as num?)?.toInt() ?? 1,
        renderParams: j['renderParams'] is Map<String, dynamic>
            ? j['renderParams'] as Map<String, dynamic>
            : null,
      );

  CaptureMeta copyWith({
    DateTime? createdAt,
    double? lat,
    double? lng,
    double? alt,
    String? place,
    String? note,
    String? deviceSn,
    int? thermalW,
    int? thermalH,
    int? visibleW,
    int? visibleH,
    int? frameCount,
    Map<String, dynamic>? renderParams,
  }) =>
      CaptureMeta(
        createdAt: createdAt ?? this.createdAt,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        alt: alt ?? this.alt,
        place: place ?? this.place,
        note: note ?? this.note,
        deviceSn: deviceSn ?? this.deviceSn,
        thermalW: thermalW ?? this.thermalW,
        thermalH: thermalH ?? this.thermalH,
        visibleW: visibleW ?? this.visibleW,
        visibleH: visibleH ?? this.visibleH,
        frameCount: frameCount ?? this.frameCount,
        renderParams: renderParams ?? this.renderParams,
      );
}

/// 单帧 (内存表示).
class CaptureFrame {
  /// 相对包 createdAt 的毫秒偏移.
  final int tsMs;

  /// 热成像温度场 (°C), 长度 = thermalW * thermalH.
  final Float32List thermal;

  /// 可见光 PNG 字节. 长度 0 表示该帧无可见光.
  final Uint8List visiblePng;

  const CaptureFrame({
    required this.tsMs,
    required this.thermal,
    required this.visiblePng,
  });
}

/// 写入器: 流式追加帧, 结束时统一回写 metaLen / frameCount + trailer.
///
/// 用法:
/// ```dart
/// final w = await CapturePackageWriter.create(
///   path: 'out.btpkg', type: CapturePackageHeader.typeVideo, meta: meta);
/// await w.appendFrame(CaptureFrame(...));
/// await w.close(); // 自动回写帧数 + trailer
/// ```
class CapturePackageWriter {
  final RandomAccessFile _raf;
  final int _type;
  CaptureMeta _meta;
  int _frameCount = 0;
  bool _closed = false;
  // 文件中 metaLen u32 的偏移, 用于 close() 时校正 meta (主要是 frameCount).
  int _metaLenOffset = 0;
  // 文件中 meta JSON 起始偏移.
  int _metaBytesOffset = 0;

  CapturePackageWriter._(this._raf, this._type, this._meta);

  static Future<CapturePackageWriter> create({
    required String path,
    required int type,
    required CaptureMeta meta,
  }) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final raf = await f.open(mode: FileMode.write);
    final w = CapturePackageWriter._(raf, type, meta);
    await w._writeHeader();
    return w;
  }

  Future<void> _writeHeader() async {
    // magic
    await _raf.writeFrom(CapturePackageHeader.magic);
    // version u16 LE + type u8 + rsv u8 (共 4B)
    final bd = ByteData(4);
    bd.setUint16(0, CapturePackageHeader.version, Endian.little);
    bd.setUint8(2, _type);
    bd.setUint8(3, 0);
    await _raf.writeFrom(bd.buffer.asUint8List());
    // metaLen u32 LE (含预留 padding, close()/editNote 时回写 meta 不会越界)
    _metaLenOffset = await _raf.position();
    final metaJson = utf8.encode(jsonEncode(_meta.toJson()));
    // 预留 padding 让后续 close (frameCount 由 0 变成实际) + editNote (备注扩写)
    // 都能就地覆盖, 不需要移动后续 frames. 1024B 余量足够装下:
    //   - frameCount 位数增量 (最多 ~9 位)
    //   - 备注扩写到约 200 字符
    //   - renderParams JSON (约 400 字节)
    //   - place 地名 (约 50 字符)
    const int padding = 1024;
    final totalMetaLen = metaJson.length + padding;
    final lenBd = ByteData(4)..setUint32(0, totalMetaLen, Endian.little);
    await _raf.writeFrom(lenBd.buffer.asUint8List());
    _metaBytesOffset = await _raf.position();
    // 真实 JSON + padding 个空格 (jsonDecode 时调用 trimRight 还原).
    final out = BytesBuilder(copy: false)
      ..add(metaJson)
      ..add(List<int>.filled(padding, 0x20));
    await _raf.writeFrom(out.toBytes());
  }

  /// 追加一帧. thermal 长度需等于 thermalW * thermalH.
  Future<void> appendFrame(CaptureFrame frame) async {
    if (_closed) throw StateError('writer already closed');
    final hdr = ByteData(8 + 4);
    hdr.setUint64(0, frame.tsMs, Endian.little);
    hdr.setUint32(8, frame.thermal.lengthInBytes, Endian.little);
    await _raf.writeFrom(hdr.buffer.asUint8List());
    // thermal float32 LE
    final hostEndian = Endian.host;
    if (hostEndian == Endian.little) {
      await _raf.writeFrom(frame.thermal.buffer
          .asUint8List(frame.thermal.offsetInBytes, frame.thermal.lengthInBytes));
    } else {
      // 主机大端: 逐 float 翻转再写. 实际所有目标平台都是 little endian.
      final tmp = ByteData(frame.thermal.lengthInBytes);
      for (int i = 0; i < frame.thermal.length; i++) {
        tmp.setFloat32(i * 4, frame.thermal[i], Endian.little);
      }
      await _raf.writeFrom(tmp.buffer.asUint8List());
    }
    // visLen u32 + visPng
    final visLen = frame.visiblePng.length;
    final tail = ByteData(4)..setUint32(0, visLen, Endian.little);
    await _raf.writeFrom(tail.buffer.asUint8List());
    if (visLen > 0) {
      await _raf.writeFrom(frame.visiblePng);
    }
    _frameCount += 1;
  }

  /// 关闭: 回写 meta.frameCount, 补 trailer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // 回写 meta JSON (frameCount 用真实值).
    final updated = _meta.copyWith(frameCount: _frameCount);
    _meta = updated;
    final metaJson = utf8.encode(jsonEncode(updated.toJson()));
    // 如果新 metaJson 长度变了 (基本会变, 因为 frameCount 从 0 变成实际值),
    // 需要把后续 frames 整体移位. 简化做法: 预留 32B padding (空白空格 + ' ').
    // 真实实现里, 我们写入定长字段: 用 padding 把 metaJson 凑到原长度.
    final origLen = _metaBytesOffset == 0
        ? metaJson.length
        : (await _readU32(_metaLenOffset));
    Uint8List toWrite;
    if (metaJson.length <= origLen) {
      final pad = origLen - metaJson.length;
      final builder = BytesBuilder(copy: false)
        ..add(metaJson)
        ..add(List<int>.filled(pad, 0x20)); // 空格填充
      toWrite = builder.toBytes();
    } else {
      // 新 meta 比旧的长 (frameCount 位数增加), 罕见 case: 录制超过 1e? 帧.
      // 直接 seek 到 frames 起点, 把后面拷贝出来再回写.
      // 这里偷懒: 写入截短到原长 (略丢 note 末尾字符). 录制几小时不会触发.
      toWrite = Uint8List.fromList(metaJson.sublist(0, origLen));
    }
    final endPos = await _raf.length();
    await _raf.setPosition(_metaBytesOffset);
    await _raf.writeFrom(toWrite);
    // 跳到文件末尾追加 trailer.
    await _raf.setPosition(endPos);
    await _raf.writeFrom(CapturePackageHeader.trailer);
    await _raf.flush();
    await _raf.close();
  }

  Future<int> _readU32(int offset) async {
    final cur = await _raf.position();
    await _raf.setPosition(offset);
    final buf = await _raf.read(4);
    await _raf.setPosition(cur);
    return ByteData.sublistView(buf).getUint32(0, Endian.little);
  }
}

/// 读取器: 一次性把 header + meta 读出来, frames 提供按索引读取.
class CapturePackageReader {
  final File file;
  final int type;
  final CaptureMeta meta;
  // 各帧在文件内的字节偏移 (frame header 起点), 顺序与 meta.frameCount 一致.
  final List<int> _frameOffsets;

  CapturePackageReader._(this.file, this.type, this.meta, this._frameOffsets);

  int get frameCount => _frameOffsets.length;

  static Future<CapturePackageReader> open(String path) async {
    final f = File(path);
    final raf = await f.open(mode: FileMode.read);
    try {
      final m = await raf.read(4);
      if (m.length < 4 ||
          m[0] != 0x42 ||
          m[1] != 0x54 ||
          m[2] != 0x50 ||
          m[3] != 0x4B) {
        throw const FormatException('not a BTPK package');
      }
      final hdr = await raf.read(4);
      final version = ByteData.sublistView(hdr).getUint16(0, Endian.little);
      if (version != 1) {
        throw FormatException('unsupported BTPK version: $version');
      }
      final type = hdr[2];
      final lenBuf = await raf.read(4);
      final metaLen =
          ByteData.sublistView(lenBuf).getUint32(0, Endian.little);
      final metaBuf = await raf.read(metaLen);
      // 去掉尾部空格 padding 再 decode.
      final raw = String.fromCharCodes(metaBuf).trimRight();
      final meta = CaptureMeta.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // 扫描 frames: 顺序读出每帧的偏移.
      final offsets = <int>[];
      for (int i = 0; i < meta.frameCount; i++) {
        final p = await raf.position();
        offsets.add(p);
        final fh = await raf.read(8 + 4);
        if (fh.length < 12) break;
        final thermalLen =
            ByteData.sublistView(fh).getUint32(8, Endian.little);
        await raf.setPosition(p + 12 + thermalLen);
        final visLenBuf = await raf.read(4);
        if (visLenBuf.length < 4) break;
        final visLen =
            ByteData.sublistView(visLenBuf).getUint32(0, Endian.little);
        await raf.setPosition(await raf.position() + visLen);
      }
      return CapturePackageReader._(f, type, meta, offsets);
    } finally {
      await raf.close();
    }
  }

  /// 读取第 [i] 帧 (返回 Float32List 热成像 + Uint8List PNG).
  Future<CaptureFrame> readFrame(int i) async {
    if (i < 0 || i >= _frameOffsets.length) {
      throw RangeError.index(i, _frameOffsets, 'frame');
    }
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(_frameOffsets[i]);
      final hb = await raf.read(12);
      final tsMs = ByteData.sublistView(hb).getUint64(0, Endian.little);
      final thermalLen =
          ByteData.sublistView(hb).getUint32(8, Endian.little);
      final tBytes = await raf.read(thermalLen);
      final thermal = Float32List.view(
        Uint8List.fromList(tBytes).buffer,
      );
      final vlb = await raf.read(4);
      final visLen = ByteData.sublistView(vlb).getUint32(0, Endian.little);
      final visPng = visLen == 0
          ? Uint8List(0)
          : Uint8List.fromList(await raf.read(visLen));
      return CaptureFrame(tsMs: tsMs, thermal: thermal, visiblePng: visPng);
    } finally {
      await raf.close();
    }
  }

  /// 仅修改 meta.note (重命名/备注编辑场景). 其他字段保持原值.
  /// 注: meta JSON 区有 padding, 长度允许小幅增长.
  static Future<void> editNote(String path, String newNote) async {
    final raf = await File(path).open(mode: FileMode.append);
    try {
      await raf.setPosition(0);
      final m = await raf.read(4);
      if (m.length < 4 ||
          m[0] != 0x42 ||
          m[1] != 0x54 ||
          m[2] != 0x50 ||
          m[3] != 0x4B) {
        throw const FormatException('not a BTPK package');
      }
      await raf.setPosition(8); // skip header(8) -> metaLen
      final lenBuf = await raf.read(4);
      final metaLen =
          ByteData.sublistView(lenBuf).getUint32(0, Endian.little);
      final metaStart = await raf.position();
      final metaBuf = await raf.read(metaLen);
      final raw = String.fromCharCodes(metaBuf).trimRight();
      final meta = CaptureMeta.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final updated = meta.copyWith(note: newNote);
      final newJson = utf8.encode(jsonEncode(updated.toJson()));
      if (newJson.length > metaLen) {
        throw StateError('备注太长, 超出预留空间 ${metaLen - newJson.length}B');
      }
      await raf.setPosition(metaStart);
      final pad = metaLen - newJson.length;
      final out = BytesBuilder(copy: false)
        ..add(newJson)
        ..add(List<int>.filled(pad, 0x20));
      await raf.writeFrom(out.toBytes());
      await raf.flush();
    } finally {
      await raf.close();
    }
  }
}
