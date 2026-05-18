/// `.btpkg` 自定义数据包格式 (BananaThermal Package v2).
///
/// v2 设计 (相对 v1): 一帧由若干"槽位"组成, 每个槽位可缺席. 当前定义两个槽位:
/// - bit0 thermal: float32 温度场 (单位 °C)
/// - bit1 visible: PNG 编码的可见光画面
/// 未来可扩 bit2 (depth) / bit3 (IR) 等.
///
/// 这种"帧 = 槽位容器"设计允许:
/// - 拍/录 时随时切推流开关, 后续帧自动缺席对应槽位.
/// - 单一容器同时表达 纯热 / 纯可见 / 双光 / 空帧 (用户主动关掉两路).
/// - 拍照 = 1 帧的录制, 视频 = N 帧, 同一种容器.
///
/// 二进制布局 (全小端):
///   magic   4B   "BTPK"  (0x42 0x54 0x50 0x4B)
///   version u16  当前 = 2
///   type    u8   0=photo (单帧)   1=video (帧序列)
///   _rsv    u8   保留 = 0
///   metaLen u32  meta JSON 字节数 (含 padding)
///   meta    UTF-8 JSON bytes + 空格 padding (允许就地回写)
///   frames  循环 frameCount 次:
///     slotMask u16  本帧槽位 bitmap
///     tsMs     u64  相对 createdAt 毫秒
///     若 slotMask & 1 (thermal):
///       thermalLen u32   通常 = 32*24*4 = 3072
///       thermal    float32 LE * thermalLen/4
///     若 slotMask & 2 (visible):
///       visLen     u32
///       visPng     PNG bytes
///   trailer 8B  ASCII "BTPK_END"
///
/// 不再向后兼容 v1: 升级期间旧包请丢弃或重新生成.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 槽位定义.
class FrameSlot {
  static const int thermal = 1 << 0; // 0x01
  static const int visible = 1 << 1; // 0x02
  static const int all = thermal | visible;
}

/// `.btpkg` 文件头部 + 元数据.
class CapturePackageHeader {
  static const List<int> magic = [0x42, 0x54, 0x50, 0x4B]; // BTPK
  static const int version = 2;
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

  /// 可见光分辨率 (旋转后), 0 表示该包从未出现过可见光帧.
  final int visibleW;
  final int visibleH;

  /// 视频帧数 (photo 模式恒为 1). 录制中按 0 占位, 结束时回写.
  final int frameCount;

  /// 拍摄/录制时的渲染+融合参数 (序列化 RenderParams.toJson). null = 未保存.
  final Map<String, dynamic>? renderParams;

  /// 本包内所有帧出现过的槽位并集 (bit0 thermal / bit1 visible).
  /// 录制结束时回写; 0 表示全部帧都是空帧.
  final int slotsUsedMask;

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
    this.slotsUsedMask = 0,
  });

  bool get hasAnyThermal => (slotsUsedMask & FrameSlot.thermal) != 0;
  bool get hasAnyVisible => (slotsUsedMask & FrameSlot.visible) != 0;

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
        'slotsUsedMask': slotsUsedMask,
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
        slotsUsedMask: (j['slotsUsedMask'] as num?)?.toInt() ?? 0,
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
    int? slotsUsedMask,
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
        slotsUsedMask: slotsUsedMask ?? this.slotsUsedMask,
      );
}

/// 单帧 (内存表示). 任一槽位可为 null = 该帧此槽位缺席.
class CaptureFrame {
  /// 相对包 createdAt 的毫秒偏移.
  final int tsMs;

  /// 热成像温度场 (°C), 长度 = thermalW * thermalH. null = 缺席.
  final Float32List? thermal;

  /// 可见光 PNG 字节. null 或长度 0 = 缺席.
  final Uint8List? visiblePng;

  const CaptureFrame({
    required this.tsMs,
    this.thermal,
    this.visiblePng,
  });

  /// 本帧槽位 bitmap.
  int get slotMask {
    int m = 0;
    if (thermal != null && thermal!.isNotEmpty) m |= FrameSlot.thermal;
    if (visiblePng != null && visiblePng!.isNotEmpty) m |= FrameSlot.visible;
    return m;
  }

  bool get hasThermal => (slotMask & FrameSlot.thermal) != 0;
  bool get hasVisible => (slotMask & FrameSlot.visible) != 0;
  bool get isEmpty => slotMask == 0;
}

/// 写入器: 流式追加帧, 结束时统一回写 metaLen / frameCount + trailer.
class CapturePackageWriter {
  final RandomAccessFile _raf;
  final int _type;
  CaptureMeta _meta;
  int _frameCount = 0;
  int _slotsUsedMask = 0;
  // 首次见到 thermal/visible 帧时记录的分辨率; 后续不再修改.
  int _thermalW;
  int _thermalH;
  int _visibleW;
  int _visibleH;
  bool _closed = false;
  int _metaLenOffset = 0;
  int _metaBytesOffset = 0;

  CapturePackageWriter._(this._raf, this._type, this._meta)
      : _thermalW = _meta.thermalW,
        _thermalH = _meta.thermalH,
        _visibleW = _meta.visibleW,
        _visibleH = _meta.visibleH;

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
    await _raf.writeFrom(CapturePackageHeader.magic);
    final bd = ByteData(4);
    bd.setUint16(0, CapturePackageHeader.version, Endian.little);
    bd.setUint8(2, _type);
    bd.setUint8(3, 0);
    await _raf.writeFrom(bd.buffer.asUint8List());
    _metaLenOffset = await _raf.position();
    final metaJson = utf8.encode(jsonEncode(_meta.toJson()));
    // padding 给 close() 回写 (frameCount/slotsUsedMask/分辨率/备注/renderParams)
    // 留出充足空间.
    const int padding = 1024;
    final totalMetaLen = metaJson.length + padding;
    final lenBd = ByteData(4)..setUint32(0, totalMetaLen, Endian.little);
    await _raf.writeFrom(lenBd.buffer.asUint8List());
    _metaBytesOffset = await _raf.position();
    final out = BytesBuilder(copy: false)
      ..add(metaJson)
      ..add(List<int>.filled(padding, 0x20));
    await _raf.writeFrom(out.toBytes());
  }

  /// 追加一帧. thermal/visiblePng 任一可为 null (该槽位缺席).
  /// 全 null 也允许 (空帧, 仅占用 10B = 2(mask)+8(ts)).
  Future<void> appendFrame(CaptureFrame frame) async {
    if (_closed) throw StateError('writer already closed');
    final mask = frame.slotMask;
    _slotsUsedMask |= mask;
    // 帧头: slotMask u16 + tsMs u64.
    final fh = ByteData(2 + 8);
    fh.setUint16(0, mask, Endian.little);
    fh.setUint64(2, frame.tsMs, Endian.little);
    await _raf.writeFrom(fh.buffer.asUint8List());
    if ((mask & FrameSlot.thermal) != 0) {
      final th = frame.thermal!;
      // 首帧记录分辨率: 实际尺寸通过 thermal.length 推算 (默认 32x24, length 应=768).
      if (_thermalW == 0 || _thermalH == 0) {
        _thermalW = 32;
        _thermalH = 24;
      }
      final lenBd = ByteData(4)..setUint32(0, th.lengthInBytes, Endian.little);
      await _raf.writeFrom(lenBd.buffer.asUint8List());
      if (Endian.host == Endian.little) {
        await _raf.writeFrom(
            th.buffer.asUint8List(th.offsetInBytes, th.lengthInBytes));
      } else {
        final tmp = ByteData(th.lengthInBytes);
        for (int i = 0; i < th.length; i++) {
          tmp.setFloat32(i * 4, th[i], Endian.little);
        }
        await _raf.writeFrom(tmp.buffer.asUint8List());
      }
    }
    if ((mask & FrameSlot.visible) != 0) {
      final png = frame.visiblePng!;
      final lenBd = ByteData(4)..setUint32(0, png.length, Endian.little);
      await _raf.writeFrom(lenBd.buffer.asUint8List());
      await _raf.writeFrom(png);
    }
    _frameCount += 1;
  }

  /// 录制过程中, 调用方通知首次见到的可见光分辨率 (PNG 解码代价高, 写时不解码).
  /// 仅在尚未记录时设置.
  void declareVisibleSize(int w, int h) {
    if (_visibleW == 0 || _visibleH == 0) {
      _visibleW = w;
      _visibleH = h;
    }
  }

  /// 关闭: 回写 meta (frameCount/slotsUsedMask/分辨率), 补 trailer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final updated = _meta.copyWith(
      frameCount: _frameCount,
      slotsUsedMask: _slotsUsedMask,
      thermalW: _thermalW,
      thermalH: _thermalH,
      visibleW: _visibleW,
      visibleH: _visibleH,
    );
    _meta = updated;
    final metaJson = utf8.encode(jsonEncode(updated.toJson()));
    final origLen = await _readU32(_metaLenOffset);
    Uint8List toWrite;
    if (metaJson.length <= origLen) {
      final pad = origLen - metaJson.length;
      final builder = BytesBuilder(copy: false)
        ..add(metaJson)
        ..add(List<int>.filled(pad, 0x20));
      toWrite = builder.toBytes();
    } else {
      toWrite = Uint8List.fromList(metaJson.sublist(0, origLen));
    }
    final endPos = await _raf.length();
    await _raf.setPosition(_metaBytesOffset);
    await _raf.writeFrom(toWrite);
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
  // 每帧的 slotMask, 与 _frameOffsets 一一对应 (供 UI 时间轴使用).
  final List<int> _frameSlotMasks;

  CapturePackageReader._(
      this.file, this.type, this.meta, this._frameOffsets, this._frameSlotMasks);

  int get frameCount => _frameOffsets.length;
  List<int> get frameSlotMasks => List.unmodifiable(_frameSlotMasks);

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
      if (version != CapturePackageHeader.version) {
        throw FormatException(
            'unsupported BTPK version: $version (expected ${CapturePackageHeader.version})');
      }
      final type = hdr[2];
      final lenBuf = await raf.read(4);
      final metaLen =
          ByteData.sublistView(lenBuf).getUint32(0, Endian.little);
      final metaBuf = await raf.read(metaLen);
      final raw = String.fromCharCodes(metaBuf).trimRight();
      final meta = CaptureMeta.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // 扫描 frames.
      final offsets = <int>[];
      final masks = <int>[];
      for (int i = 0; i < meta.frameCount; i++) {
        final p = await raf.position();
        // 帧头: u16 slotMask + u64 tsMs = 10 bytes.
        final fh = await raf.read(10);
        if (fh.length < 10) break;
        offsets.add(p);
        final slotMask =
            ByteData.sublistView(fh).getUint16(0, Endian.little);
        masks.add(slotMask);
        if ((slotMask & FrameSlot.thermal) != 0) {
          final lb = await raf.read(4);
          if (lb.length < 4) break;
          final len = ByteData.sublistView(lb).getUint32(0, Endian.little);
          await raf.setPosition(await raf.position() + len);
        }
        if ((slotMask & FrameSlot.visible) != 0) {
          final lb = await raf.read(4);
          if (lb.length < 4) break;
          final len = ByteData.sublistView(lb).getUint32(0, Endian.little);
          await raf.setPosition(await raf.position() + len);
        }
      }
      return CapturePackageReader._(f, type, meta, offsets, masks);
    } finally {
      await raf.close();
    }
  }

  /// 读取第 [i] 帧.
  Future<CaptureFrame> readFrame(int i) async {
    if (i < 0 || i >= _frameOffsets.length) {
      throw RangeError.index(i, _frameOffsets, 'frame');
    }
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(_frameOffsets[i]);
      final hb = await raf.read(10);
      final slotMask = ByteData.sublistView(hb).getUint16(0, Endian.little);
      final tsMs = ByteData.sublistView(hb).getUint64(2, Endian.little);
      Float32List? thermal;
      Uint8List? visPng;
      if ((slotMask & FrameSlot.thermal) != 0) {
        final lb = await raf.read(4);
        final len = ByteData.sublistView(lb).getUint32(0, Endian.little);
        final tBytes = await raf.read(len);
        thermal = Float32List.view(Uint8List.fromList(tBytes).buffer);
      }
      if ((slotMask & FrameSlot.visible) != 0) {
        final lb = await raf.read(4);
        final len = ByteData.sublistView(lb).getUint32(0, Endian.little);
        visPng = Uint8List.fromList(await raf.read(len));
      }
      return CaptureFrame(tsMs: tsMs, thermal: thermal, visiblePng: visPng);
    } finally {
      await raf.close();
    }
  }

  /// 仅修改 meta.note (重命名/备注编辑场景). 其他字段保持原值.
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
      await raf.setPosition(8);
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
