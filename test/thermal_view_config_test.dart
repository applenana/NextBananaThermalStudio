import 'dart:typed_data';

import 'package:banana_thermal/protocol/thermal_view_config.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/upsampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThermalViewConfig', () {
    test('解析固件 v1 响应', () {
      final config = ThermalViewConfig.tryParse({
        'type': 'thermal_view',
        'version': 1,
        'x_offset': -12,
        'y_offset': 7,
        'scale': 1.6,
      });

      expect(config, isNotNull);
      expect(config!.xOffset, -12);
      expect(config.yOffset, 7);
      expect(config.scale, 1.6);
    });

    test('拒绝未知版本和越界参数', () {
      expect(
        ThermalViewConfig.tryParse({
          'type': 'thermal_view',
          'version': 2,
          'x_offset': 0,
          'y_offset': 0,
          'scale': 1.0,
        }),
        isNull,
      );
      expect(
        ThermalViewConfig.tryParse({
          'type': 'thermal_view',
          'version': 1,
          'x_offset': 101,
          'y_offset': 0,
          'scale': 2.1,
        }),
        isNull,
      );
    });
  });

  test('RenderParams 保存并恢复设备热像视图参数', () {
    final original = const RenderParams().copyWith(
      thermalView: const ThermalViewParams(
        enabled: true,
        scale: 1.8,
        xOffset: 9,
        yOffset: -4,
      ),
    );
    final restored = RenderParams.fromJson(original.toJson());

    expect(restored.thermalView.enabled, isTrue);
    expect(restored.thermalView.scale, 1.8);
    expect(restored.thermalView.xOffset, 9);
    expect(restored.thermalView.yOffset, -4);
  });

  group('设备热像视图坐标映射', () {
    final source = Float32List.fromList([
      for (int y = 0; y < 24; y++)
        for (int x = 0; x < 32; x++) x + y * 100.0,
    ]);

    test('正向 10px X/Y 偏移分别移动 1 个源像素', () {
      Float32List render(int xOffset, int yOffset) => upsampleThermalView(
        src: source,
        srcW: 32,
        srcH: 24,
        dstW: 320,
        dstH: 240,
        scale: 1.0,
        xOffset: xOffset,
        yOffset: yOffset,
        method: UpsampleMethod.bilinear,
      );

      final base = render(0, 0);
      final shiftedX = render(10, 0);
      final shiftedY = render(0, 10);
      const sampleX = 160;
      const sampleY = 120;
      final i = sampleY * 320 + sampleX;

      expect(shiftedX[i] - base[i], closeTo(1.0, 0.001));
      expect(shiftedY[i] - base[i], closeTo(100.0, 0.001));
    });

    test('2x 缩放缩小可见源范围', () {
      final normal = upsampleThermalView(
        src: source,
        srcW: 32,
        srcH: 24,
        dstW: 320,
        dstH: 240,
        scale: 1.0,
        xOffset: 0,
        yOffset: 0,
        method: UpsampleMethod.bilinear,
      );
      final zoomed = upsampleThermalView(
        src: source,
        srcW: 32,
        srcH: 24,
        dstW: 320,
        dstH: 240,
        scale: 2.0,
        xOffset: 0,
        yOffset: 0,
        method: UpsampleMethod.bilinear,
      );

      final normalSpan = normal[319] - normal[0];
      final zoomedSpan = zoomed[319] - zoomed[0];
      expect(zoomedSpan, lessThan(normalSpan * 0.55));
    });

    test('±100px 极限偏移始终钳制在源数据边界', () {
      for (final offset in [-100, 100]) {
        final output = upsampleThermalView(
          src: source,
          srcW: 32,
          srcH: 24,
          dstW: 320,
          dstH: 240,
          scale: 1.0,
          xOffset: offset,
          yOffset: offset,
          method: UpsampleMethod.bicubic,
        );
        expect(output.length, 320 * 240);
        expect(output.every((value) => value.isFinite), isTrue);
      }
    });
  });
}
