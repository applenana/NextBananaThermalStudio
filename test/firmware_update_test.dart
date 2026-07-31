import 'dart:convert';

import 'package:banana_thermal/firmware/firmware_update.dart';
import 'package:banana_thermal/firmware/firmware_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _digestA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _digestB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _digestC =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

void main() {
  group('FirmwareDeviceIdentity', () {
    test('识别官方双光型号与独立固件版本', () {
      final identity = FirmwareDeviceIdentity.fromDeviceInfo(const {
        'version': 'HEIMAN-NSP-v1.7.0-32',
        'firmwareVersion': 'v1.7.0',
        'SerialNum': 'ABC123',
      });

      expect(identity.canFlash, isTrue);
      expect(identity.model, bananaDualLightModel);
      expect(identity.currentVersion, 'v1.7.0');
      expect(identity.serialNumber, 'ABC123');
      expect(identity.reportedVariant, isNull);
    });

    test('接受未来明确上报的型号和 Flash 容量', () {
      final identity = FirmwareDeviceIdentity.fromDeviceInfo(const {
        'deviceModel': 'HEIMAN-NSP',
        'sensorClass': '32',
        'firmwareVersion': 'v1.8.0',
        'flashSizeMb': 8,
      });

      expect(identity.canFlash, isTrue);
      expect(identity.reportedVariant, FirmwareVariant.flash8MbPerformance);
    });

    test('拒绝其他热成像、相似型号和字段冲突', () {
      expect(
        FirmwareDeviceIdentity.fromDeviceInfo(const {
          'deviceModel': 'OTHER-THERMAL',
          'firmwareVersion': 'v1.7.0',
        }).canFlash,
        isFalse,
      );
      expect(
        FirmwareDeviceIdentity.fromDeviceInfo(const {
          'version': 'HEIMAN-NSP-PRO-v1.7.0-32',
        }).canFlash,
        isFalse,
      );
      expect(
        FirmwareDeviceIdentity.fromDeviceInfo(const {
          'deviceModel': 'OTHER-THERMAL',
          'version': 'HEIMAN-NSP-v1.7.0-32',
        }).canFlash,
        isFalse,
      );
    });
  });

  group('Firmware releases', () {
    test('解析、排序正式版本并保留全部升降级目标', () {
      final releases = parseFirmwareReleaseList(
        jsonEncode([
          _releaseJson('v1.7.0', _digestA),
          _releaseJson('v1.9.0', _digestB),
          _releaseJson('v1.8.0', _digestC),
          _releaseJson('v2.0.0-rc.1', _digestA, prerelease: true),
        ]),
      );

      expect(releases.map((release) => release.tagName), [
        'v1.9.0',
        'v1.8.0',
        'v1.7.0',
      ]);
      final identity = FirmwareDeviceIdentity.fromDeviceInfo(const {
        'version': 'HEIMAN-NSP-v1.8.0-32',
      });
      expect(findNewerFirmware(identity, releases)?.tagName, 'v1.9.0');
      expect(
        releases.last.assetFor(FirmwareVariant.flash2Mb)?.name,
        'banana-thermal-v1.7.0-sketch1m_fs1m.uf2',
      );
    });

    test('拒绝伪造仓库路径的附件', () {
      final json = _releaseJson('v1.7.0', _digestA);
      final assets = json['assets'] as List<Map<String, dynamic>>;
      assets[0]['browser_download_url'] =
          'https://github.com/attacker/BananaThermalFirmware/'
          'releases/download/v1.7.0/manifest.json';

      final releases = parseFirmwareReleaseList(jsonEncode([json]));
      expect(releases, isEmpty);
    });
  });

  group('FirmwareManifest', () {
    test('严格校验三个变体并按环境选择', () {
      final manifest = FirmwareManifest.fromJsonString(
        jsonEncode(_manifestJson()),
        expectedTag: 'v1.7.0',
      );

      final stable = manifest.artifactFor(FirmwareVariant.flash8MbStable);
      expect(stable.environment, 'sketch3m_fs5m_stable');
      expect(stable.sha256, _digestC);
    });

    test('拒绝错误仓库、遗漏变体和路径型文件名', () {
      final wrongRepository = _manifestJson();
      (wrongRepository['builder']
              as Map<String, dynamic>)['workflow_repository'] =
          'attacker/repo';
      expect(
        () => FirmwareManifest.fromJsonString(
          jsonEncode(wrongRepository),
          expectedTag: 'v1.7.0',
        ),
        throwsFormatException,
      );

      final missing = _manifestJson();
      (missing['artifacts'] as List).removeLast();
      expect(
        () => FirmwareManifest.fromJsonString(
          jsonEncode(missing),
          expectedTag: 'v1.7.0',
        ),
        throwsFormatException,
      );

      final pathName = _manifestJson();
      ((pathName['artifacts'] as List).first as Map<String, dynamic>)['file'] =
          '../firmware.uf2';
      expect(
        () => FirmwareManifest.fromJsonString(
          jsonEncode(pathName),
          expectedTag: 'v1.7.0',
        ),
        throwsFormatException,
      );
    });
  });

  test('只把真实 RP2040 INFO_UF2 识别为烧录盘', () {
    expect(
      Uf2Flasher.isRp2040Info(
        'UF2 Bootloader v3.0\nModel: Raspberry Pi RP2\n'
        'Board-ID: RPI-RP2\n',
      ),
      isTrue,
    );
    expect(Uf2Flasher.isRp2040Info('ordinary removable disk'), isFalse);
    expect(
      Uf2Flasher.isRp2040Info('UF2 Bootloader\nBoard-ID: OTHER-BOARD'),
      isFalse,
    );
  });
}

Map<String, dynamic> _releaseJson(
  String tag,
  String digest, {
  bool prerelease = false,
}) {
  Map<String, dynamic> asset(String name, String sha) => {
    'name': name,
    'browser_download_url':
        'https://github.com/applenana/BananaThermalFirmware/'
        'releases/download/$tag/$name',
    'size': name == 'manifest.json' ? 500 : 1630208,
    'digest': 'sha256:$sha',
  };

  return {
    'tag_name': tag,
    'name': 'Banana Thermal $tag',
    'html_url':
        'https://github.com/applenana/BananaThermalFirmware/releases/tag/$tag',
    'body': 'Release notes',
    'published_at': '2026-07-31T12:00:00Z',
    'draft': false,
    'prerelease': prerelease,
    'assets': <Map<String, dynamic>>[
      asset('manifest.json', digest),
      asset('banana-thermal-$tag-sketch1m_fs1m.uf2', _digestA),
      asset('banana-thermal-$tag-sketch3m_fs5m.uf2', _digestB),
      asset('banana-thermal-$tag-sketch3m_fs5m_stable.uf2', _digestC),
    ],
  };
}

Map<String, dynamic> _manifestJson() => {
  'schema_version': 1,
  'firmware_tag': 'v1.7.0',
  'source_revision_sha256':
      'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  'builder': {
    'platformio_core': '6.1.19',
    'workflow_repository': 'applenana/BananaThermalFirmware',
  },
  'artifacts': [
    {
      'file': 'banana-thermal-v1.7.0-sketch1m_fs1m.uf2',
      'size': 1630208,
      'sha256':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'platformio_environment': 'sketch1m_fs1m',
    },
    {
      'file': 'banana-thermal-v1.7.0-sketch3m_fs5m.uf2',
      'size': 1630208,
      'sha256':
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'platformio_environment': 'sketch3m_fs5m',
    },
    {
      'file': 'banana-thermal-v1.7.0-sketch3m_fs5m_stable.uf2',
      'size': 1630208,
      'sha256':
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      'platformio_environment': 'sketch3m_fs5m_stable',
    },
  ],
};
