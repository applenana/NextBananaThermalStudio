/// 通用热像画布: 接收 RenderedFrame, 显示渲染后的 RGB 图, 并提供
/// 鼠标悬浮取温 / 十字光标 / 点击放置固定温度标记 / 信息条叠加.
///
/// 调用方传入已经渲染好的 [frame] (由 render_pipeline 产出), Canvas 只负责显示和交互.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../render/render_params.dart';
import '../../render/render_pipeline.dart';
import 'rgb_image_view.dart';
import 'temperature_color_legend.dart';

/// 固定温度标记 (像素坐标使用渲染后帧像素).
@immutable
class TempMarker {
  /// 帧像素坐标 (相对 frame.width / frame.height).
  final int px;
  final int py;
  final double temp;
  const TempMarker(this.px, this.py, this.temp);
}

class ThermalCanvas extends StatefulWidget {
  final RenderedFrame? frame;

  /// 是否启用鼠标悬浮取温 + 十字光标
  final bool showCursorTemp;

  /// 信息条 (Tmax/Tmin/Tavg) - 由父级决定是否传
  final Widget? infoBar;

  /// 占位提示
  final String placeholder;

  /// 已固定的温度标记 (帧像素坐标).
  final List<TempMarker> markers;

  /// 单击空白处时回调 (传入帧像素坐标 + 温度). 若不为 null 则启用点击添加.
  final void Function(int px, int py, double temp)? onAddMarker;

  /// 单击已存在的 marker 时回调 (传入索引). 可用来实现删除.
  final void Function(int index)? onRemoveMarker;

  /// 固定的单点测温光标。鼠标移出画面后仍会保留。
  final TempMarker? fixedCursor;

  /// 单击画面时更新固定单点测温光标。
  final void Function(int px, int py, double temp)? onSetFixedCursor;

  /// 是否叠加最高温像素角标 (橙黄 ▼ + H 标签). 与 [markers] 风格独立,
  /// 仅展示、不接受点击.
  final bool showHotSpot;

  /// 是否叠加最低温像素角标 (冰青 ▲ + L 标签).
  final bool showColdSpot;

  /// 是否在真实热像画面范围内叠加温度色标。
  final bool showTemperatureLegend;

  /// 温度色标的排布方向。
  final TemperatureLegendOrientation temperatureLegendOrientation;

  /// 温度色标停靠在画面左侧或右侧。
  final TemperatureLegendSide temperatureLegendSide;

  /// 图例卡片背景透明度；100 时视觉上仅保留温度彩条。
  final int temperatureLegendTransparency;

  /// 色标相对真实图像边缘的安全间距。
  final EdgeInsets temperatureLegendInsets;

  /// 点击色标右上角关闭按钮时回调。为 null 时不显示关闭按钮。
  final VoidCallback? onCloseTemperatureLegend;

  const ThermalCanvas({
    super.key,
    required this.frame,
    this.showCursorTemp = true,
    this.infoBar,
    this.placeholder = '等待数据…',
    this.markers = const [],
    this.onAddMarker,
    this.onRemoveMarker,
    this.fixedCursor,
    this.onSetFixedCursor,
    this.showHotSpot = false,
    this.showColdSpot = false,
    this.showTemperatureLegend = false,
    this.temperatureLegendOrientation = TemperatureLegendOrientation.horizontal,
    this.temperatureLegendSide = TemperatureLegendSide.left,
    this.temperatureLegendTransparency = 75,
    this.temperatureLegendInsets = const EdgeInsets.all(12),
    this.onCloseTemperatureLegend,
  });

  @override
  State<ThermalCanvas> createState() => _ThermalCanvasState();
}

class _ThermalCanvasState extends State<ThermalCanvas>
    with SingleTickerProviderStateMixin {
  Offset? _hoverLocal;
  late final AnimationController _extremeController;
  _ExtremeSpot? _hotFrom;
  _ExtremeSpot? _hotTo;
  _ExtremeSpot? _coldFrom;
  _ExtremeSpot? _coldTo;
  Offset? _temperatureLegendOffset;

  @override
  void initState() {
    super.initState();
    _extremeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      value: 1,
    );
    _updateExtremeTargets(widget.frame, animate: false);
  }

  @override
  void didUpdateWidget(covariant ThermalCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fixedCursor != null && widget.fixedCursor == null) {
      _hoverLocal = null;
    }
    if (oldWidget.temperatureLegendOrientation !=
            widget.temperatureLegendOrientation ||
        oldWidget.temperatureLegendSide != widget.temperatureLegendSide) {
      _temperatureLegendOffset = null;
    }
    if (oldWidget.frame != widget.frame) {
      _updateExtremeTargets(widget.frame, animate: true);
    }
  }

  @override
  void dispose() {
    _extremeController.dispose();
    super.dispose();
  }

  void _updateExtremeTargets(RenderedFrame? frame, {required bool animate}) {
    final targets = _findExtremeSpots(frame);
    if (targets.hot == null || targets.cold == null) {
      _extremeController.stop();
      _hotFrom = _hotTo = null;
      _coldFrom = _coldTo = null;
      return;
    }

    if (!animate || _hotTo == null || _coldTo == null) {
      _hotFrom = _hotTo = targets.hot;
      _coldFrom = _coldTo = targets.cold;
      _extremeController.value = 1;
      return;
    }

    final progress = Curves.easeOutCubic.transform(_extremeController.value);
    _hotFrom = _ExtremeSpot.lerp(_hotFrom!, _hotTo!, progress);
    _coldFrom = _ExtremeSpot.lerp(_coldFrom!, _coldTo!, progress);
    _hotTo = targets.hot;
    _coldTo = targets.cold;
    _extremeController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final frame = widget.frame;

    if (frame == null) {
      return Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.thermostat_outlined,
                size: 48,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 8),
              Text(
                widget.placeholder,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final boxAspect = c.maxWidth / c.maxHeight;
        final imgAspect = frame.width / frame.height;
        double w, h;
        if (imgAspect > boxAspect) {
          w = c.maxWidth;
          h = w / imgAspect;
        } else {
          h = c.maxHeight;
          w = h * imgAspect;
        }
        final origin = Offset((c.maxWidth - w) / 2, (c.maxHeight - h) / 2);

        void handleTap(Offset localPos) {
          final relX = localPos.dx - origin.dx;
          final relY = localPos.dy - origin.dy;
          if (relX < 0 || relY < 0 || relX > w || relY > h) return;
          final px = (relX / w * frame.width).floor().clamp(0, frame.width - 1);
          final py = (relY / h * frame.height).floor().clamp(
            0,
            frame.height - 1,
          );

          if (widget.onRemoveMarker != null) {
            final hitFx = (8 / w * frame.width).ceil().clamp(1, 999);
            final hitFy = (8 / h * frame.height).ceil().clamp(1, 999);
            for (var i = 0; i < widget.markers.length; i++) {
              final m = widget.markers[i];
              if ((m.px - px).abs() <= hitFx && (m.py - py).abs() <= hitFy) {
                widget.onRemoveMarker!(i);
                return;
              }
            }
          }

          if (widget.onAddMarker != null) {
            final temp = frame.temperatureField[py * frame.width + px];
            widget.onAddMarker!(px, py, temp);
          }
          if (widget.onSetFixedCursor != null) {
            final temp = frame.temperatureField[py * frame.width + px];
            widget.onSetFixedCursor!(px, py, temp);
          }
        }

        return Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor:
                    (widget.onAddMarker != null ||
                        widget.onSetFixedCursor != null)
                    ? SystemMouseCursors.precise
                    : SystemMouseCursors.basic,
                onHover: widget.showCursorTemp
                    ? (e) => setState(() => _hoverLocal = e.localPosition)
                    : null,
                onExit: widget.showCursorTemp
                    ? (_) => setState(() => _hoverLocal = null)
                    : null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown:
                      (widget.onAddMarker != null ||
                          widget.onRemoveMarker != null ||
                          widget.onSetFixedCursor != null)
                      ? (d) => handleTap(d.localPosition)
                      : (widget.showCursorTemp
                            // 触屏单点跟随测温: 没有 hover 时, 用 tap 落点更新十字.
                            ? (d) =>
                                  setState(() => _hoverLocal = d.localPosition)
                            : null),
                  // 触屏单点跟随测温: 通过 Pan 持续更新十字位置 (类 PC 端鼠标移动).
                  // 仅在不冲突 marker 添加/删除时启用, 由父级通过 onAddMarker=null
                  // 切换到该模式.
                  onPanStart: widget.onSetFixedCursor != null
                      ? (d) => handleTap(d.localPosition)
                      : (widget.showCursorTemp &&
                            widget.onAddMarker == null &&
                            widget.onRemoveMarker == null)
                      ? (d) => setState(() => _hoverLocal = d.localPosition)
                      : null,
                  onPanUpdate: widget.onSetFixedCursor != null
                      ? (d) => handleTap(d.localPosition)
                      : (widget.showCursorTemp &&
                            widget.onAddMarker == null &&
                            widget.onRemoveMarker == null)
                      ? (d) => setState(() => _hoverLocal = d.localPosition)
                      : null,
                  child: RgbImageView(
                    rgb: frame.rgb,
                    width: frame.width,
                    height: frame.height,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.none,
                  ),
                ),
              ),
            ),
            if (widget.markers.isNotEmpty)
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _MarkersPainter(
                      markers: widget.markers,
                      frameWidth: frame.width,
                      frameHeight: frame.height,
                    ),
                  ),
                ),
              ),
            if (widget.showHotSpot || widget.showColdSpot)
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ExtremesPainter(
                      progress: _extremeController,
                      hotFrom: _hotFrom,
                      hotTo: _hotTo,
                      coldFrom: _coldFrom,
                      coldTo: _coldTo,
                      showHot: widget.showHotSpot,
                      showCold: widget.showColdSpot,
                    ),
                  ),
                ),
              ),
            if (widget.showCursorTemp &&
                (widget.fixedCursor != null || _hoverLocal != null))
              _buildCursorOverlay(frame, origin, Size(w, h)),
            if (widget.showTemperatureLegend && frame.hasFiniteTemperatureData)
              _buildTemperatureLegend(frame, origin, Size(w, h)),
            if (widget.infoBar != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: widget.infoBar!,
              ),
          ],
        );
      },
    );
  }

  Widget _buildCursorOverlay(RenderedFrame frame, Offset origin, Size imgSize) {
    final fixed = widget.fixedCursor;
    late final double relX;
    late final double relY;
    late final double temp;
    if (fixed != null &&
        fixed.px >= 0 &&
        fixed.px < frame.width &&
        fixed.py >= 0 &&
        fixed.py < frame.height) {
      relX = (fixed.px + 0.5) / frame.width * imgSize.width;
      relY = (fixed.py + 0.5) / frame.height * imgSize.height;
      temp = fixed.temp;
    } else {
      final hover = _hoverLocal!;
      relX = hover.dx - origin.dx;
      relY = hover.dy - origin.dy;
      if (relX < 0 ||
          relY < 0 ||
          relX > imgSize.width ||
          relY > imgSize.height) {
        return const SizedBox.shrink();
      }
      final px = (relX / imgSize.width * frame.width).floor().clamp(
        0,
        frame.width - 1,
      );
      final py = (relY / imgSize.height * frame.height).floor().clamp(
        0,
        frame.height - 1,
      );
      temp = frame.temperatureField[py * frame.width + px];
    }

    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: imgSize.width,
      height: imgSize.height,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _CrossPainter(
            x: relX,
            y: relY,
            temp: temp,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }

  Widget _buildTemperatureLegend(
    RenderedFrame frame,
    Offset origin,
    Size imgSize,
  ) {
    final insets = widget.temperatureLegendInsets;
    final availableWidth = math.max(
      0.0,
      imgSize.width - insets.left - insets.right,
    );
    final availableHeight = math.max(
      0.0,
      imgSize.height - insets.top - insets.bottom,
    );
    final horizontal =
        widget.temperatureLegendOrientation ==
        TemperatureLegendOrientation.horizontal;
    final bareGradient = widget.temperatureLegendTransparency >= 100;

    late final double legendWidth;
    late final double legendHeight;
    late double left;
    late double top;

    if (horizontal) {
      if (availableWidth < 112 || availableHeight < 24) {
        return const SizedBox.shrink();
      }
      legendWidth = math.min(availableWidth, imgSize.width < 420 ? 160 : 190);
      legendHeight = bareGradient ? 24 : 30;
      left = widget.temperatureLegendSide == TemperatureLegendSide.left
          ? origin.dx + insets.left
          : origin.dx + imgSize.width - insets.right - legendWidth;
      top = origin.dy + imgSize.height - insets.bottom - legendHeight;
    } else {
      if (availableWidth < 24 || availableHeight < 96) {
        return const SizedBox.shrink();
      }
      legendWidth = math.min(bareGradient ? 24 : 48, availableWidth);
      legendHeight = math.min(bareGradient ? 180 : 210, availableHeight);
      left = widget.temperatureLegendSide == TemperatureLegendSide.left
          ? origin.dx + insets.left
          : origin.dx + imgSize.width - insets.right - legendWidth;
      top = origin.dy + insets.top + (availableHeight - legendHeight) / 2;
    }

    final minLeft = origin.dx + 4;
    final maxLeft = origin.dx + imgSize.width - legendWidth - 4;
    final minTop = origin.dy + 4;
    final maxTop = origin.dy + imgSize.height - legendHeight - 4;

    Offset clampOffset(Offset value) {
      return Offset(
        math.max(minLeft, math.min(maxLeft, value.dx)),
        math.max(minTop, math.min(maxTop, value.dy)),
      );
    }

    final storedOffset = _temperatureLegendOffset;
    if (storedOffset != null) {
      final clamped = clampOffset(storedOffset);
      left = clamped.dx;
      top = clamped.dy;
    }

    void dragLegend(DragUpdateDetails details) {
      final current = Offset(left, top);
      setState(() {
        _temperatureLegendOffset = clampOffset(current + details.delta);
      });
    }

    return Positioned(
      left: left,
      top: top,
      width: legendWidth,
      height: legendHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: dragLegend,
                child: TemperatureColorLegend(
                  frame: frame,
                  orientation: widget.temperatureLegendOrientation,
                  transparencyPercent: widget.temperatureLegendTransparency,
                  reserveCloseSpace: widget.onCloseTemperatureLegend != null,
                ),
              ),
            ),
          ),
          if (!bareGradient && widget.onCloseTemperatureLegend != null)
            Positioned(
              top: horizontal ? 3 : 22,
              right: horizontal ? 3 : 2,
              child: _LegendCloseButton(
                onTap: widget.onCloseTemperatureLegend!,
                compact: !horizontal,
              ),
            ),
        ],
      ),
    );
  }
}

class _LegendCloseButton extends StatelessWidget {
  const _LegendCloseButton({required this.onTap, required this.compact});

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '关闭温度图例',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: compact ? 16 : 20,
            height: compact ? 16 : 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.close_rounded,
              size: compact ? 11 : 13,
              color: Colors.white.withValues(alpha: 0.78),
            ),
          ),
        ),
      ),
    );
  }
}

class _CrossPainter extends CustomPainter {
  final double x, y;
  final double temp;
  final Color color;

  _CrossPainter({
    required this.x,
    required this.y,
    required this.temp,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);

    final tp = TextPainter(
      text: TextSpan(
        text: '${temp.toStringAsFixed(1)} °C',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFamily: 'SmileySans',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final bx = (x + 10).clamp(0.0, size.width - tp.width - 10);
    final by = (y + 10).clamp(0.0, size.height - tp.height - 8);
    final rect = Rect.fromLTWH(bx - 4, by - 2, tp.width + 8, tp.height + 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
    tp.paint(canvas, Offset(bx, by));
  }

  @override
  bool shouldRepaint(covariant _CrossPainter o) =>
      o.x != x || o.y != y || o.temp != temp;
}

class _MarkersPainter extends CustomPainter {
  final List<TempMarker> markers;
  final int frameWidth;
  final int frameHeight;

  _MarkersPainter({
    required this.markers,
    required this.frameWidth,
    required this.frameHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / frameWidth;
    final sy = size.height / frameHeight;

    for (final m in markers) {
      final x = (m.px + 0.5) * sx;
      final y = (m.py + 0.5) * sy;

      canvas.drawCircle(
        Offset(x, y),
        7,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        Offset(x, y),
        4.5,
        Paint()..color = const Color(0xFFFF5252),
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '${m.temp.toStringAsFixed(1)} °C',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFamily: 'SmileySans',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final bx = (x + 10).clamp(0.0, size.width - tp.width - 10);
      final by = (y - tp.height - 6).clamp(0.0, size.height - tp.height - 4);
      final rect = Rect.fromLTWH(bx - 4, by - 2, tp.width + 8, tp.height + 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = Colors.black.withValues(alpha: 0.7),
      );
      tp.paint(canvas, Offset(bx, by));
    }
  }

  @override
  bool shouldRepaint(covariant _MarkersPainter o) =>
      o.markers != markers ||
      o.frameWidth != frameWidth ||
      o.frameHeight != frameHeight;
}

class _ExtremeSpot {
  final double nx;
  final double ny;
  final double temp;

  const _ExtremeSpot({required this.nx, required this.ny, required this.temp});

  static _ExtremeSpot lerp(_ExtremeSpot a, _ExtremeSpot b, double t) {
    return _ExtremeSpot(
      nx: a.nx + (b.nx - a.nx) * t,
      ny: a.ny + (b.ny - a.ny) * t,
      temp: a.temp + (b.temp - a.temp) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _ExtremeSpot &&
      other.nx == nx &&
      other.ny == ny &&
      other.temp == temp;

  @override
  int get hashCode => Object.hash(nx, ny, temp);
}

({_ExtremeSpot? hot, _ExtremeSpot? cold}) _findExtremeSpots(
  RenderedFrame? frame,
) {
  if (frame == null || frame.temperatureField.isEmpty) {
    return (hot: null, cold: null);
  }

  final field = frame.temperatureField;
  int hotIdx = -1;
  int coldIdx = -1;
  double hot = -double.infinity;
  double cold = double.infinity;
  for (int i = 0; i < field.length; i++) {
    final v = field[i];
    if (!v.isFinite) continue;
    if (v > hot) {
      hot = v;
      hotIdx = i;
    }
    if (v < cold) {
      cold = v;
      coldIdx = i;
    }
  }
  if (hotIdx < 0 || coldIdx < 0) return (hot: null, cold: null);

  final width = frame.width;
  final height = frame.height;
  return (
    hot: _ExtremeSpot(
      nx: (hotIdx % width + 0.5) / width,
      ny: (hotIdx ~/ width + 0.5) / height,
      temp: hot,
    ),
    cold: _ExtremeSpot(
      nx: (coldIdx % width + 0.5) / width,
      ny: (coldIdx ~/ width + 0.5) / height,
      temp: cold,
    ),
  );
}

/// 最高 / 最低温像素角标. 风格独立于 [_MarkersPainter] 的圆形多点标签:
///   - 最高: 红色等腰三角 ▼ (尖端指向像素), 标签 `H 42.5°`
///   - 最低: 蓝色等腰三角 ▲ (尖端指向像素), 标签 `L 18.2°`
/// 标签字体小一号, 加细描边阴影; 坐标以 140ms ease-out 动画快速跟随.
class _ExtremesPainter extends CustomPainter {
  final Animation<double> progress;
  final _ExtremeSpot? hotFrom;
  final _ExtremeSpot? hotTo;
  final _ExtremeSpot? coldFrom;
  final _ExtremeSpot? coldTo;
  final bool showHot;
  final bool showCold;

  _ExtremesPainter({
    required this.progress,
    required this.hotFrom,
    required this.hotTo,
    required this.coldFrom,
    required this.coldTo,
    required this.showHot,
    required this.showCold,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (!showHot && !showCold) return;
    final t = Curves.easeOutCubic.transform(progress.value);

    if (showHot && hotFrom != null && hotTo != null) {
      final spot = _ExtremeSpot.lerp(hotFrom!, hotTo!, t);
      _paintSpot(
        canvas,
        size,
        anchor: Offset(spot.nx * size.width, spot.ny * size.height),
        color: const Color(0xFFFFCC00),
        tip: 'H ${spot.temp.toStringAsFixed(1)}°',
        hot: true,
      );
    }
    if (showCold && coldFrom != null && coldTo != null) {
      final spot = _ExtremeSpot.lerp(coldFrom!, coldTo!, t);
      _paintSpot(
        canvas,
        size,
        anchor: Offset(spot.nx * size.width, spot.ny * size.height),
        color: const Color(0xFF80D8FF),
        tip: 'L ${spot.temp.toStringAsFixed(1)}°',
        hot: false,
      );
    }
  }

  void _paintSpot(
    Canvas canvas,
    Size size, {
    required Offset anchor,
    required Color color,
    required String tip,
    required bool hot,
  }) {
    // 三角形尖端指向 anchor 像素. 边长 ~7px (紧凑).
    const double r = 4;
    final path = Path();
    if (hot) {
      // ▼ 顶点向下指向 anchor
      path.moveTo(anchor.dx, anchor.dy);
      path.lineTo(anchor.dx - r, anchor.dy - r * 1.4);
      path.lineTo(anchor.dx + r, anchor.dy - r * 1.4);
      path.close();
    } else {
      // ▲ 顶点向上指向 anchor
      path.moveTo(anchor.dx, anchor.dy);
      path.lineTo(anchor.dx - r, anchor.dy + r * 1.4);
      path.lineTo(anchor.dx + r, anchor.dy + r * 1.4);
      path.close();
    }
    // 黑色描边 + 彩色填充, 区分背景
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = color);

    // 中心小圆点强调像素中心
    canvas.drawCircle(
      anchor,
      1.0,
      Paint()..color = Colors.black.withValues(alpha: 0.85),
    );

    // 标签: 放在三角形远端 (热=上方, 冷=下方), 文字白描黑边
    final tp = TextPainter(
      text: TextSpan(
        text: tip,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          fontFamily: 'SmileySans',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lx = (anchor.dx - tp.width / 2).clamp(2.0, size.width - tp.width - 2);
    final ly = hot
        ? (anchor.dy - r * 1.4 - tp.height - 2)
        : (anchor.dy + r * 1.4 + 2);
    final lyClamped = ly.clamp(2.0, size.height - tp.height - 2);
    final rect = Rect.fromLTWH(
      lx - 4,
      lyClamped - 1,
      tp.width + 8,
      tp.height + 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = Colors.black.withValues(alpha: 0.65),
    );
    tp.paint(canvas, Offset(lx, lyClamped));
  }

  @override
  bool shouldRepaint(covariant _ExtremesPainter o) =>
      o.hotFrom != hotFrom ||
      o.hotTo != hotTo ||
      o.coldFrom != coldFrom ||
      o.coldTo != coldTo ||
      o.showHot != showHot ||
      o.showCold != showCold;
}
