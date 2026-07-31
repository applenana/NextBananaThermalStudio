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

  Future<void> resetPreferences() async {
    await initialize();
    automaticCheckEnabled.value = true;
    _rememberedVariants.clear();
    await _preferences?.remove(_autoCheckKey);
    await _preferences?.remove(_deviceVariantsKey);
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
    if (!Platform.isWindows) {
      throw UnsupportedError('自动烧录目前仅支持 Windows');
    }
    if (!identity.canFlash) throw StateError(identity.reason);
    if (snapshot.value.busy) throw StateError('已有固件烧录任务正在进行');

    _cancelDownload = false;
    try {
      final bundle = await _downloadBundle(release, variant);
      await rememberVariant(identity, variant);
      final port = app.currentPort;
      if (port == null || app.status != ConnectionStatus.connected) {
        throw StateError('设备已断开，请重新连接后再烧录');
      }

      final baseline = await Uf2Flasher.findRp2040Volumes();
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
        baseline: baseline.map((item) => item.root.path).toSet(),
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

      snapshot.value = FirmwareUpdateSnapshot(
        phase: FirmwareUpdatePhase.reconnecting,
        target: release,
        message: '固件已写入，正在等待设备重启并回读版本…',
      );
      await Uf2Flasher.waitForVolumeToDisappear(
        volume,
        timeout: const Duration(seconds: 12),
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
    if (!Platform.isWindows) return const [];
    final volumes = <Uf2Volume>[];
    for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
      final root = Directory('${String.fromCharCode(code)}:\\');
      final infoFile = File(p.join(root.path, 'INFO_UF2.TXT'));
      try {
        if (!await infoFile.exists()) continue;
        final handle = await infoFile.open();
        late final Uint8List bytes;
        try {
          final length = (await handle.length()).clamp(0, 64 * 1024).toInt();
          bytes = await handle.read(length);
        } finally {
          await handle.close();
        }
        final info = utf8.decode(bytes, allowMalformed: true);
        if (isRp2040Info(info)) volumes.add(Uf2Volume(root: root, info: info));
      } catch (_) {
        // 未就绪、受保护或正在弹出的盘符直接跳过。
      }
    }
    return volumes;
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
