import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:banana_thermal/firmware/android_uf2_flasher.dart';
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

  group('AndroidFirmwareUsbState', () {
    test('区分已检测但未授权的单个 RP2040 USB 磁盘', () {
      final state = AndroidFirmwareUsbState.fromMap({
        'usbHostSupported': true,
        'bootloaders': [
          {
            'id': '2e8a:0003:/dev/bus/usb/001/004',
            'deviceName': '/dev/bus/usb/001/004',
            'vendorId': 0x2E8A,
            'productId': 0x0003,
            'hasPermission': false,
          },
        ],
      });

      expect(state.usbHostSupported, isTrue);
      expect(state.singleBootloader, isNotNull);
      expect(state.singleBootloader!.hasPermission, isFalse);
      expect(state.singleBootloader!.vendorId, 0x2E8A);
    });

    test('多个 BOOTSEL 候选不会被错误选成唯一烧录目标', () {
      final state = AndroidFirmwareUsbState.fromMap({
        'usbHostSupported': true,
        'bootloaders': [
          {
            'id': 'first',
            'deviceName': 'first',
            'vendorId': 0x2E8A,
            'productId': 3,
            'hasPermission': true,
          },
          {
            'id': 'second',
            'deviceName': 'second',
            'vendorId': 0x2E8A,
            'productId': 3,
            'hasPermission': true,
          },
        ],
      });

      expect(state.bootloaders, hasLength(2));
      expect(state.singleBootloader, isNull);
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

  test('用户选择的目录必须通过 RP2040 UF2 磁盘校验', () async {
    final directory = await Directory.systemTemp.createTemp('uf2-volume-test-');
    try {
      expect(await Uf2Flasher.inspectRp2040Volume(directory), isNull);
      await File(
        '${directory.path}${Platform.pathSeparator}INFO_UF2.TXT',
      ).writeAsString(
        'UF2 Bootloader v3.0\nModel: Raspberry Pi RP2\n'
        'Board-ID: RPI-RP2\n',
      );

      final volume = await Uf2Flasher.inspectRp2040Volume(directory);
      expect(volume, isNotNull);
      expect(volume!.root.path, directory.path);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  group('RP2040 UF2 结构校验', () {
    test('接受连续、带 RP2040 family ID 且只写主 Flash 的块', () {
      validateRp2040Uf2Block(_uf2Block(0, 2), index: 0, blockCount: 2);
      validateRp2040Uf2Block(_uf2Block(1, 2), index: 1, blockCount: 2);
    });

    test('拒绝错误家族、乱序、非主 Flash 和越界地址', () {
      expect(
        () => validateRp2040Uf2Block(
          _uf2Block(0, 1, familyId: 0x12345678),
          index: 0,
          blockCount: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => validateRp2040Uf2Block(_uf2Block(1, 2), index: 0, blockCount: 2),
        throwsFormatException,
      );
      expect(
        () => validateRp2040Uf2Block(
          _uf2Block(0, 1, flags: 0x2001),
          index: 0,
          blockCount: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => validateRp2040Uf2Block(
          _uf2Block(0, 1, address: 0x20000000),
          index: 0,
          blockCount: 1,
        ),
        throwsFormatException,
      );
    });

    test('完整文件校验接受连续块并拒绝截断文件', () async {
      final directory = await Directory.systemTemp.createTemp('uf2-file-test-');
      try {
        final valid = File(
          '${directory.path}${Platform.pathSeparator}valid.uf2',
        );
        await valid.writeAsBytes([..._uf2Block(0, 2), ..._uf2Block(1, 2)]);
        expect(await validateRp2040Uf2File(valid), 2);

        final truncated = File(
          '${directory.path}${Platform.pathSeparator}truncated.uf2',
        );
        await truncated.writeAsBytes(_uf2Block(0, 1).sublist(0, 511));
        await expectLater(
          validateRp2040Uf2File(truncated),
          throwsFormatException,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });
}

Uint8List _uf2Block(
  int blockNumber,
  int blockCount, {
  int flags = 0x2000,
  int familyId = 0xE48BFF56,
  int? address,
}) {
  final block = Uint8List(512);
  final data = ByteData.sublistView(block);
  data.setUint32(0, 0x0A324655, Endian.little);
  data.setUint32(4, 0x9E5D5157, Endian.little);
  data.setUint32(8, flags, Endian.little);
  data.setUint32(12, address ?? 0x10000000 + blockNumber * 256, Endian.little);
  data.setUint32(16, 256, Endian.little);
  data.setUint32(20, blockNumber, Endian.little);
  data.setUint32(24, blockCount, Endian.little);
  data.setUint32(28, familyId, Endian.little);
  data.setUint32(508, 0x0AB16F30, Endian.little);
  return block;
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
