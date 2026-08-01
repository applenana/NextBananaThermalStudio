import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../serial/serial_service.dart';
import '../update/app_update.dart' show AppVersion, githubProxyUri;
import 'android_uf2_flasher.dart';
import 'firmware_update.dart';

enum FirmwareUpdatePhase {
  idle,
  checking,
  ready,
  updateAvailable,
  downloading,
  waitingForBootloader,
  flashing,
  reconnecting,
  completed,
  error,
}

class FirmwareUpdateSnapshot {
  const FirmwareUpdateSnapshot({
    this.phase = FirmwareUpdatePhase.idle,
    this.message,
    this.progress,
    this.target,
  });

  final FirmwareUpdatePhase phase;
  final String? message;
  final double? progress;
  final FirmwareRelease? target;

  bool get busy => switch (phase) {
    FirmwareUpdatePhase.downloading ||
    FirmwareUpdatePhase.waitingForBootloader ||
    FirmwareUpdatePhase.flashing ||
    FirmwareUpdatePhase.reconnecting => true,
    _ => false,
  };
}

class FirmwareCatalog {
  const FirmwareCatalog({
    required this.releases,
    required this.sourceLabel,
    required this.singleSourceFallback,
  });

  final List<FirmwareRelease> releases;
  final String sourceLabel;
  final bool singleSourceFallback;
}

class FirmwareUpdateNotice {
  const FirmwareUpdateNotice({
    required this.identity,
    required this.latest,
    required this.catalog,
  });

  final FirmwareDeviceIdentity identity;
  final FirmwareRelease latest;
  final FirmwareCatalog catalog;
}

class FirmwareRecoverySession {
  const FirmwareRecoverySession({
    required this.identity,
    required this.targetTag,
    required this.variant,
    required this.createdAt,
  });

  final FirmwareDeviceIdentity identity;
  final String targetTag;
  final FirmwareVariant variant;
  final DateTime createdAt;
}

class CustomFirmwareImage {
  const CustomFirmwareImage({
    required this.file,
    required this.originalName,
    required this.destinationName,
    required this.bytes,
    required this.blockCount,
    required this.sha256,
  });

  final File file;
  final String originalName;
  final String destinationName;
  final int bytes;
  final int blockCount;
  final String sha256;
}

class FirmwareUpdateService {
  FirmwareUpdateService._();

  static final FirmwareUpdateService instance = FirmwareUpdateService._();

  static final Uri releasesPage = Uri.parse(
    'https://github.com/$firmwareRepositoryOwner/$firmwareRepositoryName/releases',
  );
  static final Uri _releasesApi = Uri.parse(
    'https://api.github.com/repos/$firmwareRepositoryOwner/'
    '$firmwareRepositoryName/releases?per_page=100',
  );
  static const _autoCheckKey = 'firmware_update_auto_check';
  static const _deviceVariantsKey = 'firmware_update_device_variants';
  static const _recoverySessionKey = 'firmware_update_recovery_session';
  static const _recoverySessionLifetime = Duration(hours: 24);

  static final List<_FirmwareSource> _metadataMirrors = [
    for (final base in const [
      'https://gh-proxy.com/',
      'https://gh-proxy.org/',
      'https://gh-proxy.cn/',
      'https://gh.llkk.cc/',
      'https://ghproxy.cfd/',
      'https://github.chenc.dev/',
      'https://hub.gitmirror.com/',
    ])
      _FirmwareSource(
        label: '镜像 ${Uri.parse(base).host}',
        uri: githubProxyUri(Uri.parse(base), _releasesApi),
      ),
  ];
  static final List<_FirmwareMirror> _downloadMirrors = [
    for (final base in const [
      'https://gh-proxy.com/',
      'https://gh-proxy.org/',
      'https://gh-proxy.cn/',
      'https://ghproxy.net/',
      'https://ghfast.top/',
      'https://gh.llkk.cc/',
      'https://ghproxy.cfd/',
      'https://github.chenc.dev/',
      'https://hub.gitmirror.com/',
    ])
      _FirmwareMirror(Uri.parse(base).host, Uri.parse(base)),
  ];

  final ValueNotifier<FirmwareUpdateSnapshot> snapshot = ValueNotifier(
    const FirmwareUpdateSnapshot(),
  );
  final ValueNotifier<bool> automaticCheckEnabled = ValueNotifier(true);
  final ValueNotifier<FirmwareRecoverySession?> recoverySession = ValueNotifier(
    null,
  );

  SharedPreferences? _preferences;
  Map<String, FirmwareVariant> _rememberedVariants = {};
  FirmwareCatalog? _catalog;
  DateTime? _catalogAt;
  Future<FirmwareCatalog>? _activeCatalogRequest;
  HttpClient? _downloadClient;
  bool _cancelDownload = false;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _preferences = await SharedPreferences.getInstance();
    automaticCheckEnabled.value = _preferences?.getBool(_autoCheckKey) ?? true;
    final encoded = _preferences?.getString(_deviceVariantsKey);
    if (encoded != null) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map) {
          final restored = <String, FirmwareVariant>{};
          for (final entry in decoded.entries) {
            final variant = FirmwareVariant.fromEnvironment(entry.value);
            if (variant != null) restored[entry.key.toString()] = variant;
          }
          _rememberedVariants = restored;
        }
      } catch (_) {
        _rememberedVariants = {};
      }
    }
    final recoveryEncoded = _preferences?.getString(_recoverySessionKey);
    if (recoveryEncoded != null) {
      try {
        final decoded = jsonDecode(recoveryEncoded);
        if (decoded is Map) {
          final createdAt = DateTime.tryParse(
            decoded['createdAt']?.toString() ?? '',
          );
          final variant = FirmwareVariant.fromEnvironment(decoded['variant']);
          final targetTag = decoded['targetTag']?.toString();
          final model = decoded['model']?.toString();
          final now = DateTime.now();
          if (createdAt != null &&
              variant != null &&
              targetTag != null &&
              targetTag.isNotEmpty &&
              model == bananaDualLightModel &&
              !createdAt.isAfter(now.add(const Duration(minutes: 5))) &&
              now.difference(createdAt) <= _recoverySessionLifetime) {
            recoverySession.value = FirmwareRecoverySession(
              identity: FirmwareDeviceIdentity(
                family: FirmwareDeviceFamily.bananaDualLight,
                model: model,
                currentVersion: decoded['currentVersion']?.toString(),
                serialNumber: decoded['serialNumber']?.toString(),
                reportedVariant: variant,
                reason: '已恢复上次经过串口确认的双光热成像烧录会话',
              ),
              targetTag: targetTag,
              variant: variant,
              createdAt: createdAt,
            );
          } else {
            await _preferences?.remove(_recoverySessionKey);
          }
        }
      } catch (_) {
        await _preferences?.remove(_recoverySessionKey);
      }
    }
    _initialized = true;
  }

  Future<void> setAutomaticCheckEnabled(bool enabled) async {
    await initialize();
    automaticCheckEnabled.value = enabled;
    await _preferences?.setBool(_autoCheckKey, enabled);
  }

  FirmwareVariant? variantFor(FirmwareDeviceIdentity identity) =>
      identity.reportedVariant ?? _rememberedVariants[identity.deviceKey];

  Future<void> rememberVariant(
    FirmwareDeviceIdentity identity,
    FirmwareVariant variant,
  ) async {
    await initialize();
    if (identity.serialNumber == null || identity.serialNumber!.isEmpty) return;
    _rememberedVariants[identity.deviceKey] = variant;
    await _preferences?.setString(
      _deviceVariantsKey,
      jsonEncode({
        for (final entry in _rememberedVariants.entries)
          entry.key: entry.value.environment,
      }),
    );
  }

  Future<void> rememberRecoverySession(
    FirmwareDeviceIdentity identity,
    FirmwareRelease release,
    FirmwareVariant variant,
  ) async {
    await initialize();
    if (!identity.canFlash || identity.model != bananaDualLightModel) {
      throw StateError('只有经过串口确认的双光热成像可以建立恢复烧录会话');
    }
    final session = FirmwareRecoverySession(
      identity: identity,
      targetTag: release.tagName,
      variant: variant,
      createdAt: DateTime.now(),
    );
    recoverySession.value = session;
    await _preferences?.setString(
      _recoverySessionKey,
      jsonEncode({
        'model': identity.model,
        'currentVersion': identity.currentVersion,
        'serialNumber': identity.serialNumber,
        'targetTag': release.tagName,
        'variant': variant.environment,
        'createdAt': session.createdAt.toIso8601String(),
      }),
    );
  }

  Future<void> clearRecoverySession() async {
    await initialize();
    recoverySession.value = null;
    await _preferences?.remove(_recoverySessionKey);
  }

  void markReady(String message) {
    if (snapshot.value.busy) return;
    snapshot.value = FirmwareUpdateSnapshot(
      phase: FirmwareUpdatePhase.ready,
      message: message,
      target: snapshot.value.target,
    );
  }

  Future<void> resetPreferences() async {
    await initialize();
    automaticCheckEnabled.value = true;
    _rememberedVariants.clear();
    recoverySession.value = null;
    await _preferences?.remove(_autoCheckKey);
    await _preferences?.remove(_deviceVariantsKey);
    await _preferences?.remove(_recoverySessionKey);
  }

  Future<FirmwareCatalog> loadCatalog({bool force = false}) {
    final cached = _catalog;
    final cachedAt = _catalogAt;
    if (!force &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(minutes: 5)) {
      return Future.value(cached);
    }
    final active = _activeCatalogRequest;
    if (active != null) return active;
    final request = _fetchCatalog();
    _activeCatalogRequest = request;
    return request.whenComplete(() {
      if (identical(_activeCatalogRequest, request)) {
        _activeCatalogRequest = null;
      }
    });
  }

  Future<FirmwareUpdateNotice?> checkForUpdate(
    FirmwareDeviceIdentity identity, {
    bool manual = false,
  }) async {
    await initialize();
    if (!identity.canFlash) {
      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.error,
        message: identity.reason,
      );
      return null;
    }
    if (!manual && !automaticCheckEnabled.value) return null;
    snapshot.value = const FirmwareUpdateSnapshot(
      phase: FirmwareUpdatePhase.checking,
      message: '正在检查设备固件版本…',
    );
    try {
      final catalog = await loadCatalog(force: manual);
      if (catalog.releases.isEmpty) {
        throw const FormatException('官方仓库没有可用的固件 Release');
      }
      final newer = findNewerFirmware(identity, catalog.releases);
      if (newer == null) {
        final current = identity.currentVersion;
        snapshot.value = FirmwareUpdateSnapshot(
          phase: FirmwareUpdatePhase.ready,
          message: current == null
              ? '已获取固件列表，但设备没有可比较的固件版本号'
              : '设备固件 $current 已是最新正式版',
        );
        return null;
      }
      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.updateAvailable,
        target: newer,
        message: '发现设备固件新版本 ${newer.tagName}',
      );
      return FirmwareUpdateNotice(
        identity: identity,
        latest: newer,
        catalog: catalog,
      );
    } catch (error) {
      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.error,
        message: _friendlyError(error),
      );
      return null;
    }
  }

  Future<void> flashFirmware({
    required AppState app,
    required FirmwareDeviceIdentity identity,
    required FirmwareRelease release,
    required FirmwareVariant variant,
  }) async {
    if (!Platform.isWindows && !Platform.isAndroid) {
      throw UnsupportedError('自动烧录目前支持 Windows 和 Android');
    }
    if (!identity.canFlash) throw StateError(identity.reason);
    if (snapshot.value.busy) throw StateError('已有固件烧录任务正在进行');

    _cancelDownload = false;
    try {
      final bundle = await _downloadBundle(release, variant);
      await validateRp2040Uf2File(bundle.file);
      final port = app.currentPort;

      if (Platform.isAndroid) {
        final usbState = await AndroidUf2Flasher.inspectUsbState();
        if (!usbState.usbHostSupported) {
          throw StateError('此 Android 设备不支持 USB Host / OTG');
        }
        if (usbState.bootloaders.length > 1) {
          throw StateError('检测到多个 RP2040 USB 磁盘，请只保留待烧录设备');
        }
        final bootloader = usbState.singleBootloader;
        final serialConnected =
            port != null && app.status == ConnectionStatus.connected;
        if (bootloader != null && serialConnected) {
          throw StateError('同时检测到串口设备和 RP2040 USB 磁盘，无法确认目标；请只连接一台待烧录设备');
        }
        if (bootloader == null && !serialConnected) {
          throw StateError('没有检测到串口设备或 RP2040 USB 磁盘');
        }

        await rememberRecoverySession(identity, release, variant);
        if (bootloader != null) {
          snapshot.value = FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.waitingForBootloader,
            target: release,
            message: bootloader.hasPermission
                ? '已检测到并授权 RP2040 USB 磁盘，正在验证磁盘结构…'
                : '已检测到 RP2040 USB 磁盘，等待 USB 系统授权…',
          );
          if (!bootloader.hasPermission) {
            await AndroidUf2Flasher.requestPermission(bootloader);
          }
        } else {
          snapshot.value = FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.waitingForBootloader,
            target: release,
            message: '已检测到串口设备，正在切换到 RP2040 Bootloader…',
          );
          await app.disconnect();
          final touched = await SerialService.touch1200Bootloader(port!);
          snapshot.value = FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.waitingForBootloader,
            target: release,
            message: touched
                ? '串口切换命令已发送，等待 RP2040 USB 磁盘…'
                : '自动切换未确认；请按住按钮 A / BOOTSEL，短按 RESET 后松开按钮 A',
          );
        }

        await AndroidUf2Flasher.flashUf2(
          firmware: bundle.file,
          expectedSha256: bundle.artifact.sha256,
          destinationName: bundle.artifact.file,
          timeout: const Duration(seconds: 50),
          onProgress: (progress, message) {
            final phase =
                message.startsWith('等待') ||
                    message.contains('授权') ||
                    message.contains('结构已校验')
                ? FirmwareUpdatePhase.waitingForBootloader
                : FirmwareUpdatePhase.flashing;
            snapshot.value = FirmwareUpdateSnapshot(
              phase: phase,
              progress: progress,
              target: release,
              message: message,
            );
          },
        );
      } else {
        if (port == null || app.status != ConnectionStatus.connected) {
          throw StateError('设备已断开，请重新连接后再烧录');
        }
        final windowsBaseline = await Uf2Flasher.findRp2040Volumes();
        snapshot.value = FirmwareUpdateSnapshot(
          phase: FirmwareUpdatePhase.waitingForBootloader,
          target: release,
          message: '正在让设备进入 RP2040 Bootloader…',
        );
        await app.disconnect();
        final touched = await SerialService.touch1200Bootloader(port);
        if (!touched) {
          debugPrint('1200-baud bootloader touch failed for $port');
        }
        final volume = await Uf2Flasher.waitForSingleRp2040Volume(
          baseline: windowsBaseline.map((item) => item.root.path).toSet(),
          timeout: const Duration(seconds: 50),
          onStillWaiting: () {
            snapshot.value = FirmwareUpdateSnapshot(
              phase: FirmwareUpdatePhase.waitingForBootloader,
              target: release,
              message:
                  '等待 RP2040 磁盘：按住按钮 A / BOOTSEL，短按 RESET，'
                  '看到磁盘后松开按钮 A；程序会继续自动烧录',
            );
          },
        );

        snapshot.value = FirmwareUpdateSnapshot(
          phase: FirmwareUpdatePhase.flashing,
          progress: 0,
          target: release,
          message: '已识别 ${volume.root.path}，正在写入 ${bundle.artifact.file}',
        );
        await Uf2Flasher.copyFirmware(
          bundle.file,
          volume,
          destinationName: bundle.artifact.file,
          onProgress: (progress) {
            snapshot.value = FirmwareUpdateSnapshot(
              phase: FirmwareUpdatePhase.flashing,
              progress: progress,
              target: release,
              message: '正在烧录 ${release.tagName} · ${variant.label}',
            );
          },
        );
        await Uf2Flasher.waitForVolumeToDisappear(
          volume,
          timeout: const Duration(seconds: 12),
        );
      }

      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.reconnecting,
        target: release,
        message: '固件已写入，正在等待设备重启并回读版本…',
      );
      final connected = await _reconnect(app);
      if (!connected) {
        throw StateError('UF2 已写入，但设备未自动重连；请重新插拔 USB 后核对版本');
      }
      final updatedIdentity = FirmwareDeviceIdentity.fromDeviceInfo(
        app.deviceInfo,
      );
      final actual = AppVersion.tryParse(updatedIdentity.currentVersion ?? '');
      if (!updatedIdentity.canFlash ||
          actual == null ||
          actual.compareTo(release.version) != 0) {
        throw StateError(
          '设备已重连，但回读版本 ${updatedIdentity.currentVersion ?? '未知'} '
          '与目标 ${release.tagName} 不一致',
        );
      }
      await rememberVariant(updatedIdentity, variant);
      if (Platform.isAndroid) await clearRecoverySession();
      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.completed,
        progress: 1,
        target: release,
        message: '烧录完成并已验证设备版本 ${release.tagName}',
      );
    } catch (error) {
      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.error,
        target: release,
        message: _friendlyError(error),
      );
      rethrow;
    }
  }

  Future<CustomFirmwareImage> prepareCustomFirmware(File source) async {
    final originalName = p.basename(source.path);
    if (p.extension(originalName).toLowerCase() != '.uf2') {
      throw const FormatException('请选择扩展名为 .uf2 的固件文件');
    }
    if (!await source.exists()) {
      throw FileSystemException('选择的 UF2 文件不存在', source.path);
    }
    final blockCount = await validateRp2040Uf2File(source);
    final bytes = await source.length();
    final digest = (await sha256.bind(source.openRead()).first).toString();

    // 文件选择器在 Android/macOS 上可能只临时授予外部文件访问权。立即复制到
    // 应用缓存，既保证后续烧录仍可读取，也满足 Android 原生层只接受私有路径
    // 的安全约束。
    final temporary = await getTemporaryDirectory();
    final cacheDirectory = Directory(p.join(temporary.path, 'custom-firmware'));
    await cacheDirectory.create(recursive: true);
    final destinationName = 'CUSTOM-${digest.substring(0, 12)}.UF2';
    final cached = File(p.join(cacheDirectory.path, destinationName));
    if (!await _fileMatches(cached, bytes, digest)) {
      final partial = File('${cached.path}.partial');
      try {
        if (await partial.exists()) await partial.delete();
        await source.copy(partial.path);
        if (!await _fileMatches(partial, bytes, digest)) {
          throw const FormatException('复制到应用缓存后的 UF2 校验失败');
        }
        if (await cached.exists()) await cached.delete();
        await partial.rename(cached.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    final cachedBlockCount = await validateRp2040Uf2File(cached);
    if (cachedBlockCount != blockCount) {
      throw const FormatException('复制到应用缓存后的 UF2 块数发生变化');
    }
    return CustomFirmwareImage(
      file: cached,
      originalName: originalName,
      destinationName: destinationName,
      bytes: bytes,
      blockCount: blockCount,
      sha256: digest,
    );
  }

  Future<void> flashCustomFirmware({
    required AppState app,
    required CustomFirmwareImage image,
    Uf2Volume? selectedDesktopVolume,
    Future<Uf2Volume?> Function()? selectDesktopVolume,
  }) async {
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    if (!Platform.isAndroid && !desktop) {
      throw UnsupportedError('当前构建不支持直接写入 RP2040 UF2');
    }
    if (snapshot.value.busy) throw StateError('已有固件烧录任务正在进行');

    try {
      final blockCount = await validateRp2040Uf2File(image.file);
      if (blockCount != image.blockCount ||
          !await _fileMatches(image.file, image.bytes, image.sha256)) {
        throw const FormatException('自定义 UF2 在选择后发生变化，已拒绝烧录');
      }
      final port = app.currentPort;
      final serialConnected =
          port != null && app.status == ConnectionStatus.connected;

      if (Platform.isAndroid) {
        final usbState = await AndroidUf2Flasher.inspectUsbState();
        if (!usbState.usbHostSupported) {
          throw StateError('此 Android 设备不支持 USB Host / OTG');
        }
        if (usbState.bootloaders.length > 1) {
          throw StateError('检测到多个 RP2040 USB 磁盘，请只保留待烧录设备');
        }
        final bootloader = usbState.singleBootloader;
        if (bootloader != null && serialConnected) {
          throw StateError('同时检测到串口设备和 RP2040 USB 磁盘，无法安全确定烧录目标');
        }
        if (bootloader == null && !serialConnected) {
          throw StateError('没有检测到串口设备或 RP2040 USB 磁盘');
        }
        if (bootloader != null && !bootloader.hasPermission) {
          snapshot.value = const FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.waitingForBootloader,
            message: '自定义 UF2 已校验，等待 RP2040 USB 系统授权…',
          );
          await AndroidUf2Flasher.requestPermission(bootloader);
        } else if (bootloader == null) {
          snapshot.value = const FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.waitingForBootloader,
            message: '正在让串口设备进入 RP2040 Bootloader…',
          );
          await app.disconnect();
          final touched = await SerialService.touch1200Bootloader(port!);
          snapshot.value = FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.waitingForBootloader,
            message: touched
                ? '串口切换命令已发送，等待 RP2040 USB 磁盘…'
                : '自动切换未确认；请手动使用 BOOTSEL / RESET 进入 USB 磁盘模式',
          );
        }

        await AndroidUf2Flasher.flashUf2(
          firmware: image.file,
          expectedSha256: image.sha256,
          destinationName: image.destinationName,
          timeout: const Duration(seconds: 60),
          onProgress: (progress, message) {
            final waiting =
                message.startsWith('等待') ||
                message.contains('授权') ||
                message.contains('结构已校验');
            snapshot.value = FirmwareUpdateSnapshot(
              phase: waiting
                  ? FirmwareUpdatePhase.waitingForBootloader
                  : FirmwareUpdatePhase.flashing,
              progress: progress,
              message: message,
            );
          },
        );
      } else {
        final existingByPath = <String, Uf2Volume>{};
        for (final volume in await Uf2Flasher.findRp2040Volumes()) {
          existingByPath[p.normalize(volume.root.path)] = volume;
        }
        if (selectedDesktopVolume != null) {
          final refreshed = await Uf2Flasher.inspectRp2040Volume(
            selectedDesktopVolume.root,
          );
          if (refreshed == null) {
            throw StateError('先前选择的目录已不是可访问的 RP2040 UF2 磁盘，请重新选择');
          }
          existingByPath[p.normalize(refreshed.root.path)] = refreshed;
        }
        final existing = existingByPath.values.toList();
        if (existing.length > 1) {
          throw StateError('检测到多个 RP2040 UF2 磁盘，请只保留待烧录设备');
        }
        if (existing.isNotEmpty && serialConnected) {
          throw StateError('同时检测到串口设备和 RP2040 UF2 磁盘，无法安全确定烧录目标');
        }
        if (existing.isEmpty && !serialConnected) {
          throw StateError('没有检测到串口设备或 RP2040 UF2 磁盘');
        }

        late final Uf2Volume volume;
        if (existing.length == 1) {
          volume = existing.single;
        } else {
          snapshot.value = const FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.waitingForBootloader,
            message: '正在让串口设备进入 RP2040 Bootloader…',
          );
          await app.disconnect();
          final touched = await SerialService.touch1200Bootloader(port!);
          if (!touched) {
            snapshot.value = const FirmwareUpdateSnapshot(
              phase: FirmwareUpdatePhase.waitingForBootloader,
              message: '自动切换未确认；请手动使用 BOOTSEL / RESET 进入 UF2 磁盘模式',
            );
          }
          if (Platform.isMacOS && selectDesktopVolume != null) {
            snapshot.value = const FirmwareUpdateSnapshot(
              phase: FirmwareUpdatePhase.waitingForBootloader,
              message: '请在系统窗口中选择刚出现的 RPI-RP2 磁盘根目录',
            );
            final selected = await selectDesktopVolume();
            if (selected == null) {
              throw StateError('未选择 RP2040 UF2 磁盘，已取消烧录');
            }
            final refreshed = await Uf2Flasher.inspectRp2040Volume(
              selected.root,
            );
            if (refreshed == null) {
              throw StateError('所选目录不是可访问的 RP2040 UF2 磁盘根目录');
            }
            volume = refreshed;
          } else {
            volume = await Uf2Flasher.waitForSingleRp2040Volume(
              baseline: const <String>{},
              timeout: const Duration(seconds: 60),
              onStillWaiting: () {
                snapshot.value = const FirmwareUpdateSnapshot(
                  phase: FirmwareUpdatePhase.waitingForBootloader,
                  message: '等待 RP2040 UF2 磁盘；检测到后会继续写入自定义固件',
                );
              },
            );
          }
        }

        snapshot.value = FirmwareUpdateSnapshot(
          phase: FirmwareUpdatePhase.flashing,
          progress: 0,
          message: '已验证 ${volume.root.path}，正在写入 ${image.originalName}',
        );
        await Uf2Flasher.copyFirmware(
          image.file,
          volume,
          destinationName: image.destinationName,
          onProgress: (progress) {
            snapshot.value = FirmwareUpdateSnapshot(
              phase: FirmwareUpdatePhase.flashing,
              progress: progress,
              message: '正在写入自定义 UF2 · ${(progress * 100).toStringAsFixed(0)}%',
            );
          },
        );
        await Uf2Flasher.waitForVolumeToDisappear(
          volume,
          timeout: const Duration(seconds: 12),
        );
      }

      snapshot.value = const FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.reconnecting,
        message: '自定义 UF2 已完整提交，正在尝试重新识别设备…',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      var reconnected = false;
      try {
        reconnected = await app.autoSearchAndConnect();
      } catch (_) {
        reconnected = false;
      }
      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.completed,
        progress: 1,
        message: reconnected
            ? '自定义 UF2 已写入，设备已重新识别；无法验证第三方固件版本或功能'
            : '自定义 UF2 已提交；设备未被自动识别，请手动检查固件功能和 USB 状态',
      );
    } catch (error) {
      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.error,
        message: _friendlyError(error),
      );
      rethrow;
    }
  }

  void cancelDownload() {
    if (snapshot.value.phase != FirmwareUpdatePhase.downloading) return;
    _cancelDownload = true;
    _downloadClient?.close(force: true);
  }

  Future<void> openReleasePage([FirmwareRelease? release]) async {
    final uri = release?.pageUrl ?? releasesPage;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const FileSystemException('无法打开固件发布页面');
    }
  }

  Future<FirmwareCatalog> _fetchCatalog() async {
    try {
      final releases = await _fetchReleasesFrom(
        _FirmwareSource(label: '官方 GitHub', uri: _releasesApi),
        timeout: const Duration(seconds: 15),
      );
      final catalog = FirmwareCatalog(
        releases: releases,
        sourceLabel: '官方 GitHub',
        singleSourceFallback: false,
      );
      _catalog = catalog;
      _catalogAt = DateTime.now();
      return catalog;
    } catch (error) {
      debugPrint('Official firmware catalog failed: $error');
    }

    final attempts = await Future.wait(
      _metadataMirrors.map((source) async {
        try {
          return _FirmwareCatalogAttempt(
            source: source,
            releases: await _fetchReleasesFrom(
              source,
              timeout: const Duration(seconds: 18),
            ),
          );
        } catch (error) {
          return _FirmwareCatalogAttempt(source: source, error: error);
        }
      }),
    );
    final valid = attempts
        .where((attempt) => attempt.releases != null)
        .toList();
    if (valid.isEmpty) {
      throw const HttpException('官方源和固件镜像均不可用');
    }
    final groups = <String, List<_FirmwareCatalogAttempt>>{};
    for (final attempt in valid) {
      groups
          .putIfAbsent(_catalogIdentity(attempt.releases!), () => [])
          .add(attempt);
    }
    final ranked = groups.values.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (ranked.length > 1 && ranked[0].length == ranked[1].length) {
      throw const FormatException('多个固件镜像返回冲突的版本列表，已拒绝采用');
    }
    final winner = ranked.first;
    if (valid.length > 1 && winner.length < 2) {
      throw const FormatException('固件镜像版本信息无法交叉验证');
    }
    final labels = winner.map((attempt) => attempt.source.label).join(' + ');
    final catalog = FirmwareCatalog(
      releases: winner.first.releases!,
      sourceLabel: winner.length == 1 ? '单一镜像（$labels）' : '镜像共识（$labels）',
      singleSourceFallback: winner.length == 1,
    );
    _catalog = catalog;
    _catalogAt = DateTime.now();
    return catalog;
  }

  Future<List<FirmwareRelease>> _fetchReleasesFrom(
    _FirmwareSource source, {
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(source.uri);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28')
        ..set(HttpHeaders.userAgentHeader, 'BananaThermalStudio-Firmware');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('${source.label} 返回 HTTP ${response.statusCode}');
      }
      final bytes = BytesBuilder(copy: false);
      const maximumBytes = 4 * 1024 * 1024;
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > maximumBytes) {
          throw const FormatException('固件版本列表超过安全大小限制');
        }
        bytes.add(chunk);
      }
      final releases = parseFirmwareReleaseList(utf8.decode(bytes.takeBytes()));
      if (releases.isEmpty) throw const FormatException('没有有效的正式固件版本');
      return releases;
    } finally {
      client.close(force: true);
    }
  }

  Future<_FirmwareBundle> _downloadBundle(
    FirmwareRelease release,
    FirmwareVariant variant,
  ) async {
    final manifestAsset = release.assetNamed('manifest.json');
    if (manifestAsset == null || !manifestAsset.hasGitHubDigest) {
      throw const FormatException('Release manifest 缺少 GitHub SHA-256，已拒绝自动烧录');
    }
    final directory = await _downloadDirectory(release.tagName);
    await directory.create(recursive: true);
    snapshot.value = FirmwareUpdateSnapshot(
      phase: FirmwareUpdatePhase.downloading,
      target: release,
      progress: 0,
      message: '正在下载并验证 ${release.tagName} 固件清单…',
    );
    final manifestFile = await _downloadVerified(
      manifestAsset,
      directory,
      expectedSize: manifestAsset.size,
      expectedSha256: manifestAsset.sha256!,
    );
    if (await manifestFile.length() > 1024 * 1024) {
      throw const FormatException('manifest 超过安全大小限制');
    }
    final manifest = FirmwareManifest.fromJsonString(
      await manifestFile.readAsString(),
      expectedTag: release.tagName,
    );
    final artifact = manifest.artifactFor(variant);
    final asset = release.assetNamed(artifact.file);
    if (asset == null || asset.size != artifact.size) {
      throw FormatException('Release 缺少与 manifest 一致的 ${artifact.file}');
    }
    if (asset.sha256 != null && asset.sha256 != artifact.sha256) {
      throw FormatException('${artifact.file} 的 GitHub 摘要与 manifest 冲突');
    }
    snapshot.value = FirmwareUpdateSnapshot(
      phase: FirmwareUpdatePhase.downloading,
      target: release,
      progress: 0,
      message: '正在下载 ${artifact.file}…',
    );
    final file = await _downloadVerified(
      asset,
      directory,
      expectedSize: artifact.size,
      expectedSha256: artifact.sha256,
    );
    return _FirmwareBundle(file: file, artifact: artifact);
  }

  Future<File> _downloadVerified(
    FirmwareReleaseAsset asset,
    Directory directory, {
    required int expectedSize,
    required String expectedSha256,
  }) async {
    final safeName = p.basename(asset.name);
    if (safeName != asset.name || safeName == '.' || safeName == '..') {
      throw const FormatException('固件附件文件名无效');
    }
    final destination = File(p.join(directory.path, safeName));
    final partial = File('${destination.path}.part');
    if (await _fileMatches(destination, expectedSize, expectedSha256)) {
      return destination;
    }
    if (await destination.exists()) await destination.delete();

    final sources = <_FirmwareSource>[
      _FirmwareSource(label: '官方 GitHub', uri: asset.downloadUrl),
      for (final mirror in _downloadMirrors)
        _FirmwareSource(
          label: '镜像 ${mirror.label}',
          uri: githubProxyUri(mirror.baseUri, asset.downloadUrl),
        ),
    ];
    final errors = <String>[];
    for (final source in sources) {
      if (_cancelDownload) throw const HttpException('下载已取消');
      if (await partial.exists()) await partial.delete();
      try {
        await _downloadToFile(
          source,
          partial,
          expectedSize: expectedSize,
          target: snapshot.value.target,
        );
        if (!await _fileMatches(partial, expectedSize, expectedSha256)) {
          throw FormatException('${source.label} 返回的文件大小或 SHA-256 不匹配');
        }
        if (await destination.exists()) await destination.delete();
        return await partial.rename(destination.path);
      } catch (error) {
        if (await partial.exists()) await partial.delete();
        if (_cancelDownload) throw const HttpException('下载已取消');
        errors.add('${source.label}：${_friendlyError(error)}');
      }
    }
    throw HttpException('所有固件下载源均失败：${errors.join('；')}');
  }

  Future<void> _downloadToFile(
    _FirmwareSource source,
    File partial, {
    required int expectedSize,
    required FirmwareRelease? target,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    _downloadClient = client;
    try {
      final request = await client.getUrl(source.uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'BananaThermalStudio-Firmware',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('${source.label} 返回 HTTP ${response.statusCode}');
      }
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 35),
        )) {
          if (_cancelDownload) throw const HttpException('下载已取消');
          received += chunk.length;
          if (received > expectedSize) {
            throw const FormatException('下载内容超过 manifest 声明大小');
          }
          sink.add(chunk);
          snapshot.value = FirmwareUpdateSnapshot(
            phase: FirmwareUpdatePhase.downloading,
            target: target,
            progress: (received / expectedSize).clamp(0.0, 1.0),
            message: '正在通过 ${source.label} 下载 ${p.basename(partial.path)}',
          );
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
      if (identical(_downloadClient, client)) _downloadClient = null;
    }
  }

  Future<Directory> _downloadDirectory(String tagName) async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'firmware', tagName));
  }

  Future<bool> _fileMatches(File file, int size, String digest) async {
    if (!await file.exists() || await file.length() != size) return false;
    final actual = (await sha256.bind(file.openRead()).first).toString();
    return actual == digest;
  }

  Future<bool> _reconnect(AppState app) async {
    final deadline = DateTime.now().add(const Duration(seconds: 35));
    while (DateTime.now().isBefore(deadline)) {
      final connected = await app.autoSearchAndConnect();
      if (connected) {
        final infoDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(infoDeadline)) {
          if (app.deviceInfo != null) return true;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  String _friendlyError(Object error) {
    if (error is SocketException) return '无法连接网络，请检查网络后重试';
    if (error is TimeoutException) return '操作超时，请检查 USB 或网络连接';
    return error.toString().replaceFirst(
      RegExp(r'^\w+(?:<[^>]+>)?Exception:\s*'),
      '',
    );
  }
}

const _uf2BlockBytes = 512;
const _uf2MagicStart0 = 0x0A324655;
const _uf2MagicStart1 = 0x9E5D5157;
const _uf2MagicEnd = 0x0AB16F30;
const _uf2FlagNotMainFlash = 0x00000001;
const _uf2FlagFamilyIdPresent = 0x00002000;
const _rp2040FamilyId = 0xE48BFF56;
const _rp2040XipBase = 0x10000000;
const _rp2040XipEnd = 0x11000000;
const _maximumUf2Bytes = 64 * 1024 * 1024;

/// 在断开当前设备之前复核整个 UF2 的 RP2040 写入契约。
///
/// 发布 manifest/SHA-256 解决“文件是不是官方发布的”，这里解决“文件本身是否
/// 是完整、连续且只写 RP2040 主 Flash 的 UF2”。Android 原生层还会独立复核
/// 一次，用于防止 MethodChannel 参数或应用私有缓存发生意外变化。
Future<int> validateRp2040Uf2File(File file) async {
  final length = await file.length();
  if (length <= 0 ||
      length > _maximumUf2Bytes ||
      length % _uf2BlockBytes != 0) {
    throw const FormatException('UF2 文件大小无效');
  }
  final blockCount = length ~/ _uf2BlockBytes;
  final input = await file.open();
  try {
    for (var index = 0; index < blockCount; index++) {
      final block = await input.read(_uf2BlockBytes);
      if (block.length != _uf2BlockBytes) {
        throw FormatException('UF2 第 ${index + 1} 块读取不完整');
      }
      validateRp2040Uf2Block(block, index: index, blockCount: blockCount);
    }
  } finally {
    await input.close();
  }
  return blockCount;
}

@visibleForTesting
void validateRp2040Uf2Block(
  Uint8List block, {
  required int index,
  required int blockCount,
}) {
  if (block.length != _uf2BlockBytes || index < 0 || blockCount <= 0) {
    throw const FormatException('UF2 块参数无效');
  }
  final data = ByteData.sublistView(block);
  if (data.getUint32(0, Endian.little) != _uf2MagicStart0 ||
      data.getUint32(4, Endian.little) != _uf2MagicStart1 ||
      data.getUint32(508, Endian.little) != _uf2MagicEnd) {
    throw FormatException('UF2 第 ${index + 1} 块魔数无效');
  }
  final flags = data.getUint32(8, Endian.little);
  final address = data.getUint32(12, Endian.little);
  final payloadSize = data.getUint32(16, Endian.little);
  final blockNumber = data.getUint32(20, Endian.little);
  final declaredBlocks = data.getUint32(24, Endian.little);
  final familyId = data.getUint32(28, Endian.little);
  if (payloadSize != 256 ||
      blockNumber != index ||
      declaredBlocks != blockCount) {
    throw FormatException('UF2 第 ${index + 1} 块的编号或负载长度无效');
  }
  if ((flags & _uf2FlagNotMainFlash) != 0 ||
      (flags & _uf2FlagFamilyIdPresent) == 0 ||
      familyId != _rp2040FamilyId) {
    throw const FormatException('UF2 不是 RP2040 主 Flash 固件');
  }
  if (address < _rp2040XipBase || address + payloadSize > _rp2040XipEnd) {
    throw const FormatException('UF2 包含超出 RP2040 Flash 的目标地址');
  }
}

class Uf2Volume {
  const Uf2Volume({required this.root, required this.info});

  final Directory root;
  final String info;
}

class Uf2Flasher {
  static bool isRp2040Info(String source) {
    final normalized = source.toLowerCase();
    return normalized.contains('uf2 bootloader') &&
        (normalized.contains('rp2040') ||
            normalized.contains('raspberry pi') ||
            normalized.contains('board-id: rpi-rp2'));
  }

  static Future<List<Uf2Volume>> findRp2040Volumes() async {
    final volumes = <Uf2Volume>[];
    final roots = await _candidateVolumeRoots();
    for (final root in roots) {
      final volume = await inspectRp2040Volume(root);
      if (volume != null) volumes.add(volume);
    }
    return volumes;
  }

  /// 对用户明确选择的目录执行与自动扫描完全相同的目标校验。
  ///
  /// macOS App Sandbox 需要用户通过系统目录选择器授予磁盘访问权；调用方可用
  /// 此方法确认选中的确是 RP2040 UF2 Bootloader 根目录，而不是任意可写目录。
  static Future<Uf2Volume?> inspectRp2040Volume(Directory root) async {
    final infoFile = File(p.join(root.path, 'INFO_UF2.TXT'));
    try {
      if (!await infoFile.exists()) return null;
      final handle = await infoFile.open();
      late final Uint8List bytes;
      try {
        final length = (await handle.length()).clamp(0, 64 * 1024).toInt();
        bytes = await handle.read(length);
      } finally {
        await handle.close();
      }
      final info = utf8.decode(bytes, allowMalformed: true);
      return isRp2040Info(info) ? Uf2Volume(root: root, info: info) : null;
    } catch (_) {
      // 未就绪、受保护或正在弹出的盘符视为无效目标。
      return null;
    }
  }

  static Future<List<Directory>> _candidateVolumeRoots() async {
    if (Platform.isWindows) {
      return [
        for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++)
          Directory('${String.fromCharCode(code)}:\\'),
      ];
    }
    if (Platform.isMacOS) {
      return _childDirectories(Directory('/Volumes'), depth: 1);
    }
    if (Platform.isLinux) {
      final roots = <Directory>[];
      for (final base in const ['/media', '/run/media', '/mnt']) {
        roots.addAll(await _childDirectories(Directory(base), depth: 2));
      }
      final seen = <String>{};
      return [
        for (final root in roots)
          if (seen.add(p.normalize(root.path))) root,
      ];
    }
    return const <Directory>[];
  }

  static Future<List<Directory>> _childDirectories(
    Directory base, {
    required int depth,
  }) async {
    if (depth <= 0) return const <Directory>[];
    try {
      if (!await base.exists()) return const <Directory>[];
      final result = <Directory>[];
      var count = 0;
      await for (final entity in base.list(followLinks: false)) {
        if (entity is! Directory) continue;
        result.add(entity);
        if (depth > 1) {
          result.addAll(await _childDirectories(entity, depth: depth - 1));
        }
        // Mount roots should remain small. Bound enumeration so an unusual /mnt
        // hierarchy cannot stall the firmware page.
        if (++count >= 128) break;
      }
      return result;
    } catch (_) {
      return const <Directory>[];
    }
  }

  static Future<Uf2Volume> waitForSingleRp2040Volume({
    required Set<String> baseline,
    required Duration timeout,
    required VoidCallback onStillWaiting,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var waitingHintShown = false;
    while (DateTime.now().isBefore(deadline)) {
      final volumes = await findRp2040Volumes();
      final newVolumes = volumes
          .where((volume) => !baseline.contains(volume.root.path))
          .toList();
      final candidates = newVolumes.isNotEmpty ? newVolumes : volumes;
      if (candidates.length == 1) return candidates.single;
      if (candidates.length > 1) {
        throw StateError('检测到多个 RP2040 UF2 磁盘，请只保留当前待烧录设备');
      }
      if (!waitingHintShown &&
          DateTime.now().isAfter(
            deadline.subtract(timeout - const Duration(seconds: 4)),
          )) {
        waitingHintShown = true;
        onStillWaiting();
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('未检测到 RP2040 UF2 磁盘');
  }

  static Future<void> copyFirmware(
    File firmware,
    Uf2Volume volume, {
    required String destinationName,
    required ValueChanged<double> onProgress,
  }) async {
    final length = await firmware.length();
    if (length <= 0) throw const FileSystemException('固件文件为空');
    final destination = File(
      p.join(volume.root.path, p.basename(destinationName)),
    );
    final input = await firmware.open();
    RandomAccessFile? output;
    var written = 0;
    try {
      output = await destination.open(mode: FileMode.write);
      while (true) {
        final chunk = await input.read(64 * 1024);
        if (chunk.isEmpty) break;
        await output.writeFrom(chunk);
        written += chunk.length;
        onProgress((written / length).clamp(0.0, 1.0));
      }
      await output.flush();
    } catch (_) {
      // RP2040 在完整 UF2 到达后会立即弹出磁盘；部分 Windows 版本会让最后
      // 一次 flush/close 报“设备不存在”。只有全部字节已提交时才接受该情况。
      if (written < length) rethrow;
    } finally {
      await input.close();
      try {
        await output?.close();
      } catch (_) {
        if (written < length) rethrow;
      }
    }
    if (written != length) {
      throw FileSystemException('UF2 写入不完整', destination.path);
    }
    onProgress(1);
  }

  static Future<void> waitForVolumeToDisappear(
    Uf2Volume volume, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final info = File(p.join(volume.root.path, 'INFO_UF2.TXT'));
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (!await info.exists()) return;
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}

class _FirmwareBundle {
  const _FirmwareBundle({required this.file, required this.artifact});

  final File file;
  final FirmwareArtifact artifact;
}

class _FirmwareSource {
  const _FirmwareSource({required this.label, required this.uri});

  final String label;
  final Uri uri;
}

class _FirmwareMirror {
  const _FirmwareMirror(this.label, this.baseUri);

  final String label;
  final Uri baseUri;
}

class _FirmwareCatalogAttempt {
  const _FirmwareCatalogAttempt({
    required this.source,
    this.releases,
    this.error,
  });

  final _FirmwareSource source;
  final List<FirmwareRelease>? releases;
  final Object? error;
}

String _catalogIdentity(List<FirmwareRelease> releases) => jsonEncode(
  releases.map((release) => release.verificationIdentity).toList(),
);
