/// 通用顶层 Toast (通用端).
///
/// 通过 [Overlay.of] (rootOverlay: true) 注入到根 Overlay, 因此始终位于
/// 所有 Stack/Dialog/毛玻璃覆盖物之上, 不会被遮挡.
///
/// 动画: 从屏幕左侧 "卷轴式" 水平展开 (宽度 0 → 自然宽度) + 透明度淡入;
/// 持续显示后反向收起, 再从 overlay 中移除.
///
/// 使用:
///   BananaToast.show(context, '序列号已复制');
library;

import 'dart:async';

import 'package:flutter/material.dart';

class BananaToast {
  BananaToast._();

  static OverlayEntry? _entry;

  /// 显示一条 toast. 若已存在一条, 先无动画地移除再展示新的.
  static void show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(milliseconds: 1800),
    IconData? icon = Icons.check_rounded,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _entry?.remove();
    _entry = null;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _BananaToastWidget(
        message: message,
        duration: duration,
        icon: icon,
        onDismissed: () {
          if (_entry == entry) _entry = null;
          entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class _BananaToastWidget extends StatefulWidget {
  final String message;
  final Duration duration;
  final IconData? icon;
  final VoidCallback onDismissed;

  const _BananaToastWidget({
    required this.message,
    required this.duration,
    required this.icon,
    required this.onDismissed,
  });

  @override
  State<_BananaToastWidget> createState() => _BananaToastWidgetState();
}

class _BananaToastWidgetState extends State<_BananaToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _size;
  late final Animation<double> _fade;
  Timer? _hold;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 340),
      reverseDuration: const Duration(milliseconds: 260),
      vsync: this,
    );
    _size = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
    _hold = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_disposed) return;
    _hold?.cancel();
    try {
      await _ctrl.reverse();
    } catch (_) {}
    if (_disposed) return;
    widget.onDismissed();
  }

  @override
  void dispose() {
    _disposed = true;
    _hold?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 顶部安全距离: 状态栏 + 一点空隙. 桌面上 padding.top=0, 用固定 16.
    final topInset = mq.padding.top + 16;
    return Positioned(
      left: 16,
      top: topInset,
      // 不拦截手势, 不影响下层 UI.
      child: IgnorePointer(
        ignoring: true,
        child: FadeTransition(
          opacity: _fade,
          child: SizeTransition(
            axis: Axis.horizontal,
            axisAlignment: -1.0, // 从左侧展开
            sizeFactor: _size,
            child: _ToastCard(message: widget.message, icon: widget.icon),
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  final String message;
  final IconData? icon;
  const _ToastCard({required this.message, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [scheme.primary, const Color(0xFFFFB199)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.25,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
                softWrap: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
