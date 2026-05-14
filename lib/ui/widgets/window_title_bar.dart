/// 自绘标题栏 (替代 Windows 原生 caption).
///
/// 配合 windows/runner/win32_window.cpp 中 WM_NCCALCSIZE / WM_NCHITTEST 处理
/// 使用——native 端去掉系统 caption + 保留边缘 resize, 这里在 Flutter 顶部画
/// 32px 高的自定义条, 包含 app 标识 + 拖拽区 + 最小化/最大化/关闭按钮.
///
/// 拖拽和窗口控制通过 [WindowSizeFfi] 调 user32 API 实现, 不依赖
/// window_manager 等可能与串口插件冲突的 native plugin.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../window_size_ffi.dart';

class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key});

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> {
  bool _maximized = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refreshMaxState();
    // 轻量轮询: 用户可能通过 Win+方向键 / 拖到屏幕边缘等系统手势改变最大化状态,
    // 这些路径不会经由我们的按钮, 因此用 1s 周期补足图标同步.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshMaxState());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _refreshMaxState() {
    final m = WindowSizeFfi.instance.isMaximized();
    if (m != _maximized && mounted) {
      setState(() => _maximized = m);
    }
  }

  void _onDragStart(DragStartDetails _) {
    WindowSizeFfi.instance.startSystemDrag();
  }

  void _toggleMax() {
    WindowSizeFfi.instance.toggleMaximize();
    // 系统消息异步, 推迟一帧再读
    Future.delayed(const Duration(milliseconds: 60), _refreshMaxState);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? const Color(0xFF0E1116)
        : const Color(0xFFF6F7FB);
    final fg = scheme.onSurface.withValues(alpha: 0.85);

    return SizedBox(
      height: 32,
      child: ColoredBox(
        color: bg,
        child: Row(
          children: [
            // 拖拽区 + 应用标识 (整个左/中区域可拖, 双击切换最大化)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: _onDragStart,
                onDoubleTap: _toggleMax,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [scheme.primary, const Color(0xFFFFB199)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Center(
                          child: Text('🍌', style: TextStyle(fontSize: 11)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'BananaThermalStudio',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: fg,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 三按钮
            _CaptionButton(
              tooltip: '最小化',
              onTap: () => WindowSizeFfi.instance.minimize(),
              child: _Glyph(_GlyphKind.minimize, color: fg),
            ),
            _CaptionButton(
              tooltip: _maximized ? '还原' : '最大化',
              onTap: _toggleMax,
              child: _Glyph(
                _maximized ? _GlyphKind.restore : _GlyphKind.maximize,
                color: fg,
              ),
            ),
            _CaptionButton(
              tooltip: '关闭',
              hoverColor: const Color(0xFFE81123),
              hoverFg: Colors.white,
              onTap: () => WindowSizeFfi.instance.close(),
              child: _Glyph(_GlyphKind.close, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.child,
    required this.onTap,
    required this.tooltip,
    this.hoverColor,
    this.hoverFg,
  });

  final Widget child;
  final VoidCallback onTap;
  final String tooltip;
  final Color? hoverColor;
  final Color? hoverFg;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final defaultHover = scheme.onSurface.withValues(alpha: 0.08);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: 46,
            height: 32,
            child: ColoredBox(
              color: _hover
                  ? (widget.hoverColor ?? defaultHover)
                  : Colors.transparent,
              child: Center(
                child: _hover && widget.hoverFg != null
                    ? IconTheme(
                        data: IconThemeData(color: widget.hoverFg),
                        child: widget.child,
                      )
                    : widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _GlyphKind { minimize, maximize, restore, close }

class _Glyph extends StatelessWidget {
  const _Glyph(this.kind, {required this.color});
  final _GlyphKind kind;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(10, 10),
      painter: _GlyphPainter(kind, color),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.kind, this.color);
  final _GlyphKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final w = size.width;
    final h = size.height;
    switch (kind) {
      case _GlyphKind.minimize:
        canvas.drawLine(
            Offset(0, h / 2 + 0.5), Offset(w, h / 2 + 0.5), paint);
        break;
      case _GlyphKind.maximize:
        canvas.drawRect(
            Rect.fromLTWH(0.5, 0.5, w - 1, h - 1), paint);
        break;
      case _GlyphKind.restore:
        // 前矩形
        canvas.drawRect(
            Rect.fromLTWH(0.5, 2.5, w - 3, h - 3), paint);
        // 后矩形 (右上偏移)
        final path = Path()
          ..moveTo(2.5, 2.0)
          ..lineTo(2.5, 0.5)
          ..lineTo(w - 0.5, 0.5)
          ..lineTo(w - 0.5, h - 2.5)
          ..lineTo(w - 2, h - 2.5);
        canvas.drawPath(path, paint);
        break;
      case _GlyphKind.close:
        canvas.drawLine(const Offset(0.5, 0.5),
            Offset(w - 0.5, h - 0.5), paint);
        canvas.drawLine(Offset(w - 0.5, 0.5),
            Offset(0.5, h - 0.5), paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter old) =>
      old.kind != kind || old.color != color;
}
