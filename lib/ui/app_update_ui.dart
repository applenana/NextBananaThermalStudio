import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../update/app_update.dart';
import '../update/update_service.dart';
import 'banana_toast.dart';

const _updateRetryInterval = Duration(minutes: 1);
Timer? _updateRetryTimer;
bool _updateRetryInProgress = false;
BuildContext? _updateDialogContext;
String? _presentingUpdateTag;

Future<void> checkForUpdatesOnStartup(BuildContext context) async {
  _rememberUpdateDialogContext(context);
  // 避免启动页、设备初始化和更新弹窗同时抢占首帧。
  await Future<void>.delayed(const Duration(seconds: 2));
  if (!context.mounted) return;
  final info = await AppUpdateService.instance.checkForUpdate();
  final state = AppUpdateService.instance.snapshot.value;
  if (state.phase == AppUpdatePhase.error) {
    _scheduleUpdateRetry();
  } else {
    _cancelUpdateRetry();
  }
  if (info != null && context.mounted) {
    await _showAppUpdateDialogOnce(context, info);
  }
}

Future<void> checkForUpdatesManually(BuildContext context) async {
  _rememberUpdateDialogContext(context);
  final info = await AppUpdateService.instance.checkForUpdate(manual: true);
  final state = AppUpdateService.instance.snapshot.value;
  if (state.phase == AppUpdatePhase.error) {
    _scheduleUpdateRetry();
  } else {
    _cancelUpdateRetry();
  }
  if (!context.mounted) return;
  if (info != null) {
    await _showAppUpdateDialogOnce(context, info);
    return;
  }
  BananaToast.show(
    context,
    state.message ?? '暂时无法检查更新',
    icon: state.phase == AppUpdatePhase.upToDate
        ? Icons.verified_rounded
        : Icons.error_outline_rounded,
  );
}

void _rememberUpdateDialogContext(BuildContext context) {
  final current = _updateDialogContext;
  if (current == null || !current.mounted) {
    _updateDialogContext = context;
  }
}

void _scheduleUpdateRetry() {
  if (_updateRetryTimer != null || _updateRetryInProgress) return;
  _updateRetryTimer = Timer(_updateRetryInterval, () {
    _updateRetryTimer = null;
    unawaited(_runUpdateRetry());
  });
}

void _cancelUpdateRetry() {
  _updateRetryTimer?.cancel();
  _updateRetryTimer = null;
}

Future<void> _runUpdateRetry() async {
  if (_updateRetryInProgress) return;
  _updateRetryInProgress = true;
  final info = await AppUpdateService.instance.checkForUpdate(retry: true);
  _updateRetryInProgress = false;

  final state = AppUpdateService.instance.snapshot.value;
  if (state.phase == AppUpdatePhase.error) {
    _scheduleUpdateRetry();
    return;
  }

  _cancelUpdateRetry();
  final context = _updateDialogContext;
  if (info != null && context != null && context.mounted) {
    await _showAppUpdateDialogOnce(context, info);
  }
}

Future<void> _showAppUpdateDialogOnce(
  BuildContext context,
  AppUpdateInfo info,
) async {
  if (_presentingUpdateTag == info.release.tagName) return;
  _presentingUpdateTag = info.release.tagName;
  try {
    await showAppUpdateDialog(context, info);
  } finally {
    if (_presentingUpdateTag == info.release.tagName) {
      _presentingUpdateTag = null;
    }
  }
}

Future<void> showAppUpdateDialog(
  BuildContext context,
  AppUpdateInfo info,
) async {
  final release = info.release;
  final asset = info.asset;
  final platformHint = switch (info.platform) {
    AppUpdatePlatform.android =>
      asset == null
          ? '此版本没有适用于 Android 的 APK，将打开发布页面。'
          : '将下载 APK、校验 SHA-256，然后交给 Android 系统安装器。',
    AppUpdatePlatform.windows =>
      asset == null
          ? '此版本没有适用于 Windows 的安装包，将打开发布页面。'
          : asset.name.toLowerCase().endsWith('.zip')
          ? 'Windows 当前发布物为 ZIP。下载并校验后会定位文件，请退出应用并解压覆盖旧目录。'
          : '将下载并校验安装包，然后启动 Windows 安装程序。',
    AppUpdatePlatform.unsupported => '当前平台暂无直接安装包，将打开 GitHub 发布页面。',
  };

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.system_update_rounded),
      title: Text('发现新版本 ${release.tagName}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _VersionComparison(
                currentVersion: info.currentVersion,
                latestVersion: release.tagName,
              ),
              const SizedBox(height: 14),
              Text(platformHint),
              const SizedBox(height: 6),
              Text(
                '版本信息来源：${info.metadataSource}',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              if (info.isSingleMirrorFallback) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.errorContainer.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(
                          dialogContext,
                        ).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '当前只有一个更新镜像返回有效版本信息，尚未经过多源交叉验证。'
                          '安装包仍会按该来源声明的文件大小和 SHA-256 做完整性校验，'
                          '但这不能替代多源真实性验证；'
                          '如有疑虑，请稍后重试或前往 GitHub Releases 核对。',
                          style: TextStyle(
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.onErrorContainer,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (asset != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${asset.name} · ${formatUpdateFileSize(asset.size)}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
              if (release.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '更新内容',
                  style: Theme.of(dialogContext).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                SelectableText(
                  _trimReleaseNotes(release.notes),
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () async {
            await AppUpdateService.instance.ignoreVersion(release.tagName);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: const Text('忽略此版本'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('稍后提醒'),
        ),
        FilledButton.icon(
          icon: Icon(
            asset == null ? Icons.open_in_new_rounded : Icons.download_rounded,
          ),
          label: Text(_actionLabel(info)),
          onPressed: () {
            Navigator.pop(dialogContext);
            if (asset == null) {
              unawaited(_openReleasePage(context, release));
            } else {
              unawaited(
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => _UpdateProgressDialog(info: info),
                ),
              );
            }
          },
        ),
      ],
    ),
  );
}

String _actionLabel(AppUpdateInfo info) {
  if (info.asset == null || info.platform == AppUpdatePlatform.unsupported) {
    return '查看发布页';
  }
  if (info.platform == AppUpdatePlatform.android) return '下载并安装';
  return info.asset!.name.toLowerCase().endsWith('.zip') ? '下载更新包' : '下载并安装';
}

String _trimReleaseNotes(String source) {
  final text = source.trim();
  const maxLength = 6000;
  return text.length <= maxLength
      ? text
      : '${text.substring(0, maxLength)}\n\n…完整内容请查看 GitHub 发布页';
}

Future<void> _openReleasePage(
  BuildContext context, [
  AppRelease? release,
]) async {
  try {
    await AppUpdateService.instance.openReleasePage(release);
  } catch (error) {
    if (context.mounted) {
      BananaToast.show(
        context,
        '无法打开发布页：$error',
        icon: Icons.error_outline_rounded,
      );
    }
  }
}

class _VersionComparison extends StatelessWidget {
  const _VersionComparison({
    required this.currentVersion,
    required this.latestVersion,
  });

  final String currentVersion;
  final String latestVersion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('当前 v$currentVersion'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(Icons.arrow_forward_rounded, color: scheme.primary),
          ),
          Text(
            '最新 $latestVersion',
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.info});

  final AppUpdateInfo info;

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  bool _running = true;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    if (mounted) setState(() => _running = true);
    try {
      await AppUpdateService.instance.downloadAndInstall(widget.info);
    } catch (_) {
      // 具体错误已经写入服务状态，由对话框展示。
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppUpdateSnapshot>(
      valueListenable: AppUpdateService.instance.snapshot,
      builder: (context, state, _) {
        final progress = state.progress;
        final failed = state.phase == AppUpdatePhase.error;
        final cancelled = state.phase == AppUpdatePhase.cancelled;
        return AlertDialog(
          icon: Icon(
            failed
                ? Icons.error_outline_rounded
                : cancelled
                ? Icons.cancel_outlined
                : state.phase == AppUpdatePhase.ready
                ? Icons.download_done_rounded
                : Icons.downloading_rounded,
          ),
          title: Text(
            failed
                ? '更新失败'
                : cancelled
                ? '下载已取消'
                : state.phase == AppUpdatePhase.ready
                ? '更新包已就绪'
                : '正在获取更新',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_running || state.phase == AppUpdatePhase.downloading) ...[
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 12),
                ],
                Text(state.message ?? '请稍候…'),
                if (progress != null &&
                    state.phase == AppUpdatePhase.downloading) ...[
                  const SizedBox(height: 6),
                  Text(
                    '${(progress * 100).toStringAsFixed(0)}%',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (Platform.isWindows && state.downloadedFile != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    state.downloadedFile!.path,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (_running && state.phase == AppUpdatePhase.downloading)
              TextButton(
                onPressed: AppUpdateService.instance.cancelDownload,
                child: const Text('取消下载'),
              ),
            if (!_running)
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            if (!_running &&
                (failed ||
                    cancelled ||
                    (Platform.isAndroid && state.downloadedFile != null)))
              FilledButton.icon(
                onPressed: _run,
                icon: Icon(
                  failed || cancelled
                      ? Icons.refresh_rounded
                      : Icons.install_mobile_rounded,
                ),
                label: Text(failed || cancelled ? '重试' : '再次打开安装器'),
              ),
          ],
        );
      },
    );
  }
}

/// 设置页的版本信息、自动检查开关和手动检查入口。
class AppUpdateSettingsControl extends StatefulWidget {
  const AppUpdateSettingsControl({super.key});

  @override
  State<AppUpdateSettingsControl> createState() =>
      _AppUpdateSettingsControlState();
}

class _AppUpdateSettingsControlState extends State<AppUpdateSettingsControl> {
  final _service = AppUpdateService.instance;

  @override
  void initState() {
    super.initState();
    _service.snapshot.addListener(_refresh);
    _service.automaticCheckEnabled.addListener(_refresh);
    unawaited(_service.initialize().then((_) => _refresh()));
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.snapshot.removeListener(_refresh);
    _service.automaticCheckEnabled.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _service.snapshot.value;
    final checking = state.phase == AppUpdatePhase.checking;
    final build = _service.currentBuildNumber;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前版本 v${_service.currentVersion}'
                    '${build.isEmpty ? '' : ' ($build)'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    state.message ?? '官方 GitHub 优先，失败时自动交叉验证多个镜像',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: checking
                  ? null
                  : () => checkForUpdatesManually(context),
              icon: checking
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(checking ? '检查中' : '检查更新'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('启动时自动检查更新'),
          subtitle: const Text('成功检查最多每 12 小时一次；失败后每分钟重试直到成功'),
          value: _service.automaticCheckEnabled.value,
          onChanged: _service.setAutomaticCheckEnabled,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _openReleasePage(context, state.info?.release),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('查看 GitHub Releases'),
          ),
        ),
      ],
    );
  }
}
