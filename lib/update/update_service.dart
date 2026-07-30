import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  /// 手动检查始终访问网络并返回最新结果。
  Future<AppUpdateInfo?> checkForUpdate({bool manual = false}) {
    final active = _activeCheck;
    if (active != null) return active;
    final future = _checkForUpdate(manual: manual);
    _activeCheck = future;
    return future.whenComplete(() => _activeCheck = null);
  }

  Future<AppUpdateInfo?> _checkForUpdate({required bool manual}) async {
    try {
      await initialize();
      if (!manual && !automaticCheckEnabled.value) return null;

      final now = DateTime.now();
      final lastCheckMs = _preferences?.getInt(_lastCheckKey);
      if (!manual && lastCheckMs != null) {
        final lastCheck = DateTime.fromMillisecondsSinceEpoch(lastCheckMs);
        if (now.difference(lastCheck) < _automaticCheckInterval) return null;
      }

      snapshot.value = const AppUpdateSnapshot(
        phase: AppUpdatePhase.checking,
        message: '正在连接 GitHub…',
      );
      final release = await _fetchLatestRelease();
      await _preferences?.setInt(_lastCheckKey, now.millisecondsSinceEpoch);

      final installed = AppVersion.tryParse(currentVersion);
      final latest = release.version;
      if (installed == null || latest == null) {
        throw FormatException('无法比较版本：$currentVersion / ${release.tagName}');
      }
      if (latest.compareTo(installed) <= 0) {
        snapshot.value = AppUpdateSnapshot(
          phase: AppUpdatePhase.upToDate,
          message: '当前已是最新版本（$currentVersion）',
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
      );
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.updateAvailable,
        info: info,
        message: '发现新版本 ${release.tagName}',
      );
      return info;
    } catch (error) {
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.error,
        message: _friendlyError(error),
      );
      return null;
    }
  }

  Future<AppRelease> _fetchLatestRelease() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(_latestReleaseApi);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28')
        ..set(HttpHeaders.userAgentHeader, 'BananaThermalStudio-Updater');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        if (response.statusCode == HttpStatus.forbidden) {
          throw const HttpException('GitHub 请求受限，请稍后再试');
        }
        throw HttpException('GitHub 返回 HTTP ${response.statusCode}');
      }
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
    final directory = await _downloadDirectory(info.release.tagName);
    await directory.create(recursive: true);
    final safeName = p.basename(Uri.parse(asset.downloadUrl.toString()).path);
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      throw const FormatException('更新包文件名无效');
    }
    final destination = File(p.join(directory.path, safeName));
    final partial = File('${destination.path}.part');

    if (await destination.exists() &&
        await _digestMatches(destination, asset)) {
      snapshot.value = AppUpdateSnapshot(
        phase: AppUpdatePhase.ready,
        info: info,
        progress: 1,
        message: '更新包已下载并通过校验',
        downloadedFile: destination,
      );
      return destination;
    }
    if (await partial.exists()) await partial.delete();

    snapshot.value = AppUpdateSnapshot(
      phase: AppUpdatePhase.downloading,
      info: info,
      progress: 0,
      message: '正在下载 ${asset.name}',
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _downloadClient = client;
    try {
      final request = await client.getUrl(asset.downloadUrl);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'BananaThermalStudio-Updater',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('下载失败：HTTP ${response.statusCode}');
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
            message: '正在下载 ${asset.name}',
          );
        }
      } finally {
        await sink.close();
      }
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      client.close(force: true);
      if (identical(_downloadClient, client)) _downloadClient = null;
    }

    if (_downloadCancelled) {
      if (await partial.exists()) await partial.delete();
      throw const HttpException('下载已取消');
    }
    if (!await _digestMatches(partial, asset)) {
      if (await partial.exists()) await partial.delete();
      throw const FormatException('更新包 SHA-256 校验失败，请重新下载');
    }
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
    snapshot.value = AppUpdateSnapshot(
      phase: AppUpdatePhase.ready,
      info: info,
      progress: 1,
      message: '更新包已下载并通过校验',
      downloadedFile: destination,
    );
    return destination;
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
    if (asset.size > 0 && await file.length() != asset.size) return false;
    final digest = asset.digest;
    if (digest == null || !digest.toLowerCase().startsWith('sha256:')) {
      return true;
    }
    final expected = digest.substring(digest.indexOf(':') + 1).toLowerCase();
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

String formatUpdateFileSize(int bytes) {
  if (bytes <= 0) return '大小未知';
  const mib = 1024 * 1024;
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
  return '${(bytes / 1024).toStringAsFixed(1)} KiB';
}
