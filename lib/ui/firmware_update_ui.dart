import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../firmware/android_uf2_flasher.dart';
import '../firmware/firmware_update.dart';
import '../firmware/firmware_update_service.dart';
import '../update/app_update.dart' show AppVersion;
import 'banana_toast.dart';

String? _presentingFirmwareTag;

bool get _automaticFirmwareFlashSupported =>
    Platform.isWindows || Platform.isAndroid;

bool get _customFirmwareFlashSupported =>
    Platform.isWindows ||
    Platform.isAndroid ||
    Platform.isMacOS ||
    Platform.isLinux;

Future<void> checkFirmwareForConnectedDevice(
  BuildContext context,
  AppState app,
) async {
  final identity = FirmwareDeviceIdentity.fromDeviceInfo(app.deviceInfo);
  if (!identity.canFlash) return;
  final notice = await FirmwareUpdateService.instance.checkForUpdate(identity);
  if (notice == null || !context.mounted) return;
  await showFirmwareUpdateAvailableDialog(context, app, notice);
}

Future<void> showFirmwareUpdateAvailableDialog(
  BuildContext context,
  AppState app,
  FirmwareUpdateNotice notice,
) async {
  if (_presentingFirmwareTag == notice.latest.tagName) return;
  _presentingFirmwareTag = notice.latest.tagName;
  try {
    final manage = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.memory_rounded),
        title: Text('发现设备固件 ${notice.latest.tagName}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _VersionCard(
                current: notice.identity.currentVersion ?? '未知',
                target: notice.latest.tagName,
              ),
              const SizedBox(height: 12),
              Text(
                '设备：3.2 寸双光热成像 · ${notice.identity.model}\n'
                '版本来源：${notice.catalog.sourceLabel}',
              ),
              if (notice.catalog.singleSourceFallback) ...[
                const SizedBox(height: 10),
                const _WarningBox(
                  text:
                      '官方 GitHub 当前不可用，版本列表仅来自一个镜像。'
                      '烧录前仍会验证 GitHub 摘要、manifest、文件大小和 UF2 SHA-256。',
                ),
              ],
              const SizedBox(height: 10),
              Text(
                _automaticFirmwareFlashSupported
                    ? '你可以立即自动烧录，也可以在固件管理中选择任意正式版本进行升级、降级或重刷。'
                    : '你可以查看并选择任意正式版本；自动烧录目前支持 Windows 和 Android。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.tune_rounded),
            label: Text(
              _automaticFirmwareFlashSupported ? '选择版本并烧录' : '查看固件版本',
            ),
          ),
        ],
      ),
    );
    if (manage == true && context.mounted) {
      await showFirmwareManagerDialog(
        context,
        app,
        initialRelease: notice.latest,
        initialCatalog: notice.catalog,
      );
    }
  } finally {
    if (_presentingFirmwareTag == notice.latest.tagName) {
      _presentingFirmwareTag = null;
    }
  }
}

Future<void> showFirmwareManagerDialog(
  BuildContext context,
  AppState app, {
  FirmwareDeviceIdentity? identityOverride,
  FirmwareRelease? initialRelease,
  FirmwareCatalog? initialCatalog,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FirmwareManagerDialog(
      app: app,
      identity:
          identityOverride ??
          FirmwareDeviceIdentity.fromDeviceInfo(app.deviceInfo),
      initialRelease: initialRelease,
      initialCatalog: initialCatalog,
    ),
  );
}

Future<void> showCustomFirmwareFlashDialog(BuildContext context, AppState app) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CustomFirmwareFlashDialog(app: app),
  );
}

class FirmwareUpdateSettingsControl extends StatefulWidget {
  const FirmwareUpdateSettingsControl({super.key});

  @override
  State<FirmwareUpdateSettingsControl> createState() =>
      _FirmwareUpdateSettingsControlState();
}

class _FirmwareUpdateSettingsControlState
    extends State<FirmwareUpdateSettingsControl> {
  final _service = FirmwareUpdateService.instance;
  Timer? _usbProbeTimer;
  AndroidFirmwareUsbState? _androidUsbState;
  Object? _androidUsbError;
  bool _usbProbeInFlight = false;

  @override
  void initState() {
    super.initState();
    _service.snapshot.addListener(_refresh);
    _service.automaticCheckEnabled.addListener(_refresh);
    _service.recoverySession.addListener(_refresh);
    unawaited(_service.initialize().then((_) => _refresh()));
    if (Platform.isAndroid) {
      unawaited(_probeAndroidUsb());
      _usbProbeTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_probeAndroidUsb()),
      );
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _probeAndroidUsb() async {
    if (!Platform.isAndroid || _usbProbeInFlight) return;
    _usbProbeInFlight = true;
    try {
      final state = await AndroidUf2Flasher.inspectUsbState();
      if (mounted) {
        setState(() {
          _androidUsbState = state;
          _androidUsbError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _androidUsbError = error);
    } finally {
      _usbProbeInFlight = false;
    }
  }

  @override
  void dispose() {
    _usbProbeTimer?.cancel();
    _service.snapshot.removeListener(_refresh);
    _service.automaticCheckEnabled.removeListener(_refresh);
    _service.recoverySession.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _check(AppState app) async {
    final identity = FirmwareDeviceIdentity.fromDeviceInfo(app.deviceInfo);
    final notice = await _service.checkForUpdate(identity, manual: true);
    if (!mounted) return;
    if (notice != null) {
      await showFirmwareUpdateAvailableDialog(context, app, notice);
      return;
    }
    BananaToast.show(
      context,
      _service.snapshot.value.message ?? '未发现可用固件更新',
      icon: _service.snapshot.value.phase == FirmwareUpdatePhase.error
          ? Icons.error_outline_rounded
          : Icons.verified_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, app, _) {
        final connected = app.status == ConnectionStatus.connected;
        final liveIdentity = FirmwareDeviceIdentity.fromDeviceInfo(
          app.deviceInfo,
        );
        final recovery = _service.recoverySession.value;
        final bootloaders = _androidUsbState?.bootloaders ?? const [];
        final canRecover =
            Platform.isAndroid &&
            !connected &&
            bootloaders.length == 1 &&
            recovery != null;
        final identity = liveIdentity.canFlash
            ? liveIdentity
            : canRecover
            ? recovery.identity
            : liveIdentity;
        final checking =
            _service.snapshot.value.phase == FirmwareUpdatePhase.checking;
        final variant = identity.canFlash
            ? _service.variantFor(identity)
            : null;
        final scheme = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  identity.canFlash
                      ? Icons.verified_user_rounded
                      : connected
                      ? Icons.gpp_bad_rounded
                      : Icons.usb_off_rounded,
                  color: identity.canFlash
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        canRecover
                            ? '已检测到 RP2040 USB 磁盘 · 可恢复烧录'
                            : identity.canFlash
                            ? '3.2 寸双光热成像 · ${identity.currentVersion ?? '版本未知'}'
                            : connected
                            ? '当前设备不允许使用此固件源'
                            : '连接设备后识别型号与固件版本',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        canRecover
                            ? '上次已确认 ${identity.model} · '
                                  '目标 ${recovery.targetTag} · ${recovery.variant.label}'
                            : identity.canFlash
                            ? '${identity.reason} · '
                                  '${variant?.label ?? '尚未确认 Flash 变体'}'
                            : _androidUsbError != null
                            ? 'USB 状态读取失败：$_androidUsbError'
                            : bootloaders.length > 1
                            ? '检测到多个 RP2040 USB 磁盘，请只保留待烧录设备'
                            : identity.reason,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: identity.canFlash && !checking
                      ? () => _check(app)
                      : null,
                  icon: checking
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(checking ? '检查中' : '检查新版本'),
                ),
                OutlinedButton.icon(
                  onPressed: identity.canFlash && (connected || canRecover)
                      ? () => showFirmwareManagerDialog(
                          context,
                          app,
                          identityOverride: identity,
                        )
                      : null,
                  icon: const Icon(Icons.developer_board_rounded, size: 18),
                  label: const Text('固件管理 / 升降级'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _customFirmwareFlashSupported &&
                          !_service.snapshot.value.busy
                      ? () => showCustomFirmwareFlashDialog(context, app)
                      : null,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: const Text('烧录自定义 UF2'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    try {
                      await _service.openReleasePage();
                    } catch (error) {
                      if (context.mounted) {
                        BananaToast.show(context, error.toString());
                      }
                    }
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Releases'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('连接后自动检查固件更新'),
              subtitle: const Text('仅对明确识别为官方双光型号的设备查询；未知型号不会匹配或烧录'),
              value: _service.automaticCheckEnabled.value,
              onChanged: _service.setAutomaticCheckEnabled,
            ),
          ],
        );
      },
    );
  }
}

class _CustomFirmwareFlashDialog extends StatefulWidget {
  const _CustomFirmwareFlashDialog({required this.app});

  final AppState app;

  @override
  State<_CustomFirmwareFlashDialog> createState() =>
      _CustomFirmwareFlashDialogState();
}

class _CustomFirmwareFlashDialogState
    extends State<_CustomFirmwareFlashDialog> {
  final _service = FirmwareUpdateService.instance;
  Timer? _probeTimer;
  CustomFirmwareImage? _image;
  AndroidFirmwareUsbState? _androidUsbState;
  List<Uf2Volume> _desktopVolumes = const [];
  Uf2Volume? _selectedDesktopVolume;
  Object? _fileError;
  Object? _deviceError;
  bool _selecting = false;
  bool _selectingTarget = false;
  bool _running = false;
  bool _probing = false;
  bool _requestingPermission = false;
  bool _riskConfirmed = false;

  @override
  void initState() {
    super.initState();
    _service.markReady('请选择自定义 UF2，并完成风险确认');
    _service.snapshot.addListener(_refresh);
    unawaited(_probeDevices());
    _probeTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_probeDevices()),
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    _service.snapshot.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _probeDevices() async {
    if (_probing || _running) return;
    _probing = true;
    try {
      if (Platform.isAndroid) {
        final state = await AndroidUf2Flasher.inspectUsbState();
        if (mounted) {
          setState(() {
            _androidUsbState = state;
            _deviceError = null;
          });
        }
      } else {
        final volumes = await Uf2Flasher.findRp2040Volumes();
        if (mounted) {
          setState(() {
            _desktopVolumes = volumes;
            _deviceError = null;
          });
        }
      }
    } catch (error) {
      if (mounted) setState(() => _deviceError = error);
    } finally {
      if (mounted) {
        setState(() => _probing = false);
      } else {
        _probing = false;
      }
    }
  }

  Future<void> _selectFile() async {
    if (_selecting || _running) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['uf2'],
      allowMultiple: false,
    );
    if (picked == null) return;
    final path = picked.files.single.path;
    if (path == null || path.isEmpty) {
      setState(() => _fileError = StateError('文件选择器没有返回可读取的本地路径'));
      return;
    }
    setState(() {
      _selecting = true;
      _fileError = null;
      _image = null;
      _riskConfirmed = false;
    });
    try {
      final image = await _service.prepareCustomFirmware(File(path));
      if (mounted) setState(() => _image = image);
    } catch (error) {
      if (mounted) setState(() => _fileError = error);
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _requestPermission() async {
    final device = _androidUsbState?.singleBootloader;
    if (device == null || _requestingPermission || _running) return;
    setState(() {
      _requestingPermission = true;
      _deviceError = null;
    });
    try {
      await AndroidUf2Flasher.requestPermission(device);
      await _probeDevices();
    } catch (error) {
      if (mounted) setState(() => _deviceError = error);
    } finally {
      if (mounted) setState(() => _requestingPermission = false);
    }
  }

  Future<Uf2Volume?> _selectDesktopTarget() async {
    if (!Platform.isMacOS || _selectingTarget) return null;
    setState(() {
      _selectingTarget = true;
      _deviceError = null;
    });
    try {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择 RPI-RP2 磁盘根目录',
      );
      if (path == null || path.isEmpty) return null;
      final volume = await Uf2Flasher.inspectRp2040Volume(Directory(path));
      if (volume == null) {
        throw StateError('所选目录没有有效的 RP2040 INFO_UF2.TXT，请选择 RPI-RP2 磁盘根目录');
      }
      if (mounted) {
        setState(() {
          _selectedDesktopVolume = volume;
          _deviceError = null;
        });
      }
      return volume;
    } catch (error) {
      if (mounted) setState(() => _deviceError = error);
      return null;
    } finally {
      if (mounted) setState(() => _selectingTarget = false);
    }
  }

  Future<void> _startFlash() async {
    final image = _image;
    if (image == null || !_riskAccepted || !_targetReady) return;
    setState(() => _running = true);
    try {
      await _service.flashCustomFirmware(
        app: widget.app,
        image: image,
        selectedDesktopVolume: Platform.isMacOS ? _selectedDesktopVolume : null,
        selectDesktopVolume: Platform.isMacOS ? _selectDesktopTarget : null,
      );
      if (mounted) {
        setState(() => _riskConfirmed = false);
        BananaToast.show(
          context,
          _service.snapshot.value.message ?? '自定义 UF2 已提交',
          icon: Icons.warning_amber_rounded,
        );
      }
    } catch (error) {
      if (mounted) {
        BananaToast.show(
          context,
          _service.snapshot.value.message ?? error.toString(),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
        unawaited(_probeDevices());
      }
    }
  }

  bool get _serialConnected =>
      widget.app.status == ConnectionStatus.connected &&
      widget.app.currentPort != null;

  List<Uf2Volume> get _desktopCandidates {
    final byPath = <String, Uf2Volume>{
      for (final volume in _desktopVolumes) volume.root.path: volume,
    };
    final selected = _selectedDesktopVolume;
    if (selected != null) byPath[selected.root.path] = selected;
    return byPath.values.toList();
  }

  bool get _targetReady {
    if (Platform.isAndroid) {
      final state = _androidUsbState;
      if (state == null || !state.usbHostSupported) return false;
      if (state.bootloaders.length > 1) return false;
      final bootloader = state.singleBootloader;
      if (_serialConnected && bootloader != null) return false;
      return _serialConnected || bootloader?.hasPermission == true;
    }
    final candidates = _desktopCandidates;
    if (candidates.length > 1) return false;
    if (_serialConnected && candidates.length == 1) return false;
    return _serialConnected || candidates.length == 1;
  }

  bool get _riskAccepted => _riskConfirmed;

  Widget _desktopDeviceCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final volumes = _desktopCandidates;
    late final IconData icon;
    late final String title;
    late final String detail;
    var isError = false;
    if (_deviceError != null) {
      icon = Icons.error_outline_rounded;
      title = '设备检测失败';
      detail = _deviceError.toString();
      isError = true;
    } else if (volumes.length > 1) {
      icon = Icons.warning_amber_rounded;
      title = '检测到多个 RP2040 UF2 磁盘';
      detail = '请只保留当前准备烧录的一台设备。';
      isError = true;
    } else if (_serialConnected && volumes.length == 1) {
      icon = Icons.warning_amber_rounded;
      title = '同时检测到串口设备和 UF2 磁盘';
      detail = '无法安全确定目标，请断开无关设备。';
      isError = true;
    } else if (volumes.length == 1) {
      icon = Icons.usb_rounded;
      title = 'RP2040 UF2 磁盘已就绪';
      detail = volumes.single.root.path;
    } else if (_serialConnected) {
      icon = Icons.settings_input_component_rounded;
      title = '串口设备已连接';
      detail = '开始后会尝试自动切换到 BOOTSEL；不支持时请按提示手动操作。';
    } else {
      icon = Icons.usb_off_rounded;
      title = '未检测到可烧录设备';
      detail = Platform.isMacOS
          ? '请让 RP2040 进入 RPI-RP2 模式，再通过下方按钮明确选择磁盘。'
          : '请连接串口设备，或让 RP2040 进入 RPI-RP2 / UF2 磁盘模式。';
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (Platform.isMacOS) ...[
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: _selectingTarget || _running
                        ? null
                        : _selectDesktopTarget,
                    icon: _selectingTarget
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.drive_file_move_rounded, size: 17),
                    label: const Text('选择 RPI-RP2 磁盘'),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: _probing || _running ? null : _probeDevices,
            tooltip: '重新检测',
            icon: _probing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _service.snapshot.value;
    final busy = _running || state.busy;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: const Text('烧录自定义 UF2'),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _WarningBox(
                text:
                    '高风险操作：自定义 UF2 未经过 BananaThermal 官方来源、型号、Flash 容量、'
                    '分区布局或功能兼容性验证。错误固件可能导致设备无法启动、串口消失、参数或照片丢失。',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy || _selecting ? null : _selectFile,
                icon: _selecting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open_rounded),
                label: Text(_image == null ? '选择 UF2 文件' : '重新选择 UF2 文件'),
              ),
              if (_fileError != null) ...[
                const SizedBox(height: 8),
                _WarningBox(text: '文件校验失败：$_fileError'),
              ],
              if (_image case final image?) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        image.originalName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(image.bytes / 1024 / 1024).toStringAsFixed(2)} MiB · '
                        '${image.blockCount} 个 UF2 块 · RP2040 基础结构校验通过',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        'SHA-256  ${image.sha256}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '结构校验通过只说明文件是连续的 RP2040 主 Flash UF2，不代表它适用于当前热成像设备。',
                        style: TextStyle(color: scheme.error, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (Platform.isAndroid)
                _AndroidFirmwareConnectionCard(
                  serialConnected: _serialConnected,
                  usbState: _androidUsbState,
                  error: _deviceError,
                  probing: _probing,
                  requestingPermission: _requestingPermission,
                  busy: busy,
                  onRefresh: _probeDevices,
                  onRequestPermission: _requestPermission,
                  identityWarning:
                      'BOOTSEL 只能确认 RP2040 芯片，不能确认热成像型号；兼容性完全由用户自行负责。',
                )
              else
                _desktopDeviceCard(context),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _riskConfirmed,
                onChanged: busy
                    ? null
                    : (value) => setState(() => _riskConfirmed = value == true),
                title: const Text('我已阅读上述风险，确认固件兼容性由我负责，并已备份重要数据'),
                subtitle: const Text('错误固件可能导致设备无法启动、串口消失或设备数据丢失'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (state.busy ||
                  state.phase == FirmwareUpdatePhase.completed ||
                  state.phase == FirmwareUpdatePhase.error) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: state.phase == FirmwareUpdatePhase.error
                        ? scheme.errorContainer
                        : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(state.message ?? '正在处理自定义固件…'),
                      if (state.progress != null || state.busy) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: state.progress),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: !busy && _image != null && _riskAccepted && _targetReady
              ? _startFlash
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          icon: const Icon(Icons.warning_amber_rounded),
          label: const Text('承担风险并烧录'),
        ),
      ],
    );
  }
}

class _FirmwareManagerDialog extends StatefulWidget {
  const _FirmwareManagerDialog({
    required this.app,
    required this.identity,
    this.initialRelease,
    this.initialCatalog,
  });

  final AppState app;
  final FirmwareDeviceIdentity identity;
  final FirmwareRelease? initialRelease;
  final FirmwareCatalog? initialCatalog;

  @override
  State<_FirmwareManagerDialog> createState() => _FirmwareManagerDialogState();
}

class _FirmwareManagerDialogState extends State<_FirmwareManagerDialog> {
  final _service = FirmwareUpdateService.instance;
  FirmwareCatalog? _catalog;
  Object? _loadError;
  FirmwareRelease? _selectedRelease;
  FirmwareVariant? _selectedVariant;
  bool _loading = false;
  bool _running = false;
  bool _usbProbeInFlight = false;
  bool _requestingUsbPermission = false;
  AndroidFirmwareUsbState? _androidUsbState;
  Object? _androidUsbError;
  Timer? _usbProbeTimer;

  @override
  void initState() {
    super.initState();
    _catalog = widget.initialCatalog;
    _selectedRelease = widget.initialRelease;
    final recovery = _service.recoverySession.value;
    final matchingRecovery =
        recovery?.identity.deviceKey == widget.identity.deviceKey
        ? recovery
        : null;
    _selectedVariant =
        matchingRecovery?.variant ?? _service.variantFor(widget.identity);
    _service.snapshot.addListener(_refresh);
    if (Platform.isAndroid) {
      unawaited(_probeAndroidUsb());
      _usbProbeTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_probeAndroidUsb()),
      );
    }
    if (_catalog == null) {
      unawaited(_load());
    } else {
      _selectDefaultRelease(_catalog!);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _selectDefaultRelease(FirmwareCatalog catalog) {
    if (_selectedRelease != null || catalog.releases.isEmpty) return;
    final recovery = _service.recoverySession.value;
    if (recovery != null &&
        recovery.identity.deviceKey == widget.identity.deviceKey) {
      for (final release in catalog.releases) {
        if (release.tagName == recovery.targetTag) {
          _selectedRelease = release;
          return;
        }
      }
    }
    _selectedRelease = catalog.releases.first;
  }

  Future<void> _probeAndroidUsb() async {
    if (!Platform.isAndroid || _usbProbeInFlight) return;
    _usbProbeInFlight = true;
    try {
      final state = await AndroidUf2Flasher.inspectUsbState();
      if (mounted) {
        setState(() {
          _androidUsbState = state;
          _androidUsbError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _androidUsbError = error);
    } finally {
      _usbProbeInFlight = false;
    }
  }

  Future<void> _requestBootloaderPermission() async {
    final device = _androidUsbState?.singleBootloader;
    if (device == null || _requestingUsbPermission) return;
    setState(() {
      _requestingUsbPermission = true;
      _androidUsbError = null;
    });
    try {
      await AndroidUf2Flasher.requestPermission(device);
      await _probeAndroidUsb();
      if (mounted) {
        _service.markReady('RP2040 USB 磁盘已授权，可以继续烧录');
        BananaToast.show(
          context,
          'RP2040 USB 磁盘授权成功，可以继续烧录',
          icon: Icons.usb_rounded,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _androidUsbError = error);
    } finally {
      if (mounted) setState(() => _requestingUsbPermission = false);
    }
  }

  @override
  void dispose() {
    _usbProbeTimer?.cancel();
    _service.snapshot.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _load({bool force = true}) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final catalog = await _service.loadCatalog(force: force);
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _selectDefaultRelease(catalog);
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<FirmwareVariant> get _availableVariants {
    final reported = widget.identity.reportedVariant;
    if (reported == null) return FirmwareVariant.values;
    return FirmwareVariant.values
        .where((variant) => variant.flashBytes == reported.flashBytes)
        .toList();
  }

  Future<void> _startFlash() async {
    final release = _selectedRelease;
    final variant = _selectedVariant;
    if (release == null || variant == null) return;
    if (Platform.isAndroid) {
      await _probeAndroidUsb();
      final usbState = _androidUsbState;
      final serialConnected =
          widget.app.status == ConnectionStatus.connected &&
          widget.app.currentPort != null;
      if (usbState == null || !usbState.usbHostSupported) {
        setState(
          () => _androidUsbError = StateError('此设备无法读取 Android USB Host 状态'),
        );
        return;
      }
      if (usbState.bootloaders.length > 1 ||
          (serialConnected && usbState.singleBootloader != null)) {
        setState(
          () => _androidUsbError = StateError(
            '无法唯一确认烧录目标，请只连接一台串口设备或一个 RP2040 USB 磁盘',
          ),
        );
        return;
      }
      if (!serialConnected && usbState.singleBootloader == null) {
        setState(
          () => _androidUsbError = StateError('未检测到串口设备或 RP2040 USB 磁盘'),
        );
        return;
      }
    }
    final confirmed = await _confirmFlash(release, variant);
    if (confirmed != true || !mounted) return;
    setState(() => _running = true);
    try {
      await _service.flashFirmware(
        app: widget.app,
        identity: widget.identity,
        release: release,
        variant: variant,
      );
      if (mounted) {
        BananaToast.show(
          context,
          '固件 ${release.tagName} 烧录并验证完成',
          icon: Icons.verified_rounded,
        );
      }
    } catch (error) {
      if (mounted) {
        BananaToast.show(
          context,
          _service.snapshot.value.message ?? error.toString(),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<bool?> _confirmFlash(
    FirmwareRelease release,
    FirmwareVariant variant,
  ) {
    var backedUp = false;
    final current = AppVersion.tryParse(widget.identity.currentVersion ?? '');
    final relation = current == null
        ? '烧录'
        : release.version.compareTo(current) > 0
        ? '升级'
        : release.version.compareTo(current) < 0
        ? '降级'
        : '重新烧录';
    final remembered = _service.variantFor(widget.identity);
    final capacityChanged =
        remembered != null && remembered.flashBytes != variant.flashBytes;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: Text('确认$relation至 ${release.tagName}？'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _VersionCard(
                  current: widget.identity.currentVersion ?? '未知',
                  target: release.tagName,
                ),
                const SizedBox(height: 12),
                Text('固件变体：${variant.label}'),
                const SizedBox(height: 8),
                _WarningBox(
                  text: capacityChanged
                      ? '你正在切换 2 MB / 8 MB Flash 分区。旧照片、配置或 LittleFS '
                            '可能无法读取；必须确认真实 Flash 容量后再继续。'
                      : '固件切换可能迁移配置或使旧照片不可读。请先下载设备照片，并记录温度校准、'
                            '触摸校准和双光对齐参数。',
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: backedUp,
                  onChanged: (value) =>
                      setDialogState(() => backedUp = value == true),
                  title: const Text('我已备份照片和重要参数，并确认 Flash 容量'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: backedUp
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              icon: const Icon(Icons.memory_rounded),
              label: Text('开始$relation'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _service.snapshot.value;
    final releases = _catalog?.releases ?? const <FirmwareRelease>[];
    final busy = _running || state.busy;
    final scheme = Theme.of(context).colorScheme;
    final serialConnected =
        widget.app.status == ConnectionStatus.connected &&
        widget.app.currentPort != null;
    final bootloader = _androidUsbState?.singleBootloader;
    final ambiguousAndroidTarget =
        Platform.isAndroid && (_androidUsbState?.bootloaders.length ?? 0) > 1 ||
        (Platform.isAndroid && serialConnected && bootloader != null);
    final androidTargetAvailable =
        !Platform.isAndroid ||
        (serialConnected || bootloader != null) && !ambiguousAndroidTarget;
    return AlertDialog(
      icon: const Icon(Icons.developer_board_rounded),
      title: const Text('设备固件管理'),
      content: SizedBox(
        width: 660,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.identity.canFlash
                    ? '已识别 ${widget.identity.model} · '
                          '当前 ${widget.identity.currentVersion ?? '版本未知'}'
                    : widget.identity.reason,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '当前发布源仅包含 3.2 寸双光热成像；其他设备即使协议兼容也不会放行。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 14),
                _AndroidFirmwareConnectionCard(
                  serialConnected: serialConnected,
                  usbState: _androidUsbState,
                  error: _androidUsbError,
                  probing: _usbProbeInFlight,
                  requestingPermission: _requestingUsbPermission,
                  busy: busy,
                  onRefresh: _probeAndroidUsb,
                  onRequestPermission: _requestBootloaderPermission,
                ),
              ],
              const SizedBox(height: 16),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_loadError != null) ...[
                _WarningBox(text: '读取固件版本失败：$_loadError'),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () => _load(force: true),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                ),
              ] else ...[
                DropdownButtonFormField<FirmwareRelease>(
                  initialValue: releases.contains(_selectedRelease)
                      ? _selectedRelease
                      : null,
                  decoration: const InputDecoration(
                    labelText: '目标正式版本（可自由升级 / 降级）',
                    prefixIcon: Icon(Icons.new_releases_rounded),
                  ),
                  items: [
                    for (final release in releases)
                      DropdownMenuItem(
                        value: release,
                        child: Text(_releaseLabel(release)),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => _selectedRelease = value),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<FirmwareVariant>(
                  initialValue: _availableVariants.contains(_selectedVariant)
                      ? _selectedVariant
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Flash / 运行变体',
                    prefixIcon: Icon(Icons.memory_rounded),
                    helperText: '旧固件未上报容量时必须由用户确认一次；选择会按设备序列号记住',
                  ),
                  hint: const Text('请选择真实硬件对应的变体'),
                  items: [
                    for (final variant in _availableVariants)
                      DropdownMenuItem(
                        value: variant,
                        child: Text(variant.label),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => _selectedVariant = value),
                ),
                if (_selectedVariant == null) ...[
                  const SizedBox(height: 10),
                  const _WarningBox(
                    text: '不能从 UF2 文件大小推断 2 MB / 8 MB Flash。请选择原固件所用分区或查阅硬件资料。',
                  ),
                ],
                if (_catalog case final catalog?) ...[
                  const SizedBox(height: 10),
                  Text(
                    '版本信息：${catalog.sourceLabel}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
              if (state.busy ||
                  state.phase == FirmwareUpdatePhase.completed ||
                  state.phase == FirmwareUpdatePhase.error) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: state.phase == FirmwareUpdatePhase.error
                        ? scheme.errorContainer
                        : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(_phaseIcon(state.phase), size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(state.message ?? '正在处理…')),
                        ],
                      ),
                      if (state.progress != null) ...[
                        const SizedBox(height: 10),
                        LinearProgressIndicator(value: state.progress),
                      ] else if (state.busy) ...[
                        const SizedBox(height: 10),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ],
              if (!Platform.isAndroid && !Platform.isWindows) ...[
                const SizedBox(height: 14),
                const _WarningBox(
                  text: '自动烧录目前支持 Windows 和 Android；此平台只能查看正式版本。',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (state.phase == FirmwareUpdatePhase.downloading)
          TextButton(
            onPressed: _service.cancelDownload,
            child: const Text('取消下载'),
          ),
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (!_automaticFirmwareFlashSupported)
          FilledButton.tonalIcon(
            onPressed: () => _service.openReleasePage(_selectedRelease),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('打开发布页'),
          )
        else
          FilledButton.icon(
            onPressed:
                !widget.identity.canFlash ||
                    _selectedRelease == null ||
                    _selectedVariant == null ||
                    busy ||
                    !androidTargetAvailable
                ? null
                : Platform.isAndroid &&
                      bootloader != null &&
                      !bootloader.hasPermission
                ? _requestBootloaderPermission
                : _startFlash,
            icon: Icon(
              Platform.isAndroid &&
                      bootloader != null &&
                      !bootloader.hasPermission
                  ? Icons.usb_rounded
                  : Icons.bolt_rounded,
            ),
            label: Text(
              Platform.isAndroid &&
                      bootloader != null &&
                      !bootloader.hasPermission
                  ? '授权 USB 磁盘'
                  : Platform.isAndroid && bootloader != null
                  ? '从 USB 磁盘继续烧录'
                  : _actionLabel(_selectedRelease),
            ),
          ),
      ],
    );
  }

  String _releaseLabel(FirmwareRelease release) {
    final current = AppVersion.tryParse(widget.identity.currentVersion ?? '');
    if (current == null) return release.tagName;
    final compared = release.version.compareTo(current);
    if (compared > 0) return '${release.tagName} · 升级';
    if (compared < 0) return '${release.tagName} · 降级';
    return '${release.tagName} · 当前版本 / 可重刷';
  }

  String _actionLabel(FirmwareRelease? release) {
    if (release == null) return '选择版本';
    final current = AppVersion.tryParse(widget.identity.currentVersion ?? '');
    if (current == null) return '自动烧录';
    final compared = release.version.compareTo(current);
    if (compared > 0) return '自动升级';
    if (compared < 0) return '自动降级';
    return '重新烧录';
  }
}

class _AndroidFirmwareConnectionCard extends StatelessWidget {
  const _AndroidFirmwareConnectionCard({
    required this.serialConnected,
    required this.usbState,
    required this.error,
    required this.probing,
    required this.requestingPermission,
    required this.busy,
    required this.onRefresh,
    required this.onRequestPermission,
    this.identityWarning = 'USB 磁盘本身不能证明热成像型号；烧录仍以此前串口确认的设备身份和固件变体为准。',
  });

  final bool serialConnected;
  final AndroidFirmwareUsbState? usbState;
  final Object? error;
  final bool probing;
  final bool requestingPermission;
  final bool busy;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRequestPermission;
  final String identityWarning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bootloaders =
        usbState?.bootloaders ?? const <AndroidBootloaderDevice>[];
    final bootloader = bootloaders.length == 1 ? bootloaders.single : null;

    late final IconData icon;
    late final String title;
    late final String detail;
    var isError = false;
    if (error != null) {
      icon = Icons.error_outline_rounded;
      title = 'USB 阶段发生错误';
      detail = error
          .toString()
          .replaceFirst(RegExp(r'^Bad state:\s*'), '')
          .replaceFirst(RegExp(r'^StateError:\s*'), '');
      isError = true;
    } else if (usbState == null) {
      icon = Icons.usb_rounded;
      title = '正在检测 USB 设备';
      detail = '正在判断设备当前处于串口模式还是 RP2040 USB 磁盘模式。';
    } else if (!usbState!.usbHostSupported) {
      icon = Icons.usb_off_rounded;
      title = '此 Android 设备不支持 USB Host / OTG';
      detail = '无法直接访问 RP2040 Bootloader。';
      isError = true;
    } else if (bootloaders.length > 1) {
      icon = Icons.warning_amber_rounded;
      title = '检测到多个 RP2040 USB 磁盘';
      detail = '无法安全确定烧录目标，请只保留待烧录设备。';
      isError = true;
    } else if (serialConnected && bootloader != null) {
      icon = Icons.warning_amber_rounded;
      title = '同时检测到串口和 USB 磁盘';
      detail = '这通常表示连接了两台设备；为防止刷错，请断开无关设备。';
      isError = true;
    } else if (bootloader != null && !bootloader.hasPermission) {
      icon = Icons.lock_outline_rounded;
      title = '阶段 2/4 · 已检测到 RP2040 USB 磁盘';
      detail = '尚未获得此枚举实例的访问权限，请先完成系统 USB 授权。';
    } else if (bootloader != null) {
      icon = Icons.usb_rounded;
      title = '阶段 3/4 · RP2040 USB 磁盘已授权';
      detail = '可以验证 RPI-RP2 磁盘结构并继续写入 UF2。';
    } else if (serialConnected) {
      icon = Icons.settings_input_component_rounded;
      title = '阶段 1/4 · 串口设备已连接';
      detail = '开始后将发送 1200 波特率切换命令；若失败可手动进入 BOOTSEL。';
    } else {
      icon = Icons.usb_off_rounded;
      title = '未检测到可烧录设备';
      detail = '请连接串口设备，或让已确认的设备进入 RP2040 BOOTSEL 模式。';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (bootloader != null) ...[
            const SizedBox(height: 8),
            Text(
              'BOOTSEL ${bootloader.id}。$identityWarning',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: busy || probing ? null : onRefresh,
                icon: probing
                    ? const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新检测'),
              ),
              if (bootloader != null && !bootloader.hasPermission)
                FilledButton.tonalIcon(
                  onPressed: busy || requestingPermission
                      ? null
                      : onRequestPermission,
                  icon: requestingPermission
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open_rounded, size: 18),
                  label: Text(requestingPermission ? '等待系统授权' : '授权 USB 磁盘'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({required this.current, required this.target});

  final String current;
  final String target;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: Text('当前 $current', textAlign: TextAlign.center)),
          const Icon(Icons.arrow_forward_rounded),
          Expanded(
            child: Text(
              '目标 $target',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningBox extends StatelessWidget {
  const _WarningBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: scheme.onErrorContainer, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _phaseIcon(FirmwareUpdatePhase phase) => switch (phase) {
  FirmwareUpdatePhase.downloading => Icons.download_rounded,
  FirmwareUpdatePhase.waitingForBootloader => Icons.usb_rounded,
  FirmwareUpdatePhase.flashing => Icons.memory_rounded,
  FirmwareUpdatePhase.reconnecting => Icons.sync_rounded,
  FirmwareUpdatePhase.completed => Icons.verified_rounded,
  FirmwareUpdatePhase.error => Icons.error_outline_rounded,
  _ => Icons.info_outline_rounded,
};
