import 'dart:convert';

enum AppUpdatePlatform { windows, android, unsupported }

const _repositoryOwner = 'applenana';
const _repositoryName = 'NextBananaThermalStudio';
final _sha256Pattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

/// 将官方 HTTPS 地址拼到 GitHub 代理前缀后。
///
/// 代理地址和目标地址都由应用内常量提供，不接受远端 JSON 注入代理主机。
Uri githubProxyUri(Uri proxyBase, Uri officialUri) {
  if (proxyBase.scheme.toLowerCase() != 'https' ||
      proxyBase.host.isEmpty ||
      proxyBase.hasQuery ||
      proxyBase.hasFragment ||
      officialUri.scheme.toLowerCase() != 'https') {
    throw const FormatException('GitHub 镜像地址必须是 HTTPS');
  }
  final prefix = proxyBase.toString().endsWith('/')
      ? proxyBase.toString()
      : '${proxyBase.toString()}/';
  return Uri.parse('$prefix$officialUri');
}

bool _isExpectedRepositoryPath(Uri uri, String action) {
  final segments = uri.pathSegments;
  return uri.scheme.toLowerCase() == 'https' &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.userInfo.isEmpty &&
      segments.length >= 4 &&
      segments[0].toLowerCase() == _repositoryOwner &&
      segments[1].toLowerCase() == _repositoryName.toLowerCase() &&
      segments[2] == 'releases' &&
      segments[3] == action;
}

bool isBananaThermalReleasePage(Uri uri) =>
    _isExpectedRepositoryPath(uri, 'tag') &&
    uri.pathSegments.length == 5 &&
    uri.pathSegments.last.isNotEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment;

bool isBananaThermalReleaseAssetUrl(Uri uri) =>
    _isExpectedRepositoryPath(uri, 'download') &&
    uri.pathSegments.length == 6 &&
    uri.pathSegments[4].isNotEmpty &&
    uri.pathSegments.last.isNotEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment;

AppUpdatePlatform currentUpdatePlatform({
  required bool isWindows,
  required bool isAndroid,
}) {
  if (isWindows) return AppUpdatePlatform.windows;
  if (isAndroid) return AppUpdatePlatform.android;
  return AppUpdatePlatform.unsupported;
}

/// 宽容解析 GitHub 常用的 `v1.2.3` / `1.2.3+4` 版本格式，并按 SemVer 比较。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.parts, this.preRelease);

  final List<int> parts;
  final List<String> preRelease;

  static AppVersion? tryParse(String source) {
    var value = source.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    value = value.split('+').first;
    final split = value.split('-');
    final core = split.first.split('.');
    if (core.isEmpty || core.length > 4) return null;
    final parts = <int>[];
    for (final segment in core) {
      final number = int.tryParse(segment);
      if (number == null || number < 0) return null;
      parts.add(number);
    }
    final preRelease = split.length <= 1
        ? const <String>[]
        : split.skip(1).join('-').split('.');
    if (preRelease.any((part) => part.isEmpty)) return null;
    return AppVersion(List.unmodifiable(parts), List.unmodifiable(preRelease));
  }

  @override
  int compareTo(AppVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var i = 0; i < length; i++) {
      final left = i < parts.length ? parts[i] : 0;
      final right = i < other.parts.length ? other.parts[i] : 0;
      if (left != right) return left.compareTo(right);
    }
    if (preRelease.isEmpty && other.preRelease.isNotEmpty) return 1;
    if (preRelease.isNotEmpty && other.preRelease.isEmpty) return -1;
    final preLength = preRelease.length > other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < preLength; i++) {
      if (i >= preRelease.length) return -1;
      if (i >= other.preRelease.length) return 1;
      final left = preRelease[i];
      final right = other.preRelease[i];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        if (leftNumber != rightNumber) return leftNumber.compareTo(rightNumber);
      } else if (leftNumber != null) {
        return -1;
      } else if (rightNumber != null) {
        return 1;
      } else {
        final compared = left.compareTo(right);
        if (compared != 0) return compared;
      }
    }
    return 0;
  }
}

class AppReleaseAsset {
  const AppReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.contentType,
    required this.size,
    this.digest,
  });

  final String name;
  final Uri downloadUrl;
  final String contentType;
  final int size;
  final String? digest;

  /// GitHub API 返回的、格式已严格验证的 SHA-256（不含 `sha256:` 前缀）。
  String? get sha256 {
    final match = _sha256Pattern.firstMatch(digest?.trim() ?? '');
    return match?.group(1)?.toLowerCase();
  }

  bool get canInstallSafely => size > 0 && sha256 != null;

  factory AppReleaseAsset.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final url = Uri.tryParse(json['browser_download_url'] as String? ?? '');
    if (name.isEmpty ||
        url == null ||
        !isBananaThermalReleaseAssetUrl(url) ||
        url.pathSegments.last != name) {
      throw const FormatException('Release 资产缺少名称或下载地址');
    }
    return AppReleaseAsset(
      name: name,
      downloadUrl: url,
      contentType: json['content_type'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      digest: json['digest'] as String?,
    );
  }
}

class AppRelease {
  const AppRelease({
    required this.tagName,
    required this.name,
    required this.pageUrl,
    required this.notes,
    required this.publishedAt,
    required this.assets,
  });

  final String tagName;
  final String name;
  final Uri pageUrl;
  final String notes;
  final DateTime? publishedAt;
  final List<AppReleaseAsset> assets;

  AppVersion? get version => AppVersion.tryParse(tagName);

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final tagName = json['tag_name'] as String? ?? '';
    final pageUrl = Uri.tryParse(json['html_url'] as String? ?? '');
    if (AppVersion.tryParse(tagName) == null ||
        pageUrl == null ||
        !isBananaThermalReleasePage(pageUrl) ||
        pageUrl.pathSegments.last != tagName) {
      throw const FormatException('Release 版本或页面地址无效');
    }
    final rawAssets = json['assets'];
    final assets = <AppReleaseAsset>[];
    if (rawAssets is List) {
      for (final value in rawAssets) {
        if (value is! Map) continue;
        try {
          final asset = AppReleaseAsset.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (asset.downloadUrl.pathSegments[4] == tagName) {
            assets.add(asset);
          }
        } on FormatException {
          // 单个损坏资产不应让整个 Release 无法显示。
        }
      }
    }
    return AppRelease(
      tagName: tagName,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : tagName,
      pageUrl: pageUrl,
      notes: json['body'] as String? ?? '',
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      assets: List.unmodifiable(assets),
    );
  }

  static AppRelease fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('Release 响应不是 JSON 对象');
    return AppRelease.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// 镜像共识只比较会影响版本选择和安装包真实性的字段。
  /// Release notes 可以因缓存时间略有差异，不参与安全共识。
  String get verificationIdentity {
    final assetIdentities =
        assets
            .map(
              (asset) => jsonEncode([
                asset.name,
                asset.downloadUrl.toString(),
                asset.size,
                asset.sha256 ?? '',
              ]),
            )
            .toList()
          ..sort();
    return jsonEncode({
      'tag': tagName,
      'page': pageUrl.toString(),
      'assets': assetIdentities,
    });
  }

  bool hasSameVerificationIdentity(AppRelease other) =>
      verificationIdentity == other.verificationIdentity;

  AppReleaseAsset? assetFor(AppUpdatePlatform platform) {
    if (platform == AppUpdatePlatform.unsupported) return null;
    final candidates = assets.where((asset) {
      if (!asset.canInstallSafely) return false;
      final lower = asset.name.toLowerCase();
      return platform == AppUpdatePlatform.android
          ? lower.endsWith('.apk') && lower.contains('bananathermal')
          : lower.contains('bananathermal') &&
                (lower.endsWith('.msix') ||
                    lower.endsWith('.msi') ||
                    lower.endsWith('.exe') ||
                    lower.endsWith('.zip'));
    }).toList();
    if (candidates.isEmpty) return null;

    int score(AppReleaseAsset asset) {
      final name = asset.name.toLowerCase();
      if (platform == AppUpdatePlatform.android) {
        if (name == 'bananathermal-android.apk') return 100;
        if (name.contains('universal')) return 90;
        if (name.contains('arm64-v8a')) return 60;
        return 10;
      }
      if (name == 'bananathermal-windows-x64-setup.exe') return 110;
      if (name.endsWith('.msix')) return 100;
      if (name.endsWith('.msi')) return 90;
      if (name.endsWith('.exe')) return 80;
      if (name == 'bananathermal-windows-x64.zip') return 70;
      if (name.contains('windows') && name.contains('x64')) return 60;
      return 10;
    }

    candidates.sort((left, right) => score(right).compareTo(score(left)));
    return candidates.first;
  }
}

class AppReleaseConsensus {
  const AppReleaseConsensus({
    required this.release,
    required this.sourceLabels,
  });

  final AppRelease release;
  final List<String> sourceLabels;
}

/// 从独立镜像响应中选择达到最小票数、且安全字段完全一致的一组结果。
AppReleaseConsensus? selectAppReleaseConsensus(
  Map<String, AppRelease> responses, {
  int minimumMatches = 2,
}) {
  if (minimumMatches < 1) {
    throw ArgumentError.value(minimumMatches, 'minimumMatches');
  }
  final groups = <String, List<MapEntry<String, AppRelease>>>{};
  for (final response in responses.entries) {
    groups
        .putIfAbsent(response.value.verificationIdentity, () => [])
        .add(response);
  }
  final agreed =
      groups.values.where((group) => group.length >= minimumMatches).toList()
        ..sort((left, right) => right.length.compareTo(left.length));
  if (agreed.isEmpty) return null;
  final winner = agreed.first;
  return AppReleaseConsensus(
    release: winner.first.value,
    sourceLabels: List.unmodifiable(winner.map((entry) => entry.key)),
  );
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.release,
    required this.platform,
    required this.asset,
    required this.metadataSource,
  });

  final String currentVersion;
  final AppRelease release;
  final AppUpdatePlatform platform;
  final AppReleaseAsset? asset;
  final String metadataSource;
}
