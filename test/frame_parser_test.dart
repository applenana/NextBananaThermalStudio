import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:banana_thermal/protocol/frame_parser.dart';

Uint8List _f32Le(double v) {
  final b = ByteData(4);
  b.setFloat32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _u32Le(int v) {
  final b = ByteData(4);
  b.setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _concat(List<List<int>> parts) {
  final total = parts.fold<int>(0, (s, p) => s + p.length);
  final out = Uint8List(total);
  int o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

void main() {
  group('FrameParser', () {
    // 构造一帧合法热数据
    Uint8List buildThermal() {
      final pix = Uint8List(24 * 32 * 4);
      final view = ByteData.sublistView(pix);
      for (int i = 0; i < 24 * 32; i++) {
        view.setFloat32(i * 4, 20.0 + (i % 20) * 1.0, Endian.little);
      }
      return _concat([
        'BEGIN'.codeUnits,
        _f32Le(40.0),
        _f32Le(20.0),
        _f32Le(30.0),
        pix,
        'END'.codeUnits,
      ]);
    }

    // 构造一帧合法可见光 (8x4 简化)
    Uint8List buildVisible(int w, int h) {
      final pix = Uint8List(w * h * 2);
      for (int i = 0; i < w * h; i++) {
        pix[i * 2] = i & 0xFF;
        pix[i * 2 + 1] = (i >> 8) & 0xFF;
      }
      return _concat([
        'VBEG'.codeUnits,
        _u32Le(w),
        _u32Le(h),
        _u32Le(pix.length),
        pix,
        'VEND'.codeUnits,
      ]);
    }

    test('全帧总长 = 3092', () {
      expect(FrameParser.thermalFrameTotal, 3092);
    });

    test('拼接送入解出 2+2 帧', () {
      int tCount = 0, vCount = 0;
      final p = FrameParser(
        onThermal: (mx, mn, av, frame) {
          expect(frame.length, 24 * 32);
          expect(mx, 40.0);
          expect(mn, 20.0);
          expect(av, 30.0);
          tCount++;
        },
        onVisible: (w, h, frame) {
          expect(w, 8);
          expect(h, 4);
          expect(frame.length, 32);
          vCount++;
        },
      );

      final t = buildThermal();
      final v = buildVisible(8, 4);
      p.feed(_concat([t, v, t, v]));

      expect(tCount, 2);
      expect(vCount, 2);
    });

    test('头部噪声 + 跨边界切片送入', () {
      int tCount = 0, vCount = 0;
      final p = FrameParser(
        onThermal: (_, __, ___, ____) => tCount++,
        onVisible: (_, __, ___) => vCount++,
      );
      final big = _concat([
        [0x00, 0x01, 0xFF],
        buildThermal(),
        'junk'.codeUnits,
        buildVisible(8, 4),
      ]);
      for (int i = 0; i < big.length; i += 17) {
        final end = (i + 17 < big.length) ? i + 17 : big.length;
        p.feed(big.sublist(i, end));
      }
      expect(tCount, 1);
      expect(vCount, 1);
    });

    test('RGB565 → RGB888 红/绿/蓝色彩近似', () {
      final f = Uint16List.fromList([0xF800, 0x07E0, 0x001F]);
      final rgb = rgb565ToRgb888(f);
      expect(rgb[0], greaterThan(240)); // R
      expect(rgb[4], greaterThan(240)); // G of pixel 1
      expect(rgb[8], greaterThan(240)); // B of pixel 2
    });
  });
}
