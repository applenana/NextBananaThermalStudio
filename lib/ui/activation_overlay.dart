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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

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
            final show =
                app.status == ConnectionStatus.connected && !app.isActivated;
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
  bool _querySent = false;

  @override
  void initState() {
    super.initState();
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

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();
    messenger?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copy(String text, String okMsg) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast(okMsg);
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
      _toast('激活未成功, 请确认激活码后再试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Stack(
      children: [
        // 半透 scrim, 拦截点击.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
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
              _CopyableInline(
                text: _kAftersaleUrl,
                tooltip: '复制链接',
                onCopy: () => _copy(_kAftersaleUrl, '链接已复制'),
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
