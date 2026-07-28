/// 图片解析: 把设备 `download <filename>` 返回的原始字节解析为温度场 +
/// 可选可见光. 兼容三种格式 (与全能上位机 py 端等价):
///
/// 1. v1 simple : `[0..3]Tmax(f32)` `[4..7]Tmin(f32)` `[8..]` 768 floats (24x32)
///    元数据中无 `mode` / `dataFormat` 字段时走此分支.
/// 2. v1 full   : `[0..7]Tmax,Tmin(f32)` `[8]full_screen(bool)` `[9..]` 768
///    或 1024 floats. 元数据含 `mode` 时走此分支.
/// 3. v2 HTPH   : `[0..3]'HTPH'` `[4]ver` `[5]flags` `[6..9]Tmax` `[10..13]Tmin`
///    `[14..15]visW (LE u16, has_visible)` `[16..17]visH` 之后是热成像 floats,
///    最后是 visible RGB565 LE.
/// 4. v3 HTPH   : 完整保留 v2 主体布局，在所有热成像/可见光数据之后追加
///    `[4B]thermalScale(f32)` `[2B]thermalX(i16)` `[2B]thermalY(i16)`.
///    因此旧解码器读取 v3 时仍能正确读取主体，只会忽略新增尾部.
///
/// flags: bit0=full_screen, bit1=has_visible, bit2-3=fusion_mode.
library;

import 'dart:typed_data';

import '../app_state.dart' show PhotoMeta;
import '../render/render_params.dart' show ThermalViewParams;

enum PhotoFormat { jpegLike, v1Simple, v1Full, v2Htph, unknown }

class PhotoDecoded {
  final PhotoFormat format;

  /// 24*32 / 32*32 单精度温度场 (上下镜像后, 与实时画面同方向).
  /// 可能为 null (jpegLike / unknown).
  final Float32List? thermal;
  final int srcW;
  final int srcH;
  final double tMin;
  final double tMax;

  /// 可见光 RGB888 (顺时针旋转 90° 后), 与项目实时通路同方向.
  final Uint8List? visibleRgb;
  final int visW;
  final int visH;

  /// 原始 JPEG 字节 (仅 jpegLike 有).
  final Uint8List? jpegBytes;

  /// 拍照瞬间设备使用的热像缩放/偏移. 仅 HTPH v3+ 携带;
  /// null 表示旧照片没有该元数据, 调用方必须保持旧版默认渲染行为.
  final ThermalViewParams? thermalView;

  /// 调试: 描述信息 (模式 / 融合标志等).
  final String summary;

  const PhotoDecoded({
    required this.format,
    this.thermal,
    this.srcW = 0,
    this.srcH = 0,
    this.tMin = 0,
    this.tMax = 0,
    this.visibleRgb,
    this.visW = 0,
    this.visH = 0,
    this.jpegBytes,
    this.thermalView,
    this.summary = '',
  });
}

class PhotoDecoder {
  /// 嗅探并解析. 不抛异常: 失败时返回 [PhotoFormat.unknown].
  static PhotoDecoded decode(Uint8List raw, PhotoMeta meta) {
    if (raw.length < 8) {
      return PhotoDecoded(format: PhotoFormat.unknown, summary: '数据过短');
    }
    // JPEG: FF D8 FF
    if (raw[0] == 0xFF && raw[1] == 0xD8 && raw[2] == 0xFF) {
      return PhotoDecoded(
        format: PhotoFormat.jpegLike,
        jpegBytes: raw,
        summary: 'JPEG ${raw.length}B',
      );
    }
    // HTPH magic
    if (raw.length >= 14 &&
        raw[0] == 0x48 &&
        raw[1] == 0x54 &&
        raw[2] == 0x50 &&
        raw[3] == 0x48) {
      return _decodeV2(raw);
    }
    // v1 完整 / 简易
    final hasMeta = meta.mode != null && meta.dataFormat != null;
    return hasMeta ? _decodeV1Full(raw) : _decodeV1Simple(raw);
  }

  static PhotoDecoded _decodeV1Simple(Uint8List raw) {
    final bd = ByteData.sublistView(raw);
    final tMax = bd.getFloat32(0, Endian.little);
    final tMin = bd.getFloat32(4, Endian.little);
    final field = _parseFloats(raw, 8, 768);
    final mirrored = _flipV(field, 32, 24);
    return PhotoDecoded(
      format: PhotoFormat.v1Simple,
      thermal: mirrored,
      srcW: 32,
      srcH: 24,
      tMin: _safe(tMin),
      tMax: _safe(tMax),
      summary: 'v1 simple 24x32',
    );
  }

  static PhotoDecoded _decodeV1Full(Uint8List raw) {
    if (raw.length < 9) {
      return PhotoDecoded(format: PhotoFormat.unknown, summary: 'v1 full 头不全');
    }
    final bd = ByteData.sublistView(raw);
    final tMax = bd.getFloat32(0, Endian.little);
    final tMin = bd.getFloat32(4, Endian.little);
    final fullScreen = raw[8] != 0;
    final w = 32, h = fullScreen ? 24 : 32;
    final n = w * h;
    final field = _parseFloats(raw, 9, n);
    final mirrored = _flipV(field, w, h);
    return PhotoDecoded(
      format: PhotoFormat.v1Full,
      thermal: mirrored,
      srcW: w,
      srcH: h,
      tMin: _safe(tMin),
      tMax: _safe(tMax),
      summary: 'v1 full ${h}x$w (${fullScreen ? "full" : "square"})',
    );
  }

  static PhotoDecoded _decodeV2(Uint8List raw) {
    final bd = ByteData.sublistView(raw);
    final ver = raw[4];
    final flags = raw[5];
    final fullScreen = (flags & 0x01) != 0;
    final hasVisible = (flags & 0x02) != 0;
    final fusionMode = (flags >> 2) & 0x03;
    final tMax = bd.getFloat32(6, Endian.little);
    final tMin = bd.getFloat32(10, Endian.little);

    int cursor = 14;
    ThermalViewParams? thermalView;
    int visW = 0, visH = 0;
    if (hasVisible) {
      if (raw.length < cursor + 4) {
        return PhotoDecoded(format: PhotoFormat.unknown, summary: 'v2 头不全');
      }
      visW = bd.getUint16(cursor, Endian.little);
      visH = bd.getUint16(cursor + 2, Endian.little);
      cursor += 4;
    }

    final w = 32, h = fullScreen ? 24 : 32;
    final thermalPoints = w * h;
    final thermalBytes = thermalPoints * 4;
    if (raw.length < cursor + thermalBytes) {
      return PhotoDecoded(format: PhotoFormat.unknown, summary: 'v2 热成像数据不足');
    }
    final field = _parseFloats(raw, cursor, thermalPoints);
    cursor += thermalBytes;
    final mirrored = _flipV(field, w, h);

    Uint8List? visRgb;
    int finalVisW = 0, finalVisH = 0;
    if (hasVisible && visW > 0 && visH > 0) {
      final visBytes = visW * visH * 2;
      if (raw.length >= cursor + visBytes) {
        final bytes = raw.sublist(cursor, cursor + visBytes);
        visRgb = _rgb565ToRgb888Rotated(bytes, visW, visH);
        finalVisW = visH;
        finalVisH = visW;
        cursor += visBytes;
      }
    }

    // v3 尾部位于完整 v2 主体之后。分块下载尚未收到可见光尾部时不猜测，
    // 先按旧图预览；完整文件到达后再合入照片自己的视图参数。
    final bodyComplete =
        !hasVisible || (visW > 0 && visH > 0 && visRgb != null);
    if (ver >= 3 && bodyComplete && raw.length >= cursor + 8) {
      final scale = bd.getFloat32(cursor, Endian.little);
      final xOffset = bd.getInt16(cursor + 4, Endian.little);
      final yOffset = bd.getInt16(cursor + 6, Endian.little);
      thermalView = ThermalViewParams(
        enabled: true,
        scale: _safeThermalScale(scale),
        xOffset: xOffset.clamp(-100, 100).toInt(),
        yOffset: yOffset.clamp(-100, 100).toInt(),
      );
    }

    const fusionNames = {0: 'OFF', 1: 'BLEND', 2: 'EDGE', 3: 'HALF_SAMPLE'};
    final viewSummary = thermalView == null
        ? 'thermalView=legacy'
        : 'thermalView=${thermalView.scale.toStringAsFixed(1)}x/'
            '${thermalView.xOffset}/${thermalView.yOffset}';
    return PhotoDecoded(
      format: PhotoFormat.v2Htph,
      thermal: mirrored,
      srcW: w,
      srcH: h,
      tMin: _safe(tMin),
      tMax: _safe(tMax),
      visibleRgb: visRgb,
      visW: finalVisW,
      visH: finalVisH,
      thermalView: thermalView,
      summary: 'v2 HTPH v$ver ${h}x$w '
          '${fullScreen ? "full" : "square"} '
          'fusion=${fusionNames[fusionMode] ?? "?"} '
          'visible=${hasVisible ? "${visW}x$visH" : "no"} '
          '$viewSummary',
    );
  }

  // ----------------- helpers -----------------

  static Float32List _parseFloats(Uint8List src, int offset, int count) {
    final out = Float32List(count);
    final bd = ByteData.sublistView(src);
    final maxN = ((src.length - offset) ~/ 4).clamp(0, count);
    for (int i = 0; i < maxN; i++) {
      out[i] = bd.getFloat32(offset + i * 4, Endian.little);
    }
    return out;
  }

  static Float32List _flipV(Float32List src, int w, int h) {
    final out = Float32List(w * h);
    for (int y = 0; y < h; y++) {
      final srcOff = (h - 1 - y) * w;
      final dstOff = y * w;
      for (int x = 0; x < w; x++) {
        out[dstOff + x] = src[srcOff + x];
      }
    }
    return out;
  }

  /// RGB565 LE -> RGB888, 顺时针旋转 90° (与实时通路一致).
  static Uint8List _rgb565ToRgb888Rotated(Uint8List src, int w, int h) {
    final newW = h, newH = w;
    final out = Uint8List(newW * newH * 3);
    final bd = ByteData.sublistView(src);
    for (int yp = 0; yp < newH; yp++) {
      for (int xp = 0; xp < newW; xp++) {
        final srcX = yp;
        final srcY = h - 1 - xp;
        final v = bd.getUint16((srcY * w + srcX) * 2, Endian.little);
        final r5 = (v >> 11) & 0x1F;
        final g6 = (v >> 5) & 0x3F;
        final b5 = v & 0x1F;
        final dj = (yp * newW + xp) * 3;
        out[dj] = (r5 << 3) | (r5 >> 2);
        out[dj + 1] = (g6 << 2) | (g6 >> 4);
        out[dj + 2] = (b5 << 3) | (b5 >> 2);
      }
    }
    return out;
  }

  static double _safe(double v) => (v.isNaN || v.isInfinite) ? 0.0 : v;

  static double _safeThermalScale(double v) {
    if (v.isNaN || v.isInfinite) return 1.0;
    return v.clamp(1.0, 2.0).toDouble();
  }
}
