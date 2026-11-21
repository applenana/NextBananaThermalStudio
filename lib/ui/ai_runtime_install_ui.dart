import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../render/ai_runtime_install.dart';
import '../render/photo_ai_model.dart';
import '../render/photo_ai_runtime.dart';

const _dismissKey = 'ai_runtime_do_not_prompt';
bool _dialogOpen = false;
bool get _ready => PhotoAiModel.windowsModels.every(PhotoAiRuntime.available);

Future<void> offerAiRuntimeOnStartup(BuildContext context) async {
  if (!AiRuntimeInstaller.supported ||
      !AiRuntimeInstaller.configured ||
      _ready ||
      _dialogOpen) {
    return;
  }
  final preferences = await SharedPreferences.getInstance();
  if (preferences.getBool(_dismissKey) == true || !context.mounted) return;
  final installer = AiRuntimeInstaller.instance;
  await installer.check();
  // Offline, unsupported and out-of-space states should not nag on startup.
  if (installer.package == null ||
      !context.mounted ||
      _dialogOpen ||
      _ready ||
      ModalRoute.of(context)?.isCurrent != true) {
    return;
  }
  await showAiRuntimeInstaller(context, checked: true);
}

Future<void> showAiRuntimeInstaller(
  BuildContext context, {
  bool checked = false,
}) async {
  if (_dialogOpen) return;
  _dialogOpen = true;
  try {
    final installer = AiRuntimeInstaller.instance;
    if (!checked && !installer.state.value.busy) {
      // Open immediately; the dialog displays asynchronous environment checking.
      installer.check();
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _InstallDialog(),
    );
  } finally {
    _dialogOpen = false;
  }
}

class AiRuntimeInstallButton extends StatelessWidget {
  const AiRuntimeInstallButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AiRuntimeInstaller.supported) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: PhotoAiRuntime.revision,
      builder: (context, _, _) => _ready
          ? const Text('AI 运行包已安装', style: TextStyle(fontSize: 12))
          : OutlinedButton.icon(
              onPressed: () => showAiRuntimeInstaller(context),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('安装 AI 运行包'),
            ),
    );
  }
}

class _InstallDialog extends StatefulWidget {
  const _InstallDialog();
  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  bool _doNotPrompt = false;

  @override
  Widget build(BuildContext context) {
    final installer = AiRuntimeInstaller.instance;
    return ValueListenableBuilder<AiInstallState>(
      valueListenable: installer.state,
      builder: (context, state, _) {
        final package = installer.package;
        final environment = installer.environment;
        return PopScope(
          canPop: !state.busy,
          child: AlertDialog(
            icon: const Icon(Icons.auto_awesome),
            title: Text(_ready ? 'AI 运行包已就绪' : '安装 AI 超分运行包'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '下载安装后，可在照片和实时画面中使用 Thermal-PFT 3× 超分。仅增强显示，温度测量仍使用原始数据。',
                    ),
                    const SizedBox(height: 12),
                    if (environment != null) ...[
                      Text(
                        '系统内存：${formatAiBytes(environment.ramBytes)} · 磁盘可用：${formatAiBytes(environment.freeBytes)}',
                      ),
                      Text('检测到显卡：${environment.gpu}'),
                      const Text(
                        '兼容的 NVIDIA 显卡和驱动可使用 CUDA；安装后会进一步检测，其他环境使用 CPU，实时处理可能较慢。',
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (package != null) ...[
                      Text('下载大小：${formatAiBytes(package.downloadBytes)}'),
                      Text(
                        '安装后占用：${formatAiBytes(package.expandedBytes)}；安装期间需要 ${formatAiBytes(package.requiredBytes)} 可用空间。',
                      ),
                      const Text('来源：本项目 GitHub Release。运行包较大，建议使用稳定网络。'),
                      const SizedBox(height: 8),
                      SelectableText('安装位置：${PhotoAiRuntime.managedRoot}'),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      state.message,
                      style: TextStyle(
                        color: state.error
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                    if (state.busy) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: state.progress),
                    ],
                    if (!state.busy && !_ready)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('不再自动提示（可从设置中安装）'),
                        value: _doNotPrompt,
                        onChanged: (value) async {
                          setState(() => _doNotPrompt = value ?? false);
                          final preferences =
                              await SharedPreferences.getInstance();
                          await preferences.setBool(_dismissKey, _doNotPrompt);
                        },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              if (state.cancellable)
                TextButton(
                  onPressed: installer.cancel,
                  child: const Text('取消下载'),
                ),
              if (!state.busy) ...[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_ready ? '完成' : '暂不安装'),
                ),
                if (!_ready && package == null)
                  TextButton(
                    onPressed: installer.check,
                    child: const Text('重新检查'),
                  ),
                if (!_ready && package != null)
                  FilledButton(
                    onPressed: installer.install,
                    child: Text(state.error ? '重试安装' : '下载并安装'),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
