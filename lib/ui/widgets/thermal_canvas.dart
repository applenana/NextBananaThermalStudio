/// 通用热像画布: 接收 RenderedFrame, 显示渲染后的 RGB 图, 并提供
/// 鼠标悬浮取温 / 十字光标 / 点击放置固定温度标记 / 信息条叠加.
///
/// 调用方传入已经渲染好的 [frame] (由 render_pipeline 产出), Canvas 只负责显示和交互.
library;

import 'package:flutter/material.dart';

import '../../render/render_pipeline.dart';
import 'rgb_image_view.dart';

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

  /// 是否在画面上叠加最高/最低温像素角标 (与 [markers] 风格独立, 仅展示
  /// 用、不接受点击). 用于 "主画面 H/L 角标" 功能.
  final bool showExtremeSpots;

  const ThermalCanvas({
    super.key,
    required this.frame,
    this.showCursorTemp = true,
    this.infoBar,
    this.placeholder = '等待数据…',
    this.markers = const [],
    this.onAddMarker,
    this.onRemoveMarker,
    this.showExtremeSpots = false,
  });

  @override
  State<ThermalCanvas> createState() => _ThermalCanvasState();
}

class _ThermalCanvasState extends State<ThermalCanvas> {
  Offset? _hoverLocal;

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
              Text(widget.placeholder,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 13)),
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
        final origin = Offset(
          (c.maxWidth - w) / 2,
          (c.maxHeight - h) / 2,
        );

        void handleTap(Offset localPos) {
          final relX = localPos.dx - origin.dx;
          final relY = localPos.dy - origin.dy;
          if (relX < 0 || relY < 0 || relX > w || relY > h) return;
          final px = (relX / w * frame.width).floor().clamp(0, frame.width - 1);
          final py = (relY / h * frame.height).floor().clamp(0, frame.height - 1);

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
        }

        return Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: widget.onAddMarker != null
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
                  onTapDown: (widget.onAddMarker != null ||
                          widget.onRemoveMarker != null)
                      ? (d) => handleTap(d.localPosition)
                      : (widget.showCursorTemp
                          // 触屏单点跟随测温: 没有 hover 时, 用 tap 落点更新十字.
                          ? (d) =>
                              setState(() => _hoverLocal = d.localPosition)
                          : null),
                  // 触屏单点跟随测温: 通过 Pan 持续更新十字位置 (类 PC 端鼠标移动).
                  // 仅在不冲突 marker 添加/删除时启用, 由父级通过 onAddMarker=null
                  // 切换到该模式.
                  onPanStart: (widget.showCursorTemp &&
                          widget.onAddMarker == null &&
                          widget.onRemoveMarker == null)
                      ? (d) => setState(() => _hoverLocal = d.localPosition)
                      : null,
                  onPanUpdate: (widget.showCursorTemp &&
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
            if (widget.showExtremeSpots)
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ExtremesPainter(
                      frame: frame,
                    ),
                  ),
                ),
              ),
            if (widget.showCursorTemp && _hoverLocal != null)
              _buildCursorOverlay(frame, origin, Size(w, h)),
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
    final hover = _hoverLocal!;
    final relX = hover.dx - origin.dx;
    final relY = hover.dy - origin.dy;
    if (relX < 0 || relY < 0 || relX > imgSize.width || relY > imgSize.height) {
      return const SizedBox.shrink();
    }
    final px = (relX / imgSize.width * frame.width).floor().clamp(0, frame.width - 1);
    final py = (relY / imgSize.height * frame.height).floor().clamp(0, frame.height - 1);
    final temp = frame.temperatureField[py * frame.width + px];

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

/// 最高 / 最低 温像素角标. 风格独立于 [_MarkersPainter] 的圆形多点标签:
///   - 最高: 红色等腰三角 ▼ (尖端指向像素), 标签 `H 42.5°`
///   - 最低: 蓝色等腰三角 ▲ (尖端指向像素), 标签 `L 18.2°`
/// 标签字体小一号, 加细描边阴影; 仅展示, 不响应事件.
class _ExtremesPainter extends CustomPainter {
  final RenderedFrame frame;
  _ExtremesPainter({required this.frame});

  @override
  void paint(Canvas canvas, Size size) {
    final field = frame.temperatureField;
    if (field.isEmpty) return;

    int hotIdx = -1, coldIdx = -1;
    double hot = -double.infinity, cold = double.infinity;
    for (int i = 0; i < field.length; i++) {
      final v = field[i];
      if (v.isNaN) continue;
      if (v > hot) {
        hot = v;
        hotIdx = i;
      }
      if (v < cold) {
        cold = v;
        coldIdx = i;
      }
    }
    if (hotIdx < 0 || coldIdx < 0) return;

    final fw = frame.width;
    final fh = frame.height;
    final sx = size.width / fw;
    final sy = size.height / fh;

    final hx = (hotIdx % fw + 0.5) * sx;
    final hy = (hotIdx ~/ fw + 0.5) * sy;
    final cx = (coldIdx % fw + 0.5) * sx;
    final cy = (coldIdx ~/ fw + 0.5) * sy;

    _paintSpot(
      canvas,
      size,
      anchor: Offset(hx, hy),
      color: const Color(0xFFFFCC00), // 醒目橙黄, 区分于 marker 的红
      tip: 'H ${hot.toStringAsFixed(1)}°',
      hot: true,
    );
    _paintSpot(
      canvas,
      size,
      anchor: Offset(cx, cy),
      color: const Color(0xFF80D8FF), // 冷亮青, 区分于 marker 蓝
      tip: 'L ${cold.toStringAsFixed(1)}°',
      hot: false,
    );
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
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
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
    final rect = Rect.fromLTWH(lx - 3, lyClamped - 1, tp.width + 6, tp.height + 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2.5)),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
    tp.paint(canvas, Offset(lx, lyClamped));
  }

  @override
  bool shouldRepaint(covariant _ExtremesPainter o) => o.frame != frame;
}
