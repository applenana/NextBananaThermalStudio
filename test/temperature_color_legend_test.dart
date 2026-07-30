import 'dart:typed_data';

import 'package:banana_thermal/fusion/fusion.dart';
import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';
import 'package:banana_thermal/ui/widgets/temperature_color_legend.dart';
import 'package:banana_thermal/ui/widgets/thermal_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RenderedFrame buildFrame({
    RenderParams params = const RenderParams(
      upsampleScale: 1,
      bilateralEnabled: false,
    ),
  }) {
    return renderPipeline(
      thermalFrame: Float32List.fromList([
        10,
        15,
        20,
        25,
        30,
        35,
        40,
        45,
        50,
        55,
        60,
        65,
      ]),
      srcW: 4,
      srcH: 3,
      params: params,
    );
  }

  test('帧色标与正式 colorize 路径完全一致', () {
    const params = RenderParams(
      upsampleScale: 1,
      bilateralEnabled: false,
      mappingCurve: 'nonlinear',
      useCustomColors: true,
      coldColor: 0x123456,
      midColor: 0x78ABCD,
      hotColor: 0xFEDCBA,
    );
    final frame = buildFrame(params: params);
    final normalized = Float32List(64);
    for (int i = 0; i < normalized.length; i++) {
      normalized[i] = i / (normalized.length - 1);
    }
    final expected = colorize(
      normalized: normalized,
      width: normalized.length,
      height: 1,
      mappingCurve: params.mappingCurve,
      useCustomColors: params.useCustomColors,
      coldColor: params.coldColor,
      midColor: params.midColor,
      hotColor: params.hotColor,
    );

    expect(frame.thermalColorScaleRgb, orderedEquals(expected));
    expect(frame.tMin, 10);
    expect(frame.tMax, 65);
  });

  test('全帧无有效温度时标记为不可显示图例', () {
    final frame = renderPipeline(
      thermalFrame: Float32List.fromList(List.filled(12, double.nan)),
      srcW: 4,
      srcH: 3,
      params: const RenderParams(upsampleScale: 1, bilateralEnabled: false),
    );

    expect(frame.hasFiniteTemperatureData, isFalse);
  });

  testWidgets('温度图例开关控制是否渲染', (tester) async {
    final frame = buildFrame();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: ThermalCanvas(frame: frame, showTemperatureLegend: false),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TemperatureColorLegend), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: ThermalCanvas(frame: frame, showTemperatureLegend: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TemperatureColorLegend), findsOneWidget);
  });

  testWidgets('浮窗关闭按钮触发关闭回调', (tester) async {
    final frame = buildFrame();
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: ThermalCanvas(
            frame: frame,
            showTemperatureLegend: true,
            onCloseTemperatureLegend: () => closed = true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('关闭温度图例'));

    expect(closed, isTrue);
  });

  testWidgets('左侧和右侧停靠会改变图例水平位置', (tester) async {
    final frame = buildFrame();

    Future<double> legendLeft(TemperatureLegendSide side) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: ThermalCanvas(
              frame: frame,
              showTemperatureLegend: true,
              temperatureLegendSide: side,
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getTopLeft(find.byType(TemperatureColorLegend)).dx;
    }

    final left = await legendLeft(TemperatureLegendSide.left);
    final right = await legendLeft(TemperatureLegendSide.right);

    expect(right, greaterThan(left));
  });

  testWidgets('温度图例可以在热像画面内拖动', (tester) async {
    final frame = buildFrame();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: ThermalCanvas(frame: frame, showTemperatureLegend: true),
        ),
      ),
    );
    await tester.pump();
    final before = tester.getTopLeft(find.byType(TemperatureColorLegend));

    await tester.drag(
      find.byType(TemperatureColorLegend),
      const Offset(60, -40),
    );
    await tester.pump();
    final after = tester.getTopLeft(find.byType(TemperatureColorLegend));

    expect(after.dx, greaterThan(before.dx));
    expect(after.dy, lessThan(before.dy));
  });

  testWidgets('纵向图例按高温在上、低温在下渲染', (tester) async {
    final frame = buildFrame();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: ThermalCanvas(
            frame: frame,
            showTemperatureLegend: true,
            temperatureLegendOrientation: TemperatureLegendOrientation.vertical,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(TemperatureColorLegend), findsOneWidget);
    expect(find.text('65.0°'), findsOneWidget);
    expect(find.text('10.0°'), findsOneWidget);
    expect(
      tester.getSize(find.byType(TemperatureColorLegend)).width,
      lessThanOrEqualTo(48),
    );
    final maxTop = tester.getTopLeft(find.text('65.0°')).dy;
    final minTop = tester.getTopLeft(find.text('10.0°')).dy;
    expect(maxTop, lessThan(minTop));
  });
}
