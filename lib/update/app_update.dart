import 'dart:convert';

enum AppUpdatePlatform { windows, android, unsupported }

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

  factory AppReleaseAsset.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final url = Uri.tryParse(json['browser_download_url'] as String? ?? '');
    if (name.isEmpty || url == null || url.scheme.toLowerCase() != 'https') {
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
        pageUrl.scheme.toLowerCase() != 'https') {
      throw const FormatException('Release 版本或页面地址无效');
    }
    final rawAssets = json['assets'];
    final assets = <AppReleaseAsset>[];
    if (rawAssets is List) {
      for (final value in rawAssets) {
        if (value is! Map) continue;
        try {
          assets.add(
            AppReleaseAsset.fromJson(Map<String, dynamic>.from(value)),
          );
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

  AppReleaseAsset? assetFor(AppUpdatePlatform platform) {
    if (platform == AppUpdatePlatform.unsupported) return null;
    final candidates = assets.where((asset) {
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

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.release,
    required this.platform,
    required this.asset,
  });

  final String currentVersion;
  final AppRelease release;
  final AppUpdatePlatform platform;
  final AppReleaseAsset? asset;
}
