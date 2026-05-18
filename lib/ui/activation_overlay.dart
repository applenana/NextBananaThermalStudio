/// 设备激活遮罩 (通用端).
///
/// 当串口连接成功且设备返回 `isActivated=false` 时, 在窗口中央覆盖一层
/// 毛玻璃风格的提示卡片. 视觉风格与香蕉橙色主题 + 全局圆角 (14-20) 保持
/// 一致, 仅作为温和提醒.
///
/// 协议参考 (D:\Github_project\全能上位机\thermal_dual_app.py):
///   - 查询: `GetSysInfo\n` → JSON {SerialNum, isActivated, ...}
///   - 激活: `activate <key>\n` → 等 ~1.5s 后再次 GetSysInfo 刷新状态
///
/// 兼容自动 / 手动连接两种路径: 一旦 [AppState.status] = connected 且
/// `isActivated=false`, 立即展示卡片. 若此时 SerialNum 尚未到达, 显示占位
/// 并在卡片首次构建时再发一次 GetSysInfo, 兜底手动连接路径下 JSON 错过
/// 的极小概率.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

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
            final show =
                app.status == ConnectionStatus.connected && !app.isActivated;
            if (!show) return const SizedBox.shrink();
            return Positioned.fill(
              child: _ActivationCard(serial: app.deviceSerial),
            );
          },
        ),
      ],
    );
  }
}

class _ActivationCard extends StatefulWidget {
  /// null 或空字符串表示 SerialNum 还没回来.
  final String? serial;
  const _ActivationCard({required this.serial});

  @override
  State<_ActivationCard> createState() => _ActivationCardState();
}

class _ActivationCardState extends State<_ActivationCard> {
  final TextEditingController _ctrl = TextEditingController();
  bool _busy = false;
  String? _hint;
  bool _ok = false; // 提示是否为成功类
  bool _querySent = false;

  @override
  void initState() {
    super.initState();
    // 若首次出现时 SerialNum 还没回来, 主动再发一次, 兜底手动连接路径.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = context.read<AppState>();
      if (!_querySent &&
          app.status == ConnectionStatus.connected &&
          (app.deviceSerial == null || app.deviceSerial!.isEmpty)) {
        _querySent = true;
        app.sendCommand('GetSysInfo');
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _copySerial() async {
    final s = widget.serial;
    if (s == null || s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    if (!mounted) return;
    setState(() {
      _ok = true;
      _hint = '序列号已复制';
    });
  }

  Future<void> _submit() async {
    final key = _ctrl.text.trim();
    if (key.isEmpty) {
      setState(() {
        _ok = false;
        _hint = '请输入激活码';
      });
      return;
    }
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) {
      setState(() {
        _ok = false;
        _hint = '设备未连接';
      });
      return;
    }
    setState(() {
      _busy = true;
      _hint = '正在激活…';
      _ok = true;
    });
    app.sendCommand('activate $key');
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    app.sendCommand('GetSysInfo');
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!context.read<AppState>().isActivated) {
        _ok = false;
        _hint = '激活未成功, 请确认激活码后再试';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final cardBg = (isDark ? const Color(0xFF1F1A17) : Colors.white).withValues(
      alpha: isDark ? 0.78 : 0.82,
    );
    final borderColor = scheme.outlineVariant.withValues(alpha: 0.45);

    return Stack(
      children: [
        // 背景毛玻璃 + 半透蒙版.
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: Container(
                color: (isDark ? Colors.black : Colors.white).withValues(
                  alpha: 0.18,
                ),
              ),
            ),
          ),
        ),
        // 居中卡片.
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: borderColor, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.55 : 0.18,
                          ),
                          blurRadius: 28,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: _buildContent(theme),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部色带: 香蕉橙色渐变, 与 App Logo 同源.
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [scheme.primary, const Color(0xFFFFB199)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            children: [
              const Text('🍌', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '激活设备',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                '尚未激活',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '把下方序列号发给客服换取激活码, 填入即可启用设备.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: scheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: 14),
              _Field(
                label: '设备序列号',
                child: _SerialRow(serial: widget.serial, onCopy: _copySerial),
              ),
              const SizedBox(height: 10),
              _Field(
                label: '激活码',
                child: TextField(
                  controller: _ctrl,
                  enabled: !_busy,
                  autofocus: true,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 6),
                    hintText: '在此粘贴激活码',
                    hintStyle: TextStyle(fontSize: 13),
                  ),
                  onSubmitted: (_) => _busy ? null : _submit(),
                ),
              ),
              SizedBox(
                height: 22,
                child: _hint == null
                    ? null
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _hint!,
                            style: TextStyle(
                              fontSize: 12,
                              color: _ok ? scheme.primary : scheme.error,
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 6),
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
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.key_rounded, size: 18),
                    label: Text(_busy ? '激活中' : '激活'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SerialRow extends StatelessWidget {
  final String? serial;
  final VoidCallback onCopy;
  const _SerialRow({required this.serial, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = serial;
    final hasSerial = s != null && s.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: hasSerial
              ? SelectableText(
                  s,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '正在读取设备信息…',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
        ),
        IconButton(
          tooltip: hasSerial ? '复制' : '尚未获取',
          icon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: hasSerial ? onCopy : null,
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(
          alpha: isDark ? 0.05 : 0.035,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
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
              color: scheme.onSurface.withValues(alpha: 0.55),
              letterSpacing: 0.2,
            ),
          ),
          child,
        ],
      ),
    );
  }
}
