/// 设备激活提示 (通用端).
///
/// 串口已连接且设备 `isActivated=false` 时, 在窗口中央覆盖一层半透 scrim,
/// 上面放一张常规风格的 Material 卡片提示用户激活设备. 提供:
///   - 可复制的设备序列号
///   - 闲鱼售后链接: https://fishflow.applenana.fun/aftersale (用订单号自助)
///   - DIY 用户 QQ 群: 1002979587 (找群主)
///   - 激活码输入框 + 激活按钮
///
/// 协议参考 (D:\Github_project\全能上位机\thermal_dual_app.py):
///   - 查询: `GetSysInfo\n` → JSON {SerialNum, isActivated, ...}
///   - 激活: `activate <key>\n` → 等 ~1.5s 后再次 GetSysInfo 刷新状态
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import 'banana_toast.dart';

const String _kAftersaleUrl = 'https://fishflow.applenana.fun/aftersale';
const String _kQqGroup = '1002979587';

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
            // 必须先收到 GetSysInfo JSON 响应 (deviceInfo != null) 才能判定
            // 激活状态. 否则手动连接刚 connected, isActivated 默认 false,
            // 会在 SN/激活状态都还没拿到时就误弹激活框.
            final show =
                app.status == ConnectionStatus.connected &&
                app.deviceInfo != null &&
                !app.isActivated;
            if (!show) return const SizedBox.shrink();
            return Positioned.fill(
              child: _ActivationDialog(serial: app.deviceSerial),
            );
          },
        ),
      ],
    );
  }
}

class _ActivationDialog extends StatefulWidget {
  final String? serial;
  const _ActivationDialog({required this.serial});

  @override
  State<_ActivationDialog> createState() => _ActivationDialogState();
}

class _ActivationDialogState extends State<_ActivationDialog> {
  final TextEditingController _ctrl = TextEditingController();
  bool _busy = false;
  String? _errorMsg;
  Timer? _serialPollTimer;
  int _serialRetry = 0;
  static const int _kMaxSerialRetry = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 首次立即请求 (补发一次 GetSysInfo), 如果~1.2s 后仍未拿到
      // 才进入 3s 重试循环, 避免正常路径频繁重复轮询.
      _requestSerialIfMissing();
      _scheduleFirstFollowUp();
    });
  }

  void _scheduleFirstFollowUp() {
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      final s = context.read<AppState>().deviceSerial;
      if (s != null && s.isNotEmpty) return;
      _requestSerialIfMissing();
      _startSerialPolling();
    });
  }

  void _requestSerialIfMissing() {
    if (!mounted) return;
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) return;
    final s = app.deviceSerial;
    if (s == null || s.isEmpty) {
      app.sendCommand('GetSysInfo');
    }
  }

  /// 序列号每 3s 轮询一次, 直到拿到或达到上限 (避免无限刷).
  void _startSerialPolling() {
    _serialPollTimer?.cancel();
    _serialPollTimer = Timer.periodic(const Duration(seconds: 3), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final app = context.read<AppState>();
      final s = app.deviceSerial;
      if (s != null && s.isNotEmpty) {
        t.cancel();
        return;
      }
      if (_serialRetry >= _kMaxSerialRetry) {
        t.cancel();
        return;
      }
      _serialRetry++;
      if (app.status == ConnectionStatus.connected) {
        app.sendCommand('GetSysInfo');
      }
    });
  }

  @override
  void dispose() {
    _serialPollTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    BananaToast.show(context, msg);
  }

  Future<void> _copy(String text, String okMsg) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast(okMsg);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _toast('链接不合法');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        await Clipboard.setData(ClipboardData(text: url));
        _toast('无法启动浏览器, 链接已复制');
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      _toast('无法启动浏览器, 链接已复制');
    }
  }

  Future<void> _showErrorDialog(String message) async {
    if (!mounted) return;
    setState(() => _errorMsg = message);
  }

  void _dismissError() {
    if (!mounted) return;
    setState(() => _errorMsg = null);
  }

  Future<void> _submit() async {
    final key = _ctrl.text.trim();
    if (key.isEmpty) {
      _toast('请输入激活码');
      return;
    }
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) {
      _toast('设备未连接');
      return;
    }
    setState(() => _busy = true);
    app.sendCommand('activate $key');
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    app.sendCommand('GetSysInfo');
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    setState(() => _busy = false);
    if (!context.read<AppState>().isActivated) {
      await _showErrorDialog('激活码不正确或设备未确认, 请确认后再试.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Stack(
      children: [
        // 背景毛玻璃 + 半透深色 scrim, 拦截点击.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.32)),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Material(
                color: scheme.surface,
                elevation: 6,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  child: _buildContent(theme),
                ),
              ),
            ),
          ),
        ),
        if (_errorMsg != null)
          Positioned.fill(
            child: _ErrorLayer(message: _errorMsg!, onDismiss: _dismissError),
          ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    final scheme = theme.colorScheme;
    final subStyle = TextStyle(
      fontSize: 13,
      height: 1.55,
      color: scheme.onSurface.withValues(alpha: 0.78),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.lock_outline_rounded, color: scheme.primary, size: 22),
            const SizedBox(width: 8),
            Text(
              '设备尚未激活',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('把下方序列号交给客服, 获取激活码后填入即可使用.', style: subStyle),
        const SizedBox(height: 16),
        _SerialBox(serial: widget.serial, onCopy: _copy),
        const SizedBox(height: 14),
        _SectionTitle(text: '获取激活码'),
        const SizedBox(height: 6),
        _BulletLine(
          index: 1,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              Text('闲鱼购买:', style: subStyle),
              _LinkInline(
                text: _kAftersaleUrl,
                tooltip: '在浏览器中打开',
                onTap: () => _openUrl(_kAftersaleUrl),
              ),
              Text('凭订单号自助获取.', style: subStyle),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _BulletLine(
          index: 2,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              Text('DIY 用户: 加 QQ 群', style: subStyle),
              _CopyableInline(
                text: _kQqGroup,
                tooltip: '复制群号',
                onCopy: () => _copy(_kQqGroup, '群号已复制'),
              ),
              Text('联系群主获取.', style: subStyle),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
          decoration: const InputDecoration(
            labelText: '激活码',
            hintText: '在此粘贴激活码',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _busy ? null : _submit(),
        ),
        const SizedBox(height: 16),
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
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('激活'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SerialBox extends StatelessWidget {
  final String? serial;
  final Future<void> Function(String text, String okMsg) onCopy;
  const _SerialBox({required this.serial, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = serial;
    final has = s != null && s.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '设备序列号',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 2),
                if (has)
                  SelectableText(
                    s,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  )
                else
                  Row(
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
                        '正在读取…',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: has ? '复制序列号' : '尚未获取',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: has ? () => onCopy(s, '序列号已复制') : null,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface.withValues(alpha: 0.6),
        letterSpacing: 0.3,
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  final int index;
  final Widget child;
  const _BulletLine({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Text(
              '$index.',
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _CopyableInline extends StatelessWidget {
  final String text;
  final String tooltip;
  final VoidCallback onCopy;
  const _CopyableInline({
    required this.text,
    required this.tooltip,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onCopy,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 3),
              Icon(Icons.copy_rounded, size: 13, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkInline extends StatelessWidget {
  final String text;
  final String tooltip;
  final VoidCallback onTap;
  const _LinkInline({
    required this.text,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: scheme.primary,
                ),
              ),
              const SizedBox(width: 3),
              Icon(Icons.open_in_new_rounded, size: 13, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 叠加在激活弹窗之上的错误提示层 (非 Navigator 路由, 避免 Windows release
/// 模式下 BackdropFilter + showDialog 的渲染兼容问题).
class _ErrorLayer extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;
  const _ErrorLayer({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Material(
                color: scheme.surface,
                elevation: 8,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: scheme.error,
                        size: 36,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '激活码错误',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: scheme.onSurface.withValues(alpha: 0.78),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: onDismiss,
                          child: const Text('我知道了'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
