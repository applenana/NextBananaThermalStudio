import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update.dart';

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  cancelled,
  ready,
  error,
}

class AppUpdateSnapshot {
  const AppUpdateSnapshot({
    this.phase = AppUpdatePhase.idle,
    this.info,
    this.progress,
    this.message,
    this.downloadedFile,
  });

  final AppUpdatePhase phase;
  final AppUpdateInfo? info;
  final double? progress;
  final String? message;
  final File? downloadedFile;
}

class AppUpdateService {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  static final Uri releasesPage = Uri.parse(
    'https://github.com/applenana/NextBananaThermalStudio/releases',
  );
  static final Uri _latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/applenana/NextBananaThermalStudio/releases/latest',
  );
  static final List<_UpdateSource> _metadataMirrorSources = [
    _UpdateSource(
      label: '镜像 gh-proxy.com',
      uri: githubProxyUri(
        Uri.parse('https://gh-proxy.com/'),
        _latestReleaseApi,
      ),
    ),
    _UpdateSource(
      label: '镜像 gh-proxy.org',
      uri: githubProxyUri(
        Uri.parse('https://gh-proxy.org/'),
        _latestReleaseApi,
      ),
    ),
    _UpdateSource(
      label: '镜像 gh-proxy.cn',
      uri: githubProxyUri(Uri.parse('https://gh-proxy.cn/'), _latestReleaseApi),
    ),
    _UpdateSource(
      label: '镜像 gh.llkk.cc',
      uri: githubProxyUri(Uri.parse('https://gh.llkk.cc/'), _latestReleaseApi),
    ),
    _UpdateSource(
      label: '镜像 ghproxy.homeboyc.cn',
      uri: githubProxyUri(
        Uri.parse('https://ghproxy.homeboyc.cn/'),
        _latestReleaseApi,
      ),
    ),
    _UpdateSource(
      label: '镜像 ghproxy.cfd',
      uri: githubProxyUri(Uri.parse('https://ghproxy.cfd/'), _latestReleaseApi),
    ),
    _UpdateSource(
      label: '镜像 github.chenc.dev',
      uri: githubProxyUri(
        Uri.parse('https://github.chenc.dev/'),
        _latestReleaseApi,
      ),
    ),
    _UpdateSource(
      label: '镜像 hub.gitmirror.com',
      uri: githubProxyUri(
        Uri.parse('https://hub.gitmirror.com/'),
        _latestReleaseApi,
      ),
    ),
  ];
  static final List<_MirrorPrefix> _downloadMirrorPrefixes = [
    _MirrorPrefix('镜像 gh-proxy.com', Uri.parse('https://gh-proxy.com/')),
    _MirrorPrefix('镜像 gh-proxy.org', Uri.parse('https://gh-proxy.org/')),
    _MirrorPrefix('镜像 gh-proxy.cn', Uri.parse('https://gh-proxy.cn/')),
    _MirrorPrefix('镜像 ghproxy.net', Uri.parse('https://ghproxy.net/')),
    _MirrorPrefix('镜像 ghfast.top', Uri.parse('https://ghfast.top/')),
    _MirrorPrefix('镜像 gh.llkk.cc', Uri.parse('https://gh.llkk.cc/')),
    _MirrorPrefix(
      '镜像 ghproxy.homeboyc.cn',
      Uri.parse('https://ghproxy.homeboyc.cn/'),
    ),
    _MirrorPrefix('镜像 ghproxy.cfd', Uri.parse('https://ghproxy.cfd/')),
    _MirrorPrefix(
      '镜像 github.chenc.dev',
      Uri.parse('https://github.chenc.dev/'),
    ),
    _MirrorPrefix(
      '镜像 hub.gitmirror.com',
      Uri.parse('https://hub.gitmirror.com/'),
    ),
  ];
  static const _automaticCheckInterval = Duration(hours: 12);
  static const _androidChannel = MethodChannel(
    'com.applenana.banana_thermal/app_update',
  );

  static const _autoCheckKey = 'app_update_auto_check';
  static const _ignoredVersionKey = 'app_update_ignored_version';
  static const _lastCheckKey = 'app_update_last_check_ms';

  final ValueNotifier<AppUpdateSnapshot> snapshot = ValueNotifier(
    const AppUpdateSnapshot(),
  );
  final ValueNotifier<bool> automaticCheckEnabled = ValueNotifier(true);

  SharedPreferences? _preferences;
  PackageInfo? _packageInfo;
  bool _initialized = false;
  Future<AppUpdateInfo?>? _activeCheck;
  HttpClient? _downloadClient;
  bool _downloadCancelled = false;

  String get currentVersion => _packageInfo?.version ?? '读取中';
  String get currentBuildNumber => _packageInfo?.buildNumber ?? '';

  AppUpdatePlatform get platform => currentUpdatePlatform(
    isWindows: Platform.isWindows,
    isAndroid: Platform.isAndroid,
  );

  Future<void> initialize() async {
    if (_initialized) return;
    final values = await Future.wait<Object>([
      SharedPreferences.getInstance(),
      PackageInfo.fromPlatform(),
    ]);
    _preferences = values[0] as SharedPreferences;
    _packageInfo = values[1] as PackageInfo;
    automaticCheckEnabled.value = _preferences?.getBool(_autoCheckKey) ?? true;
    _initialized = true;
  }

  Future<void> setAutomaticCheckEnabled(bool enabled) async {
    await initialize();
    automaticCheckEnabled.value = enabled;
    await _preferences?.setBool(_autoCheckKey, enabled);
  }

  Future<void> ignoreVersion(String tagName) async {
    await initialize();
    await _preferences?.setString(_ignoredVersionKey, tagName);
    snapshot.value = const AppUpdateSnapshot(
      phase: AppUpdatePhase.idle,
      message: '已忽略此版本，仍可在设置中手动检查',
    );
  }

  Future<void> resetPreferences() async {
    await initialize();
    await _preferences?.remove(_autoCheckKey);
    await _preferences?.remove(_ignoredVersionKey);
    await _preferences?.remove(_lastCheckKey);
    automaticCheckEnabled.value = true;
    snapshot.value = const AppUpdateSnapshot();
  }

  /// 检查 GitHub 最新正式 Release。自动检查会限频并尊重“忽略此版本”，
  /// 手动检查始终访问网络并返回最新结果；失败重试会绕过自动检查限频。
  Future<AppUpdateInfo?> checkForUpdate({
    bool manual = false,
    bool retry = false,
  }) {
    final active = _activeCheck;
    if (active != null) return active;
    final future = _checkForUpdate(manual: manual, retry: retry);
    _activeCheck = future;
    return future.whenComplete(() => _activeCheck = null);
  }

  Future<AppUpdateInfo?> _checkForUpdate({
    required bool manual,
    required bool retry,
  }) async {
    try {
      await initialize();
      if (!manual && !retry && !automaticCheckEnabled.value) return null;

      final now = DateTime.now();
      final lastCheckMs = _preferences?.getInt(_lastCheckKey);
      if (!manual && !retry && lastCheckMs != null) {
        final lastCheck = DateTime.fromMillisecondsSinceEpoch(lastCheckMs);
        if (now.difference(lastCheck) < _automaticCheckInterval) return null;
      }

      snapshot.value = const AppUpdateSnapshot(
        phase: AppUpdatePhase.checking,
        message: '正在连接 GitHub…',
      );
      final fetched = await _fetchLatestRelease();
      final release = fetched.release;

      final installed = AppVersion.tryParse(currentVersion);
      final latest = release.version;
      if (installed == null || latest == null) {
        throw FormatException('无法比较版本：$currentVersion / ${release.tagName}');
      }
      await _preferences?.setInt(_lastCheckKey, now.millisecondsSinceEpoch);
      if (latest.compareTo(installed) <= 0) {
        snapshot.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.upToDate,
          message: '当前已是最新版本（$currentVersion）· ${fetched.sourceLabel}',
        );
        return null;
      }
      if (!manual &&
          _preferences?.getString(_ignoredVersionKey) == release.tagName) {
        snapshot.value = const AppUpdateSnapshot(
          phase: AppUpdatePhase.idle,
          message: '最新版本已被忽略',
        );
        return null;
      }

      final info = AppUpdateInfo(
        currentVersion: currentVersion,
        release: release,
        platform: platform,
        asset: release.assetFor(platform),
        metadataSource: fetched.sourceLabel,
        isSingleMirrorFallback: fetched.isSingleMirrorFallback,
      );
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.updateAvailable,
        info: info,
        message:
            '发现新版本 ${release.tagName} · ${fetched.sourceLabel}'
            '${fetched.isSingleMirrorFallback ? '（未交叉验证）' : ''}',
      );
      return info;
    } catch (error) {
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.error,
        message: '${_friendlyError(error)}；将在 1 分钟后自动重试',
      );
      return null;
    }
  }

  Future<_FetchedRelease> _fetchLatestRelease() async {
    try {
      final release = await _fetchReleaseFrom(
        _UpdateSource(label: '官方 GitHub', uri: _latestReleaseApi),
        timeout: const Duration(seconds: 12),
      );
      return _FetchedRelease(
        release,
        '官方 GitHub',
        isSingleMirrorFallback: false,
      );
    } catch (error) {
      debugPrint('Official GitHub update check failed: $error');
    }

    snapshot.value = const AppUpdateSnapshot(
      phase: AppUpdatePhase.checking,
      message: '官方 GitHub 不可用，正在交叉验证更新镜像…',
    );
    final attempts = await Future.wait(
      _metadataMirrorSources.map(_tryFetchMirrorRelease),
    );
    final responses = <String, AppRelease>{
      for (final attempt in attempts)
        if (attempt.release != null) attempt.source.label: attempt.release!,
    };
    final consensus = selectAppReleaseConsensus(
      responses,
      allowSingleSourceFallback: true,
    );
    if (consensus == null) {
      final details = attempts
          .map(
            (attempt) => attempt.release != null
                ? '${attempt.source.label}=响应不一致'
                : '${attempt.source.label}=${attempt.error}',
          )
          .join('；');
      debugPrint('Update mirror consensus failed: $details');
      if (responses.isEmpty) {
        throw UpdateSourceException(
          '官方源和 ${_metadataMirrorSources.length} 个更新镜像均未返回有效版本信息',
        );
      }
      throw UpdateSourceException(
        '官方源不可用，${responses.length} 个有效镜像响应互相冲突，已拒绝采用',
      );
    }
    final labels = consensus.sourceLabels.join(' + ');
    if (!consensus.isCrossVerified) {
      return _FetchedRelease(
        consensus.release,
        '单一镜像（$labels）',
        isSingleMirrorFallback: true,
      );
    }
    return _FetchedRelease(
      consensus.release,
      '镜像共识（$labels）',
      isSingleMirrorFallback: false,
    );
  }

  Future<_ReleaseAttempt> _tryFetchMirrorRelease(_UpdateSource source) async {
    try {
      return _ReleaseAttempt(
        source: source,
        release: await _fetchReleaseFrom(
          source,
          timeout: const Duration(seconds: 15),
        ),
      );
    } catch (error) {
      debugPrint('${source.label} update check failed: $error');
      return _ReleaseAttempt(source: source, error: _friendlyError(error));
    }
  }

  Future<AppRelease> _fetchReleaseFrom(
    _UpdateSource source, {
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(source.uri);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28')
        ..set(HttpHeaders.userAgentHeader, 'BananaThermalStudio-Updater');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        if (response.statusCode == HttpStatus.forbidden) {
          throw HttpException('${source.label} 请求受限');
        }
        throw HttpException('${source.label} 返回 HTTP ${response.statusCode}');
      }
      const maximumResponseBytes = 2 * 1024 * 1024;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > maximumResponseBytes) {
          throw const FormatException('Release 元数据超过安全大小限制');
        }
        bytes.add(chunk);
      }
      final body = utf8.decode(bytes.takeBytes());
      return AppRelease.fromJsonString(body);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> openReleasePage([AppRelease? release]) async {
    final url = release?.pageUrl ?? releasesPage;
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw const FileSystemException('无法打开系统浏览器');
    }
  }

  /// 下载当前平台资产、校验 GitHub 提供的 SHA-256，然后进入平台安装流程。
  Future<void> downloadAndInstall(AppUpdateInfo info) async {
    final asset = info.asset;
    if (asset == null) {
      await openReleasePage(info.release);
      return;
    }
    try {
      _downloadCancelled = false;
      final file = await _download(info, asset);
      await _launchInstaller(file, info);
    } catch (error) {
      if (_downloadCancelled) {
        snapshot.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.cancelled,
          info: info,
          message: '已取消下载',
        );
        return;
      }
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.error,
        info: info,
        message: _friendlyError(error),
      );
      rethrow;
    }
  }

  void cancelDownload() {
    if (snapshot.value.phase != AppUpdatePhase.downloading) return;
    _downloadCancelled = true;
    _downloadClient?.close(force: true);
  }

  Future<File> _download(AppUpdateInfo info, AppReleaseAsset asset) async {
    if (!asset.canInstallSafely) {
      throw const FormatException('发布资产缺少有效的文件大小或 SHA-256，已拒绝自动安装');
    }
    final directory = await _downloadDirectory(info.release.tagName);
    await directory.create(recursive: true);
    final safeName = p.basename(asset.name);
    if (safeName.isEmpty ||
        safeName == '.' ||
        safeName == '..' ||
        safeName != asset.name) {
      throw const FormatException('更新包文件名无效');
    }
    final destination = File(p.join(directory.path, safeName));
    final partial = File('${destination.path}.part');

    if (await destination.exists()) {
      if (await _digestMatches(destination, asset)) {
        snapshot.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.ready,
          info: info,
          progress: 1,
          message: '更新包已下载并通过 SHA-256 校验',
          downloadedFile: destination,
        );
        return destination;
      }
      await destination.delete();
    }
    if (await partial.exists()) await partial.delete();

    final errors = <String>[];
    for (final source in _downloadSourcesFor(asset.downloadUrl)) {
      if (_downloadCancelled) {
        throw const HttpException('下载已取消');
      }
      if (await partial.exists()) await partial.delete();
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.downloading,
        info: info,
        progress: 0,
        message: '正在通过 ${source.label} 下载 ${asset.name}',
      );
      try {
        await _downloadFromSource(
          info: info,
          asset: asset,
          source: source,
          partial: partial,
        );
        if (_downloadCancelled) {
          throw const HttpException('下载已取消');
        }
        if (!await _digestMatches(partial, asset)) {
          throw FormatException('${source.label} 返回的文件校验失败');
        }
        await partial.rename(destination.path);
        snapshot.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.ready,
          info: info,
          progress: 1,
          message: '已通过 ${source.label} 下载并通过 SHA-256 校验',
          downloadedFile: destination,
        );
        return destination;
      } catch (error) {
        if (await partial.exists()) await partial.delete();
        if (_downloadCancelled) rethrow;
        errors.add('${source.label}：${_friendlyError(error)}');
        debugPrint('${source.label} update download failed: $error');
      }
    }
    throw UpdateDownloadException('所有更新下载源均失败：${errors.join('；')}');
  }

  List<_UpdateSource> _downloadSourcesFor(Uri officialUri) => [
    _UpdateSource(label: '官方 GitHub', uri: officialUri),
    ..._downloadMirrorPrefixes.map(
      (mirror) => _UpdateSource(
        label: mirror.label,
        uri: githubProxyUri(mirror.baseUri, officialUri),
      ),
    ),
  ];

  Future<void> _downloadFromSource({
    required AppUpdateInfo info,
    required AppReleaseAsset asset,
    required _UpdateSource source,
    required File partial,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _downloadClient = client;
    try {
      final request = await client.getUrl(source.uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'BananaThermalStudio-Updater',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('${source.label} 返回 HTTP ${response.statusCode}');
      }
      final expected = response.contentLength > 0
          ? response.contentLength
          : asset.size;
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (_downloadCancelled) {
            throw const HttpException('下载已取消');
          }
          sink.add(chunk);
          received += chunk.length;
          snapshot.value = AppUpdateSnapshot(
            phase: AppUpdatePhase.downloading,
            info: info,
            progress: expected > 0
                ? (received / expected).clamp(0.0, 1.0)
                : null,
            message: '正在通过 ${source.label} 下载 ${asset.name}',
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
    if (Platform.isAndroid) {
      final cache = await getTemporaryDirectory();
      return Directory(p.join(cache.path, 'updates', tagName));
    }
    if (Platform.isWindows) {
      final downloads = await getDownloadsDirectory();
      final base = downloads ?? await getApplicationSupportDirectory();
      return Directory(
        p.join(base.path, 'BananaThermalStudio Updates', tagName),
      );
    }
    return Directory(
      p.join(Directory.systemTemp.path, 'BananaThermalStudio', tagName),
    );
  }

  Future<bool> _digestMatches(File file, AppReleaseAsset asset) async {
    if (!await file.exists()) return false;
    final expected = asset.sha256;
    if (expected == null || asset.size <= 0) return false;
    if (await file.length() != asset.size) return false;
    final actual = (await sha256.bind(file.openRead()).first).toString();
    return actual == expected;
  }

  Future<void> _launchInstaller(File file, AppUpdateInfo info) async {
    if (Platform.isAndroid) {
      final result = await _androidChannel.invokeMethod<String>('installApk', {
        'path': file.path,
      });
      if (result == 'permission_required') {
        snapshot.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.ready,
          info: info,
          progress: 1,
          message: '请在系统设置中允许安装未知应用，返回后再次点击安装',
          downloadedFile: file,
        );
      } else {
        snapshot.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.ready,
          info: info,
          progress: 1,
          message: '已打开 Android 系统安装器',
          downloadedFile: file,
        );
      }
      return;
    }
    if (Platform.isWindows) {
      final extension = p.extension(file.path).toLowerCase();
      if (extension == '.exe') {
        await Process.start(file.path, const []);
      } else if (extension == '.msi') {
        await Process.start('msiexec.exe', ['/i', file.path]);
      } else {
        await Process.start('explorer.exe', ['/select,${file.path}']);
      }
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.ready,
        info: info,
        progress: 1,
        message: extension == '.zip'
            ? '已定位更新包；请退出应用后解压并覆盖旧目录'
            : '已启动 Windows 安装程序',
        downloadedFile: file,
      );
      return;
    }
    await openReleasePage(info.release);
  }

  String _friendlyError(Object error) {
    if (error is SocketException) return '无法连接网络，请检查网络后重试';
    if (error is TimeoutException) return '连接超时，请稍后重试';
    if (error is PlatformException) {
      return error.message?.isNotEmpty == true ? error.message! : '系统无法打开安装器';
    }
    return error.toString().replaceFirst(RegExp(r'^\w+Exception:\s*'), '');
  }
}

class UpdateSourceException implements Exception {
  const UpdateSourceException(this.message);

  final String message;

  @override
  String toString() => 'UpdateSourceException: $message';
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);

  final String message;

  @override
  String toString() => 'UpdateDownloadException: $message';
}

class _UpdateSource {
  const _UpdateSource({required this.label, required this.uri});

  final String label;
  final Uri uri;
}

class _MirrorPrefix {
  const _MirrorPrefix(this.label, this.baseUri);

  final String label;
  final Uri baseUri;
}

class _FetchedRelease {
  const _FetchedRelease(
    this.release,
    this.sourceLabel, {
    required this.isSingleMirrorFallback,
  });

  final AppRelease release;
  final String sourceLabel;
  final bool isSingleMirrorFallback;
}

class _ReleaseAttempt {
  const _ReleaseAttempt({required this.source, this.release, this.error});

  final _UpdateSource source;
  final AppRelease? release;
  final String? error;
}

String formatUpdateFileSize(int bytes) {
  if (bytes <= 0) return '大小未知';
  const mib = 1024 * 1024;
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
  return '${(bytes / 1024).toStringAsFixed(1)} KiB';
}
