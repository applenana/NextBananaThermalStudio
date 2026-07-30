import 'dart:typed_data';

import 'package:banana_thermal/protocol/thermal_view_config.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';
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

    test('解析方屏 Heimann v2 响应', () {
      final config = ThermalViewConfig.tryParse({
        'type': 'thermal_view',
        'version': 2,
        'sensor': 'heimann_htpa32x32',
        'screen_mode': 'square',
        'visible_width': 120,
        'visible_height': 120,
        'thermal_width': 32,
        'thermal_height': 32,
        'thermal_count': 1024,
        'display_width': 240,
        'display_height': 240,
        'x_offset': 4,
        'y_offset': -6,
        'scale': 1.4,
        'sensor_rotate180': false,
      });

      expect(config, isNotNull);
      expect(config!.sensor, ThermalSensorKind.heimannHtpa32x32);
      expect(config.screenMode, ThermalScreenMode.square);
      expect(config.thermalWidth, 32);
      expect(config.thermalHeight, 32);
      expect(config.thermalCount, 1024);
      expect(config.sensorRotate180, isFalse);
    });

    test('解析方屏 MLX v2 时仍保持 32x24 热流', () {
      final config = ThermalViewConfig.tryParse({
        'type': 'thermal_view',
        'version': 2,
        'sensor': 'mlx90640',
        'screen_mode': 'square',
        'visible_width': 120,
        'visible_height': 120,
        'thermal_width': 32,
        'thermal_height': 24,
        'thermal_count': 768,
        'display_width': 240,
        'display_height': 240,
        'x_offset': 0,
        'y_offset': 0,
        'scale': 1.3,
        'sensor_rotate180': true,
      });

      expect(config, isNotNull);
      expect(config!.sensor, ThermalSensorKind.mlx90640);
      expect(config.thermalCount, 768);
    });

    test('拒绝传感器与热流尺寸不一致的 v2 响应', () {
      final json = <String, dynamic>{
        'type': 'thermal_view',
        'version': 2,
        'sensor': 'mlx90640',
        'screen_mode': 'square',
        'visible_width': 120,
        'visible_height': 120,
        'thermal_width': 32,
        'thermal_height': 32,
        'thermal_count': 1024,
        'display_width': 240,
        'display_height': 240,
        'x_offset': 0,
        'y_offset': 0,
        'scale': 1.0,
        'sensor_rotate180': true,
      };

      expect(ThermalViewConfig.tryParse(json), isNull);
      json['sensor'] = 'unknown';
      expect(ThermalViewConfig.tryParse(json), isNull);
      json['sensor'] = 'heimann_htpa32x32';
      expect(ThermalViewConfig.tryParse(json), isNotNull);
    });

    test('拒绝未知版本和越界参数', () {
      expect(
        ThermalViewConfig.tryParse({
          'type': 'thermal_view',
          'version': 3,
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
        sensor: ThermalSensorKind.mlx90640,
        screenMode: ThermalScreenMode.square,
        sensorRotate180: false,
        displayWidth: 240,
        displayHeight: 240,
      ),
    );
    final restored = RenderParams.fromJson(original.toJson());

    expect(restored.thermalView.enabled, isTrue);
    expect(restored.thermalView.scale, 1.8);
    expect(restored.thermalView.xOffset, 9);
    expect(restored.thermalView.yOffset, -4);
    expect(restored.thermalView.sensor, ThermalSensorKind.mlx90640);
    expect(restored.thermalView.screenMode, ThermalScreenMode.square);
    expect(restored.thermalView.sensorRotate180, isFalse);
    expect(restored.thermalView.displayWidth, 240);
    expect(restored.thermalView.displayHeight, 240);
  });

  test('RenderParams 保存并恢复温度图例设置', () {
    final original = const RenderParams().copyWith(
      showTemperatureLegend: false,
      temperatureLegendOrientation: TemperatureLegendOrientation.vertical,
      temperatureLegendSide: TemperatureLegendSide.right,
    );
    final restored = RenderParams.fromJson(original.toJson());

    expect(restored.showTemperatureLegend, isFalse);
    expect(
      restored.temperatureLegendOrientation,
      TemperatureLegendOrientation.vertical,
    );
    expect(restored.temperatureLegendSide, TemperatureLegendSide.right);
  });

  test('旧版 RenderParams JSON 使用温度图例兼容默认值', () {
    final restored = RenderParams.fromJson(const {});

    expect(restored.showTemperatureLegend, isTrue);
    expect(
      restored.temperatureLegendOrientation,
      TemperatureLegendOrientation.horizontal,
    );
    expect(restored.temperatureLegendSide, TemperatureLegendSide.left);
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

  group('MLX 方屏链路复原', () {
    final mlx = Float32List.fromList([
      for (int y = 0; y < 24; y++)
        for (int x = 0; x < 32; x++) y.toDouble(),
    ]);

    test('旋转开启时上补7行、下补1行并输出32x32', () {
      final restored = restoreMlxSquareContainer(mlx, sensorRotate180: true);
      expect(restored, hasLength(1024));
      expect(restored[0], 0);
      expect(restored[6 * 32], 0);
      expect(restored[7 * 32], 0);
      expect(restored[30 * 32], 23);
      expect(restored[31 * 32], 23);
    });

    test('旋转关闭时上补1行、下补7行', () {
      final restored = restoreMlxSquareContainer(mlx, sensorRotate180: false);
      expect(restored[0], 0);
      expect(restored[32], 0);
      expect(restored[24 * 32], 23);
      expect(restored[25 * 32], 23);
      expect(restored[31 * 32], 23);
    });

    test('渲染管线把 MLX 方屏输出为正方形', () {
      final frame = renderPipeline(
        thermalFrame: mlx,
        srcW: 32,
        srcH: 24,
        params: const RenderParams(
          upsampleScale: 1,
          upsampleMethod: UpsampleMethod.nearest,
          bilateralEnabled: false,
          thermalView: ThermalViewParams(
            enabled: true,
            sensor: ThermalSensorKind.mlx90640,
            screenMode: ThermalScreenMode.square,
          ),
        ),
      );
      expect(frame.width, 32);
      expect(frame.height, 32);
    });
  });
}
