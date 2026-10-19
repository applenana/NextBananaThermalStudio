import 'dart:convert';

import '../update/app_update.dart' show AppVersion;

const firmwareRepositoryOwner = 'applenana';
const firmwareRepositoryName = 'BananaThermalFirmware';
const bananaDualLightModel = 'HEIMAN-NSP';
const bananaStandardModel = 'HEIMAN-NSP-STANDARD';

final _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
final _assetDigestPattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');
final _unifiedIdentityPattern = RegExp(
  r'^(HEIMAN-NSP(?:-STANDARD)?)-(v\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)-(32)$',
  caseSensitive: false,
);
final _standardMigrationIdentityPattern = RegExp(
  r'^(HEIMAN)-(v\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)-(3inch2|2in4&8)$',
  caseSensitive: false,
);
final _unifiedFirmwareCutover = AppVersion.tryParse('v1.8.0')!;

enum FirmwareDeviceFamily { bananaThermal, unsupported }

enum FirmwareHardwareProfile { dual, standard }

enum FirmwareVariant {
  flash8MbPerformance(
    environment: 'dual_sketch3m_fs5m',
    label: '双光 · 8 MB 性能版（300 MHz）',
    profile: FirmwareHardwareProfile.dual,
    flashBytes: 8 * 1024 * 1024,
    filesystemBytes: 5 * 1024 * 1024,
    cpuHz: 300000000,
    stabilityProfile: 'performance',
    historicalEnvironment: 'sketch3m_fs5m',
  ),
  flash8MbStable(
    environment: 'dual_sketch3m_fs5m_stable',
    label: '双光 · 8 MB 稳定版（220 MHz）',
    profile: FirmwareHardwareProfile.dual,
    flashBytes: 8 * 1024 * 1024,
    filesystemBytes: 5 * 1024 * 1024,
    cpuHz: 220000000,
    stabilityProfile: 'stable',
    historicalEnvironment: 'sketch3m_fs5m_stable',
  ),
  flash2Mb(
    environment: 'dual_sketch1m_fs1m',
    label: '双光 · 2 MB 兼容版（300 MHz）',
    profile: FirmwareHardwareProfile.dual,
    flashBytes: 2 * 1024 * 1024,
    filesystemBytes: 1 * 1024 * 1024,
    cpuHz: 300000000,
    stabilityProfile: 'performance',
    historicalEnvironment: 'sketch1m_fs1m',
  ),
  standardFlash8MbPerformance(
    environment: 'standard_sketch3m_fs5m',
    label: '普通热成像 · 8 MB 性能版（300 MHz）',
    profile: FirmwareHardwareProfile.standard,
    flashBytes: 8 * 1024 * 1024,
    filesystemBytes: 5 * 1024 * 1024,
    cpuHz: 300000000,
    stabilityProfile: 'performance',
  ),
  standardFlash8MbStable(
    environment: 'standard_sketch3m_fs5m_stable',
    label: '普通热成像 · 8 MB 稳定版（220 MHz）',
    profile: FirmwareHardwareProfile.standard,
    flashBytes: 8 * 1024 * 1024,
    filesystemBytes: 5 * 1024 * 1024,
    cpuHz: 220000000,
    stabilityProfile: 'stable',
  ),
  standardFlash2Mb(
    environment: 'standard_sketch1m_fs1m',
    label: '普通热成像 · 2 MB 兼容版（300 MHz）',
    profile: FirmwareHardwareProfile.standard,
    flashBytes: 2 * 1024 * 1024,
    filesystemBytes: 1 * 1024 * 1024,
    cpuHz: 300000000,
    stabilityProfile: 'performance',
  );

  const FirmwareVariant({
    required this.environment,
    required this.label,
    required this.profile,
    required this.flashBytes,
    required this.filesystemBytes,
    required this.cpuHz,
    required this.stabilityProfile,
    this.historicalEnvironment,
  });

  final String environment;
  final String label;
  final FirmwareHardwareProfile profile;
  final int flashBytes;
  final int filesystemBytes;
  final int cpuHz;
  final String stabilityProfile;
  final String? historicalEnvironment;

  static FirmwareVariant? fromEnvironment(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    for (final variant in values) {
      if (variant.environment == normalized ||
          variant.historicalEnvironment == normalized) {
        return variant;
      }
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
    required this.hardwareProfile,
    required this.model,
    required this.currentVersion,
    required this.serialNumber,
    required this.reportedVariant,
    required this.requiresProductMigration,
    required this.migrationFlashBytes,
    required this.reason,
  });

  final FirmwareDeviceFamily family;
  final FirmwareHardwareProfile? hardwareProfile;
  final String? model;
  final String? currentVersion;
  final String? serialNumber;
  final FirmwareVariant? reportedVariant;
  final bool requiresProductMigration;
  final int? migrationFlashBytes;
  final String reason;

  bool get canFlash => family == FirmwareDeviceFamily.bananaThermal;

  String get productName => switch (hardwareProfile) {
    FirmwareHardwareProfile.dual => '双光热成像',
    FirmwareHardwareProfile.standard => '普通热成像',
    null => '未知热成像',
  };

  String get deviceKey {
    final serial = serialNumber?.trim();
    final profile = hardwareProfile?.name ?? 'unknown';
    return serial == null || serial.isEmpty
        ? '$profile:${model ?? 'unknown'}:anonymous'
        : '$profile:${model ?? 'unknown'}:$serial';
  }

  static FirmwareDeviceIdentity fromDeviceInfo(Map<String, dynamic>? info) {
    if (info == null) {
      return const FirmwareDeviceIdentity(
        family: FirmwareDeviceFamily.unsupported,
        hardwareProfile: null,
        model: null,
        currentVersion: null,
        serialNumber: null,
        reportedVariant: null,
        requiresProductMigration: false,
        migrationFlashBytes: null,
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
    final unifiedMatch = _unifiedIdentityPattern.firstMatch(composite ?? '');
    final migrationMatch = _standardMigrationIdentityPattern.firstMatch(
      composite ?? '',
    );
    final compositeModel = unifiedMatch?.group(1)?.toUpperCase();
    final compositeVersion = unifiedMatch?.group(2) ?? migrationMatch?.group(2);
    final compositeSensorClass = unifiedMatch?.group(3);
    final migrationKind = migrationMatch?.group(3)?.toLowerCase();
    final requiresMigration = migrationMatch != null;

    final explicitModel = firstString(const [
      'deviceModel',
      'DeviceModel',
      'machineModel',
      'MachineModel',
      'model',
      'Model',
    ])?.toUpperCase();
    final model = explicitModel ?? compositeModel ?? migrationMatch?.group(1);
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
    final explicitProfile = firstString(const [
      'hardwareProfile',
      'HardwareProfile',
    ])?.toLowerCase();
    FirmwareHardwareProfile? hardwareProfile;
    if (requiresMigration || model == bananaStandardModel) {
      hardwareProfile = FirmwareHardwareProfile.standard;
    } else if (model == bananaDualLightModel) {
      hardwareProfile = FirmwareHardwareProfile.dual;
    }
    if (explicitProfile == 'dual') {
      hardwareProfile = FirmwareHardwareProfile.dual;
    } else if (explicitProfile == 'standard') {
      hardwareProfile = FirmwareHardwareProfile.standard;
    }

    FirmwareVariant? reportedVariant = FirmwareVariant.fromEnvironment(
      firstString(const [
        'firmwareVariant',
        'FirmwareVariant',
        'platformioEnvironment',
      ]),
    );
    final rawFlashSize =
        info['flashSizeBytes'] ?? info['FlashSizeBytes'] ?? info['flashSizeMb'];
    final flashVariant = _variantFromFlashSize(rawFlashSize, hardwareProfile);
    final flashFieldsConflict =
        reportedVariant != null &&
        flashVariant != null &&
        reportedVariant.flashBytes != flashVariant.flashBytes;
    reportedVariant ??= flashVariant;
    final rawCpuHz = num.tryParse(
      (info['cpuFrequencyHz'] ?? info['CpuFrequencyHz'] ?? '').toString(),
    )?.toInt();
    final cpuFieldsConflict =
        reportedVariant != null &&
        rawCpuHz != null &&
        reportedVariant.cpuHz != rawCpuHz;

    final serial = firstString(const ['SerialNum', 'Serial']);
    if (explicitModel != null &&
        compositeModel != null &&
        explicitModel != compositeModel) {
      return FirmwareDeviceIdentity(
        family: FirmwareDeviceFamily.unsupported,
        hardwareProfile: hardwareProfile,
        model: explicitModel,
        currentVersion: currentVersion,
        serialNumber: serial,
        reportedVariant: reportedVariant,
        requiresProductMigration: requiresMigration,
        migrationFlashBytes: null,
        reason: '设备上报的型号字段互相冲突，已拒绝自动刷写',
      );
    }
    final expectedModel = hardwareProfile == FirmwareHardwareProfile.standard
        ? bananaStandardModel
        : bananaDualLightModel;
    final profileConflicts =
        (explicitProfile != null &&
            explicitProfile != 'dual' &&
            explicitProfile != 'standard') ||
        (reportedVariant != null &&
            reportedVariant.profile != hardwareProfile) ||
        flashFieldsConflict ||
        cpuFieldsConflict;
    if (hardwareProfile == null ||
        profileConflicts ||
        (!requiresMigration && model != expectedModel) ||
        (sensorClass != null && sensorClass != '32')) {
      return FirmwareDeviceIdentity(
        family: FirmwareDeviceFamily.unsupported,
        hardwareProfile: hardwareProfile,
        model: model,
        currentVersion: currentVersion,
        serialNumber: serial,
        reportedVariant: reportedVariant,
        requiresProductMigration: requiresMigration,
        migrationFlashBytes: null,
        reason: model == null
            ? '无法确认设备型号和硬件板型'
            : '设备身份字段冲突或型号 $model 不属于当前固件源，已禁止自动刷写',
      );
    }

    final migrationFlashBytes = migrationKind == '3inch2'
        ? 8 * 1024 * 1024
        : migrationKind == '2in4&8'
        ? 2 * 1024 * 1024
        : null;
    if (requiresMigration) {
      reportedVariant = migrationFlashBytes == 8 * 1024 * 1024
          ? FirmwareVariant.standardFlash8MbPerformance
          : FirmwareVariant.standardFlash2Mb;
    }

    return FirmwareDeviceIdentity(
      family: FirmwareDeviceFamily.bananaThermal,
      hardwareProfile: hardwareProfile,
      model: requiresMigration ? bananaStandardModel : model,
      currentVersion: currentVersion,
      serialNumber: serial,
      reportedVariant: reportedVariant,
      requiresProductMigration: requiresMigration,
      migrationFlashBytes: migrationFlashBytes,
      reason: requiresMigration
          ? '已识别旧普通热成像，需要迁移到统一固件'
          : currentVersion == null
          ? '已识别 ${hardwareProfile.name} 设备，但当前固件没有可比较的版本号'
          : hardwareProfile == FirmwareHardwareProfile.dual
          ? '已识别双光热成像'
          : '已识别普通热成像',
    );
  }

  static FirmwareVariant? _variantFromFlashSize(
    Object? raw,
    FirmwareHardwareProfile? profile,
  ) {
    if (raw == null || profile == null) return null;
    final text = raw.toString().trim().toLowerCase();
    final number = num.tryParse(text.replaceAll(RegExp(r'[^0-9.]'), ''));
    if (number == null) return null;
    final bytes = text.contains('mb') || number <= 16
        ? (number * 1024 * 1024).round()
        : number.round();
    if (bytes >= 7 * 1024 * 1024) {
      return profile == FirmwareHardwareProfile.dual
          ? FirmwareVariant.flash8MbPerformance
          : FirmwareVariant.standardFlash8MbPerformance;
    }
    if (bytes >= 2 * 1024 * 1024 && bytes < 3 * 1024 * 1024) {
      return profile == FirmwareHardwareProfile.dual
          ? FirmwareVariant.flash2Mb
          : FirmwareVariant.standardFlash2Mb;
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

  FirmwareReleaseAsset? assetFor(FirmwareVariant variant) {
    final environment = version.compareTo(_unifiedFirmwareCutover) < 0
        ? variant.historicalEnvironment
        : variant.environment;
    if (environment == null) return null;
    return assetNamed('banana-thermal-$tagName-$environment.uf2');
  }

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
    required this.hardwareProfile,
    required this.flashBytes,
    required this.filesystemBytes,
    required this.cpuHz,
    required this.stabilityProfile,
  });

  final String file;
  final int size;
  final String sha256;
  final String environment;
  final FirmwareHardwareProfile? hardwareProfile;
  final int? flashBytes;
  final int? filesystemBytes;
  final int? cpuHz;
  final String? stabilityProfile;
}

class FirmwareManifest {
  const FirmwareManifest({
    required this.schemaVersion,
    required this.tagName,
    required this.artifacts,
  });

  final int schemaVersion;
  final String tagName;
  final List<FirmwareArtifact> artifacts;

  FirmwareArtifact artifactFor(FirmwareVariant variant) {
    final environment = schemaVersion == 1
        ? variant.historicalEnvironment
        : variant.environment;
    if (environment == null) {
      throw StateError('当前历史 manifest 不包含 ${variant.label}');
    }
    return artifacts.firstWhere(
      (artifact) => artifact.environment == environment,
    );
  }

  factory FirmwareManifest.fromJsonString(
    String source, {
    required String expectedTag,
  }) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('manifest 不是 JSON 对象');
    final json = Map<String, dynamic>.from(decoded);
    final schemaVersion = (json['schema_version'] as num?)?.toInt();
    final expectedVersion = AppVersion.tryParse(expectedTag);
    final expectedSchema =
        expectedVersion != null &&
            expectedVersion.compareTo(_unifiedFirmwareCutover) >= 0
        ? 2
        : 1;
    if (schemaVersion != expectedSchema ||
        json['firmware_tag'] != expectedTag) {
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
      final profileText = raw['hardware_profile']?.toString().toLowerCase();
      final profile = profileText == 'dual'
          ? FirmwareHardwareProfile.dual
          : profileText == 'standard'
          ? FirmwareHardwareProfile.standard
          : null;
      final flashBytes = (raw['flash_bytes'] as num?)?.toInt();
      final filesystemBytes = (raw['filesystem_bytes'] as num?)?.toInt();
      final cpuHz = (raw['cpu_hz'] as num?)?.toInt();
      final stabilityProfile = raw['stability_profile']?.toString();
      if (file.isEmpty ||
          file.contains('/') ||
          file.contains('\\') ||
          size <= 0 ||
          !_sha256Pattern.hasMatch(digest) ||
          environment.isEmpty) {
        throw const FormatException('manifest 固件附件字段无效');
      }
      if (schemaVersion == 2 &&
          (profile == null ||
              flashBytes == null ||
              filesystemBytes == null ||
              cpuHz == null ||
              stabilityProfile == null)) {
        throw const FormatException('schema v2 固件附件缺少板型元数据');
      }
      artifacts.add(
        FirmwareArtifact(
          file: file,
          size: size,
          sha256: digest,
          environment: environment,
          hardwareProfile: profile,
          flashBytes: flashBytes,
          filesystemBytes: filesystemBytes,
          cpuHz: cpuHz,
          stabilityProfile: stabilityProfile,
        ),
      );
    }

    final variants = schemaVersion == 1
        ? FirmwareVariant.values
              .where((variant) => variant.historicalEnvironment != null)
              .toList()
        : FirmwareVariant.values;
    final expectedEnvironments = variants
        .map(
          (variant) => schemaVersion == 1
              ? variant.historicalEnvironment!
              : variant.environment,
        )
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
      if (schemaVersion == 2) {
        final variant = FirmwareVariant.fromEnvironment(artifact.environment);
        if (variant == null ||
            artifact.hardwareProfile != variant.profile ||
            artifact.flashBytes != variant.flashBytes ||
            artifact.filesystemBytes != variant.filesystemBytes ||
            artifact.cpuHz != variant.cpuHz ||
            artifact.stabilityProfile != variant.stabilityProfile) {
          throw FormatException('manifest 固件元数据冲突：${artifact.environment}');
        }
      }
    }
    return FirmwareManifest(
      schemaVersion: schemaVersion!,
      tagName: expectedTag,
      artifacts: List.unmodifiable(artifacts),
    );
  }
}

FirmwareRelease? findNewerFirmware(
  FirmwareDeviceIdentity identity,
  List<FirmwareRelease> releases,
) {
  if (!identity.canFlash) return null;
  if (identity.requiresProductMigration) {
    for (final release in releases) {
      if (release.version.compareTo(_unifiedFirmwareCutover) >= 0) {
        return release;
      }
    }
    return null;
  }
  if (identity.currentVersion == null) return null;
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
