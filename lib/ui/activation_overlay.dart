/// 设备激活遮罩.
///
/// 通用端: 当串口连接成功 + 设备返回 `isActivated=false` 时, 在窗口/屏幕
/// 正中央弹出一个毛玻璃风格的激活对话框. 用户复制序列号、输入激活码,
/// 点 "激活" 后:
///   1. 发送 `activate <key>` 到设备
///   2. 1.5s 后主动 `GetSysInfo` 刷新激活状态
///   3. AppState.isActivated 变 true → Consumer 重建 → 遮罩自动消失
///
/// 与设备协议参见 D:\Github_project\全能上位机\thermal_dual_app.py 中的
/// `_do_activate` / `_handle_device_info`.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// 把整棵子树包起来; 满足条件时在正中央覆盖一层毛玻璃激活对话框.
class ActivationOverlay extends StatelessWidget {
  final Widget child;
  const ActivationOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Consumer<AppState>(
          builder: (ctx, app, _) {
            final needShow = app.status == ConnectionStatus.connected &&
                !app.isActivated &&
                (app.deviceSerial != null &&
                    app.deviceSerial!.isNotEmpty &&
                    app.deviceSerial != '未获取');
            if (!needShow) return const SizedBox.shrink();
            return Positioned.fill(
              child: _ActivationDialog(serial: app.deviceSerial!),
            );
          },
        ),
      ],
    );
  }
}

class _ActivationDialog extends StatefulWidget {
  final String serial;
  const _ActivationDialog({required this.serial});

  @override
  State<_ActivationDialog> createState() => _ActivationDialogState();
}

class _ActivationDialogState extends State<_ActivationDialog> {
  final TextEditingController _ctrl = TextEditingController();
  bool _busy = false;
  String? _hint; // 状态提示文本

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _copySerial() async {
    await Clipboard.setData(ClipboardData(text: widget.serial));
    if (!mounted) return;
    setState(() => _hint = '序列号已复制到剪贴板');
  }

  Future<void> _submit() async {
    final key = _ctrl.text.trim();
    if (key.isEmpty) {
      setState(() => _hint = '请输入激活码');
      return;
    }
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) {
      setState(() => _hint = '设备未连接');
      return;
    }
    setState(() {
      _busy = true;
      _hint = '正在激活...';
    });
    app.sendCommand('activate $key');
    // 与参考实现一致: 1.5s 后主动查询设备状态.
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    app.sendCommand('GetSysInfo');
    // 再给设备一点时间回复 JSON, AppState 监听到 isActivated=true 后,
    // 上层 Consumer 会自动卸载本弹窗.
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    setState(() {
      _busy = false;
      // 走到这里还在 = 没成功
      if (!context.read<AppState>().isActivated) {
        _hint = '激活失败, 请检查激活码后重试';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = (isDark ? Colors.black : Colors.white).withValues(
      alpha: 0.55,
    );
    final borderColor = scheme.outline.withValues(alpha: 0.3);

    return Stack(
      children: [
        // 全屏毛玻璃 + 半透明遮罩, 不可点击穿透.
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {}, // 拦截点击, 不穿透
              child: Container(
                color: (isDark ? Colors.black : Colors.white).withValues(
                  alpha: 0.25,
                ),
              ),
            ),
          ),
        ),
        // 居中卡片.
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: borderColor, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.22),
                          blurRadius: 32,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
                    child: _buildContent(scheme),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.verified_user_outlined,
                color: scheme.primary, size: 26),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '设备未激活',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Text(
          '请把下方设备序列号发给客服, 获取激活码后填入下方输入框完成激活.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 18),
        _LabeledBox(
          label: '设备序列号',
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  widget.serial,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制',
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: _copySerial,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _LabeledBox(
          label: '激活码',
          child: TextField(
            controller: _ctrl,
            enabled: !_busy,
            autofocus: true,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.symmetric(vertical: 4),
              hintText: '请输入激活码',
            ),
            onSubmitted: (_) => _busy ? null : _submit(),
          ),
        ),
        if (_hint != null) ...[
          const SizedBox(height: 10),
          Text(
            _hint!,
            style: TextStyle(
              fontSize: 12,
              color: _hint!.contains('失败')
                  ? scheme.error
                  : scheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => context.read<AppState>().disconnect(),
              child: const Text('断开'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.key_rounded, size: 18),
              label: Text(_busy ? '激活中' : '激活'),
            ),
          ],
        ),
      ],
    );
  }
}

class _LabeledBox extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledBox({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.6),
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }
}
