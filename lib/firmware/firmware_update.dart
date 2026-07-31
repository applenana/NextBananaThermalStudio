import 'dart:convert';

import '../update/app_update.dart' show AppVersion;

const firmwareRepositoryOwner = 'applenana';
const firmwareRepositoryName = 'BananaThermalFirmware';
const bananaDualLightModel = 'HEIMAN-NSP';

final _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
final _assetDigestPattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');
final _legacyIdentityPattern = RegExp(
  r'^(HEIMAN-NSP)-(v\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)-(32)$',
  caseSensitive: false,
);

enum FirmwareDeviceFamily { bananaDualLight, unsupported }

enum FirmwareVariant {
  flash8MbPerformance(
    environment: 'sketch3m_fs5m',
    label: '8 MB 性能版（300 MHz）',
    flashBytes: 8 * 1024 * 1024,
  ),
  flash8MbStable(
    environment: 'sketch3m_fs5m_stable',
    label: '8 MB 稳定版（220 MHz）',
    flashBytes: 8 * 1024 * 1024,
  ),
  flash2Mb(
    environment: 'sketch1m_fs1m',
    label: '2 MB 兼容版',
    flashBytes: 2 * 1024 * 1024,
  );

  const FirmwareVariant({
    required this.environment,
    required this.label,
    required this.flashBytes,
  });

  final String environment;
  final String label;
  final int flashBytes;

  static FirmwareVariant? fromEnvironment(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    for (final variant in values) {
      if (variant.environment == normalized) return variant;
    }
    return null;
  }
}

/// 从 GetSysInfo 建立的设备身份。
///
/// 只有明确匹配已知设备族的设备才允许自动刷写。热流协议兼容、串口 VID/PID
/// 或“能响应 GetSysInfo”都不能单独证明固件兼容。
class FirmwareDeviceIdentity {
  const FirmwareDeviceIdentity({
    required this.family,
    required this.model,
    required this.currentVersion,
    required this.serialNumber,
    required this.reportedVariant,
    required this.reason,
  });

  final FirmwareDeviceFamily family;
  final String? model;
  final String? currentVersion;
  final String? serialNumber;
  final FirmwareVariant? reportedVariant;
  final String reason;

  bool get canFlash => family == FirmwareDeviceFamily.bananaDualLight;

  String get deviceKey {
    final serial = serialNumber?.trim();
    return serial == null || serial.isEmpty
        ? '${model ?? 'unknown'}:anonymous'
        : '${model ?? 'unknown'}:$serial';
  }

  static FirmwareDeviceIdentity fromDeviceInfo(Map<String, dynamic>? info) {
    if (info == null) {
      return const FirmwareDeviceIdentity(
        family: FirmwareDeviceFamily.unsupported,
        model: null,
        currentVersion: null,
        serialNumber: null,
        reportedVariant: null,
        reason: '设备尚未返回 GetSysInfo，不能确认固件兼容性',
      );
    }

    String? firstString(Iterable<String> keys) {
      for (final key in keys) {
        final value = info[key]?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }

    final composite = firstString(const ['version', 'Version']);
    final compositeMatch = _legacyIdentityPattern.firstMatch(composite ?? '');
    final compositeModel = compositeMatch?.group(1)?.toUpperCase();
    final compositeVersion = compositeMatch?.group(2);
    final compositeSensorClass = compositeMatch?.group(3);

    final explicitModel = firstString(const [
      'deviceModel',
      'DeviceModel',
      'machineModel',
      'MachineModel',
      'model',
      'Model',
    ])?.toUpperCase();
    final model = explicitModel ?? compositeModel;
    final explicitSensorClass = firstString(const [
      'sensorClass',
      'SensorClass',
    ]);
    final sensorClass = explicitSensorClass ?? compositeSensorClass;
    final versionCandidate =
        firstString(const ['firmwareVersion', 'FirmwareVersion']) ??
        compositeVersion;
    final currentVersion = AppVersion.tryParse(versionCandidate ?? '') == null
        ? null
        : versionCandidate;

    FirmwareVariant? reportedVariant = FirmwareVariant.fromEnvironment(
      firstString(const [
        'firmwareVariant',
        'FirmwareVariant',
        'platformioEnvironment',
      ]),
    );
    reportedVariant ??= _variantFromFlashSize(
      info['flashSizeBytes'] ?? info['FlashSizeBytes'] ?? info['flashSizeMb'],
    );

    final serial = firstString(const ['SerialNum', 'Serial']);
    if (explicitModel != null &&
        compositeModel != null &&
        explicitModel != compositeModel) {
      return FirmwareDeviceIdentity(
        family: FirmwareDeviceFamily.unsupported,
        model: explicitModel,
        currentVersion: currentVersion,
        serialNumber: serial,
        reportedVariant: reportedVariant,
        reason: '设备上报的型号字段互相冲突，已拒绝自动刷写',
      );
    }
    if (model != bananaDualLightModel ||
        (sensorClass != null && sensorClass != '32')) {
      return FirmwareDeviceIdentity(
        family: FirmwareDeviceFamily.unsupported,
        model: model,
        currentVersion: currentVersion,
        serialNumber: serial,
        reportedVariant: reportedVariant,
        reason: model == null
            ? '无法确认设备型号；当前固件源只支持 3.2 寸双光热成像'
            : '型号 $model 不属于当前固件源，已禁止自动刷写',
      );
    }

    return FirmwareDeviceIdentity(
      family: FirmwareDeviceFamily.bananaDualLight,
      model: model,
      currentVersion: currentVersion,
      serialNumber: serial,
      reportedVariant: reportedVariant,
      reason: currentVersion == null
          ? '已识别 3.2 寸双光设备，但当前固件没有可比较的版本号'
          : '已识别 3.2 寸双光热成像',
    );
  }

  static FirmwareVariant? _variantFromFlashSize(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim().toLowerCase();
    final number = num.tryParse(text.replaceAll(RegExp(r'[^0-9.]'), ''));
    if (number == null) return null;
    final bytes = text.contains('mb') || number <= 16
        ? (number * 1024 * 1024).round()
        : number.round();
    if (bytes >= 7 * 1024 * 1024) {
      return FirmwareVariant.flash8MbPerformance;
    }
    if (bytes >= 2 * 1024 * 1024 && bytes < 3 * 1024 * 1024) {
      return FirmwareVariant.flash2Mb;
    }
    return null;
  }
}

class FirmwareReleaseAsset {
  const FirmwareReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.digest,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String? digest;

  String? get sha256 {
    final match = _assetDigestPattern.firstMatch(digest?.trim() ?? '');
    return match?.group(1)?.toLowerCase();
  }

  bool get hasGitHubDigest => size > 0 && sha256 != null;

  factory FirmwareReleaseAsset.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final uri = Uri.tryParse(json['browser_download_url'] as String? ?? '');
    if (name.isEmpty ||
        uri == null ||
        !_isFirmwareAssetUrl(uri) ||
        uri.pathSegments.last != name) {
      throw const FormatException('固件 Release 资产地址无效');
    }
    return FirmwareReleaseAsset(
      name: name,
      downloadUrl: uri,
      size: (json['size'] as num?)?.toInt() ?? 0,
      digest: json['digest'] as String?,
    );
  }
}

class FirmwareRelease {
  const FirmwareRelease({
    required this.tagName,
    required this.name,
    required this.pageUrl,
    required this.notes,
    required this.publishedAt,
    required this.assets,
    required this.prerelease,
  });

  final String tagName;
  final String name;
  final Uri pageUrl;
  final String notes;
  final DateTime? publishedAt;
  final List<FirmwareReleaseAsset> assets;
  final bool prerelease;

  AppVersion get version => AppVersion.tryParse(tagName)!;

  FirmwareReleaseAsset? assetNamed(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  FirmwareReleaseAsset? assetFor(FirmwareVariant variant) =>
      assetNamed('banana-thermal-$tagName-${variant.environment}.uf2');

  String get verificationIdentity {
    final assetIdentity =
        assets
            .map(
              (asset) => [
                asset.name,
                asset.downloadUrl.toString(),
                asset.size.toString(),
                asset.sha256 ?? '',
              ],
            )
            .toList()
          ..sort((a, b) => a.first.compareTo(b.first));
    return jsonEncode({'tag': tagName, 'assets': assetIdentity});
  }

  factory FirmwareRelease.fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String? ?? '';
    final pageUrl = Uri.tryParse(json['html_url'] as String? ?? '');
    if (AppVersion.tryParse(tag) == null ||
        pageUrl == null ||
        !_isFirmwareReleasePage(pageUrl) ||
        pageUrl.pathSegments.last != tag) {
      throw const FormatException('固件 Release 版本或页面地址无效');
    }
    final assets = <FirmwareReleaseAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        if (raw is! Map) continue;
        try {
          final asset = FirmwareReleaseAsset.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (asset.downloadUrl.pathSegments[4] == tag) assets.add(asset);
        } on FormatException {
          // 一个无效附件不能污染其余安全附件，但该附件不会参与自动烧录。
        }
      }
    }
    return FirmwareRelease(
      tagName: tag,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : tag,
      pageUrl: pageUrl,
      notes: json['body'] as String? ?? '',
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      assets: List.unmodifiable(assets),
      prerelease: json['prerelease'] == true,
    );
  }
}

List<FirmwareRelease> parseFirmwareReleaseList(
  String source, {
  bool includePrereleases = false,
}) {
  final decoded = jsonDecode(source);
  if (decoded is! List) throw const FormatException('固件版本响应不是 JSON 数组');
  final releases = <FirmwareRelease>[];
  for (final raw in decoded) {
    if (raw is! Map || raw['draft'] == true) continue;
    try {
      final release = FirmwareRelease.fromJson(Map<String, dynamic>.from(raw));
      if (!includePrereleases && release.prerelease) continue;
      if (release.assetNamed('manifest.json') == null) continue;
      releases.add(release);
    } on FormatException {
      // 忽略单条损坏或不属于官方仓库的发布。
    }
  }
  releases.sort((a, b) => b.version.compareTo(a.version));
  return List.unmodifiable(releases);
}

class FirmwareArtifact {
  const FirmwareArtifact({
    required this.file,
    required this.size,
    required this.sha256,
    required this.environment,
  });

  final String file;
  final int size;
  final String sha256;
  final String environment;
}

class FirmwareManifest {
  const FirmwareManifest({required this.tagName, required this.artifacts});

  final String tagName;
  final List<FirmwareArtifact> artifacts;

  FirmwareArtifact artifactFor(FirmwareVariant variant) => artifacts.firstWhere(
    (artifact) => artifact.environment == variant.environment,
  );

  factory FirmwareManifest.fromJsonString(
    String source, {
    required String expectedTag,
  }) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('manifest 不是 JSON 对象');
    final json = Map<String, dynamic>.from(decoded);
    if (json['schema_version'] != 1 || json['firmware_tag'] != expectedTag) {
      throw const FormatException('manifest schema 或版本不匹配');
    }
    final builder = json['builder'];
    if (builder is! Map ||
        builder['workflow_repository'] !=
            '$firmwareRepositoryOwner/$firmwareRepositoryName') {
      throw const FormatException('manifest 构建仓库不匹配');
    }
    final rawArtifacts = json['artifacts'];
    if (rawArtifacts is! List) throw const FormatException('manifest 缺少固件附件');
    final artifacts = <FirmwareArtifact>[];
    for (final raw in rawArtifacts) {
      if (raw is! Map) throw const FormatException('manifest 附件格式无效');
      final file = raw['file']?.toString() ?? '';
      final environment = raw['platformio_environment']?.toString() ?? '';
      final size = (raw['size'] as num?)?.toInt() ?? 0;
      final digest = raw['sha256']?.toString().toLowerCase() ?? '';
      if (file.isEmpty ||
          file.contains('/') ||
          file.contains('\\') ||
          size <= 0 ||
          !_sha256Pattern.hasMatch(digest) ||
          environment.isEmpty) {
        throw const FormatException('manifest 固件附件字段无效');
      }
      artifacts.add(
        FirmwareArtifact(
          file: file,
          size: size,
          sha256: digest,
          environment: environment,
        ),
      );
    }

    final expectedEnvironments = FirmwareVariant.values
        .map((variant) => variant.environment)
        .toSet();
    final actualEnvironments = artifacts.map((a) => a.environment).toSet();
    if (artifacts.length != expectedEnvironments.length ||
        actualEnvironments.length != artifacts.length ||
        !actualEnvironments.containsAll(expectedEnvironments)) {
      throw const FormatException('manifest 固件变体集合与当前设备族不匹配');
    }
    for (final artifact in artifacts) {
      final expectedFile =
          'banana-thermal-$expectedTag-${artifact.environment}.uf2';
      if (artifact.file != expectedFile) {
        throw FormatException('manifest 固件文件名不匹配：${artifact.file}');
      }
    }
    return FirmwareManifest(
      tagName: expectedTag,
      artifacts: List.unmodifiable(artifacts),
    );
  }
}

FirmwareRelease? findNewerFirmware(
  FirmwareDeviceIdentity identity,
  List<FirmwareRelease> releases,
) {
  if (!identity.canFlash || identity.currentVersion == null) return null;
  final current = AppVersion.tryParse(identity.currentVersion!);
  if (current == null) return null;
  for (final release in releases) {
    if (release.version.compareTo(current) > 0) return release;
  }
  return null;
}

bool _isFirmwareReleasePage(Uri uri) {
  final segments = uri.pathSegments;
  return uri.scheme.toLowerCase() == 'https' &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      segments.length == 5 &&
      segments[0].toLowerCase() == firmwareRepositoryOwner &&
      segments[1].toLowerCase() == firmwareRepositoryName.toLowerCase() &&
      segments[2] == 'releases' &&
      segments[3] == 'tag' &&
      segments[4].isNotEmpty;
}

bool _isFirmwareAssetUrl(Uri uri) {
  final segments = uri.pathSegments;
  return uri.scheme.toLowerCase() == 'https' &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      segments.length == 6 &&
      segments[0].toLowerCase() == firmwareRepositoryOwner &&
      segments[1].toLowerCase() == firmwareRepositoryName.toLowerCase() &&
      segments[2] == 'releases' &&
      segments[3] == 'download' &&
      segments[4].isNotEmpty &&
      segments[5].isNotEmpty;
}
