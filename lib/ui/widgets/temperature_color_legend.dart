import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../render/render_params.dart';
import '../../render/render_pipeline.dart';

/// 热像画面上的悬浮温度色标。
///
/// 色条颜色直接来自 [RenderedFrame.thermalColorScaleRgb]，不会在 UI 层
/// 重新解释调色板，因此与本帧的 S 曲线、自定义颜色和端点裁剪保持一致。
class TemperatureColorLegend extends StatelessWidget {
  const TemperatureColorLegend({
    super.key,
    required this.frame,
    required this.orientation,
    this.reserveCloseSpace = false,
  });

  final RenderedFrame frame;
  final TemperatureLegendOrientation orientation;

  /// 为画布叠加的关闭按钮预留右上角空间。
  final bool reserveCloseSpace;

  @override
  Widget build(BuildContext context) {
    final colors = _decodeColors(frame.thermalColorScaleRgb);
    if (colors.length < 2 || !frame.hasFiniteTemperatureData) {
      return const SizedBox.shrink();
    }

    final span = frame.tMax - frame.tMin;
    return Semantics(
      container: true,
      label: span.abs() < 1e-6
          ? '温度色标，当前温度 ${_formatTemperature(frame.tMin)} 摄氏度'
          : '温度色标，最低 ${_formatTemperature(frame.tMin)} 摄氏度，'
                '最高 ${_formatTemperature(frame.tMax)} 摄氏度',
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x59131519),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 7,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: orientation == TemperatureLegendOrientation.horizontal
                ? const EdgeInsets.fromLTRB(10, 7, 10, 7)
                : const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: span.abs() < 1e-6
                ? _SingleTemperature(
                    value: frame.tMin,
                    color: colors.first,
                    reserveCloseSpace: reserveCloseSpace,
                    orientation: orientation,
                  )
                : orientation == TemperatureLegendOrientation.horizontal
                ? _HorizontalLegend(
                    colors: colors,
                    tMin: frame.tMin,
                    tMax: frame.tMax,
                    reserveCloseSpace: reserveCloseSpace,
                  )
                : _VerticalLegend(
                    colors: colors,
                    tMin: frame.tMin,
                    tMax: frame.tMax,
                  ),
          ),
        ),
      ),
    );
  }
}

class _HorizontalLegend extends StatelessWidget {
  const _HorizontalLegend({
    required this.colors,
    required this.tMin,
    required this.tMax,
    required this.reserveCloseSpace,
  });

  final List<Color> colors;
  final double tMin;
  final double tMax;
  final bool reserveCloseSpace;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tickCount = constraints.maxWidth >= 224 ? 5 : 3;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LegendHeader(
              label: '温度色标 · °C',
              reserveCloseSpace: reserveCloseSpace,
            ),
            const SizedBox(height: 4),
            _GradientBar(
              colors: colors,
              orientation: TemperatureLegendOrientation.horizontal,
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                for (int i = 0; i < tickCount; i++)
                  Expanded(
                    child: Text(
                      _formatTemperature(
                        tMin + (tMax - tMin) * i / (tickCount - 1),
                      ),
                      textAlign: i == 0
                          ? TextAlign.left
                          : i == tickCount - 1
                          ? TextAlign.right
                          : TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: _legendValueStyle,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _VerticalLegend extends StatelessWidget {
  const _VerticalLegend({
    required this.colors,
    required this.tMin,
    required this.tMax,
  });

  final List<Color> colors;
  final double tMin;
  final double tMax;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${_formatTemperature(tMax)}°',
            maxLines: 1,
            style: _legendValueStyle.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Center(
            child: _GradientBar(
              colors: colors,
              orientation: TemperatureLegendOrientation.vertical,
            ),
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${_formatTemperature(tMin)}°',
            maxLines: 1,
            style: _legendValueStyle.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendHeader extends StatelessWidget {
  const _LegendHeader({required this.label, required this.reserveCloseSpace});

  final String label;
  final bool reserveCloseSpace;

  @override
  Widget build(BuildContext context) {
    final reserved = reserveCloseSpace ? 18.0 : 0.0;
    return Row(
      children: [
        SizedBox(width: reserved),
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: _legendTitleStyle,
          ),
        ),
        SizedBox(width: reserved),
      ],
    );
  }
}

class _GradientBar extends StatelessWidget {
  const _GradientBar({required this.colors, required this.orientation});

  final List<Color> colors;
  final TemperatureLegendOrientation orientation;

  @override
  Widget build(BuildContext context) {
    final horizontal = orientation == TemperatureLegendOrientation.horizontal;
    return Container(
      width: horizontal ? null : 11,
      height: horizontal ? 8 : null,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        gradient: LinearGradient(
          // 横向从低温到高温；纵向按热像行业习惯让高温位于顶部。
          begin: horizontal ? Alignment.centerLeft : Alignment.bottomCenter,
          end: horizontal ? Alignment.centerRight : Alignment.topCenter,
          colors: colors,
        ),
      ),
    );
  }
}

class _SingleTemperature extends StatelessWidget {
  const _SingleTemperature({
    required this.value,
    required this.color,
    required this.reserveCloseSpace,
    required this.orientation,
  });

  final double value;
  final Color color;
  final bool reserveCloseSpace;
  final TemperatureLegendOrientation orientation;

  @override
  Widget build(BuildContext context) {
    if (orientation == TemperatureLegendOrientation.vertical) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (reserveCloseSpace) const SizedBox(height: 14),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
            ),
          ),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${_formatTemperature(value)} °C',
              maxLines: 1,
              style: _legendValueStyle.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (reserveCloseSpace) const SizedBox(width: 18),
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            '${_formatTemperature(value)} °C',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: _legendValueStyle.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (reserveCloseSpace) const SizedBox(width: 18),
      ],
    );
  }
}

List<Color> _decodeColors(List<int> rgb) {
  final count = rgb.length ~/ 3;
  if (count < 2) return const [];
  return [
    for (int i = 0; i < count; i++)
      Color.fromARGB(255, rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]),
  ];
}

String _formatTemperature(double value) {
  if (!value.isFinite) return '--';
  final magnitude = math.max(value.abs(), 1);
  if (magnitude >= 1000) return value.toStringAsFixed(0);
  return value.toStringAsFixed(1);
}

const TextStyle _legendTitleStyle = TextStyle(
  color: Colors.white,
  fontSize: 9.5,
  height: 1,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.1,
);

const TextStyle _legendValueStyle = TextStyle(
  color: Colors.white,
  fontSize: 9.5,
  height: 1,
  fontWeight: FontWeight.w600,
  fontFeatures: [FontFeature.tabularFigures()],
);
