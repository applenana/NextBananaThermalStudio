import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:banana_thermal/firmware/firmware_update.dart';
import 'package:banana_thermal/firmware/starthermal_ota.dart';
import 'package:banana_thermal/firmware/starthermal_package.dart';
import 'package:banana_thermal/starthermal/protocol.dart';
import 'package:banana_thermal/serial/serial_port_info.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/starthermal_release.json').readAsStringSync(),
          )
          as Map;
  Uint8List bytes(String name) =>
      base64Decode(fixture['files'][name] as String);
  const tag = 'StarThermal-v0.1.0';
  final image = bytes('$tag.bin');
  final info = <String, dynamic>{
    'deviceModel': 'StarThermal',
    'protocolVersion': 2,
    'firmwareVersion': '0.0.9',
    'SerialNum': 'BOARD-1',
    'hardwareId': 'starthermal-rp2040-8m',
  };
  final identity = FirmwareDeviceIdentity.fromDeviceInfo(info);

  test(
    'catalog traverses full pages of another product before selecting latest',
    () async {
      final pages = <int>[];
      final releases = await fetchFirmwareReleasePages((page) async {
        pages.add(page);
        return jsonEncode(
          page == 1
              ? List.generate(100, (i) => _release('StarThermal-v0.1.$i'))
              : [_release('v1.8.1')],
        );
      });
      expect(pages, [1, 2]);
      expect(releases, hasLength(101));
      final old = FirmwareDeviceIdentity.fromDeviceInfo({
        'version': 'HEIMAN-NSP-v1.8.0-32',
      });
      expect(findNewerFirmware(old, releases)?.tagName, 'v1.8.1');
      await expectLater(
        fetchFirmwareReleasePages(
          (page) async =>
              jsonEncode(List.generate(100, (_) => {'draft': true})),
          maximumPages: 2,
        ),
        throwsFormatException,
      );
    },
  );

  test('legacy USB descriptions and logs use public branding', () {
    final port = SerialPortInfo(
      name: 'COM1',
      description: '$legacyStarThermalModel USB',
      productName: legacyStarThermalModel.toLowerCase(),
      manufacturer: legacyStarThermalModel,
    );
    expect(port.description, 'StarThermal USB');
    expect(port.productName, 'StarThermal');
    expect(port.manufacturer, 'StarThermal');
    expect(
      publicStarThermalText('$legacyStarThermalModel connected'),
      'StarThermal connected',
    );
    expect(
      FirmwareDeviceIdentity.fromDeviceInfo({
        ...info,
        'otaProtocol': 'other',
      }).canFlash,
      isFalse,
    );
  });

  test(
    'OpenSSH signature authenticates manifest and binary with independent test key',
    () async {
      final sums = await verifyStarThermalChecksums(
        bytes('SHA256SUMS'),
        utf8.decode(bytes('SHA256SUMS.sig')),
        tag,
        trustedKey: fixture['public_key'] as String,
      );
      expect(
        sums['manifest.json'],
        sha256.convert(bytes('manifest.json')).toString(),
      );
      final artifact = parseStarThermalManifest(
        utf8.decode(bytes('manifest.json')),
        tag: tag,
      );
      expect(artifact.sha256, sums[artifact.file]);
      expect(artifact.sha256, sha256.convert(image).toString());
      validateStarThermalImage(image, tag);
    },
  );

  test(
    'production trust refuses fixture signing key and tampered checksums',
    () async {
      await expectLater(
        verifyStarThermalChecksums(
          bytes('SHA256SUMS'),
          utf8.decode(bytes('SHA256SUMS.sig')),
          tag,
        ),
        throwsFormatException,
      );
      final changed = bytes('SHA256SUMS')..[0] ^= 1;
      await expectLater(
        verifyStarThermalChecksums(
          changed,
          utf8.decode(bytes('SHA256SUMS.sig')),
          tag,
          trustedKey: fixture['public_key'] as String,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'schema3 rejects wrong product, partition, protocol and duplicate artifact',
    () {
      for (final field in ['product_id', 'firmware_tag', 'device_model']) {
        final manifest = jsonDecode(utf8.decode(bytes('manifest.json'))) as Map;
        manifest[field] = 'other';
        expect(
          () => parseStarThermalManifest(jsonEncode(manifest), tag: tag),
          throwsFormatException,
        );
      }
      for (final field in [
        'hardware_id',
        'flash_bytes',
        'max_firmware_bytes',
        'transfer_protocol',
      ]) {
        final manifest = jsonDecode(utf8.decode(bytes('manifest.json'))) as Map;
        manifest['artifacts'][0][field] = 'other';
        expect(
          () => parseStarThermalManifest(jsonEncode(manifest), tag: tag),
          throwsFormatException,
        );
      }
      final manifest = jsonDecode(utf8.decode(bytes('manifest.json'))) as Map;
      manifest['artifacts'][1] = manifest['artifacts'][0];
      expect(
        () => parseStarThermalManifest(jsonEncode(manifest), tag: tag),
        throwsFormatException,
      );
      expect(
        () => validateStarThermalImage(image, 'StarThermal-v0.1.1'),
        throwsFormatException,
      );
      expect(
        () => FirmwareManifest.fromJsonString(
          utf8.decode(bytes('manifest.json')),
          expectedTag: tag,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'new and legacy devices select only their own independent release stream',
    () {
      final releases = parseFirmwareReleaseList(
        jsonEncode([
          _release('v9.0.0'),
          _release('StarThermal-v8.0.0'),
          _release('v1.8.1'),
        ]),
      );
      final old = FirmwareDeviceIdentity.fromDeviceInfo({
        'version': 'HEIMAN-NSP-v1.8.0-32',
      });
      final legacyStar = FirmwareDeviceIdentity.fromDeviceInfo({
        ...info,
        'deviceModel': legacyStarThermalModel,
      });
      expect(
        findNewerFirmware(identity, releases)!.tagName,
        'StarThermal-v8.0.0',
      );
      expect(
        findNewerFirmware(legacyStar, releases)!.tagName,
        'StarThermal-v8.0.0',
      );
      expect(findNewerFirmware(old, releases)!.tagName, 'v9.0.0');
      expect(
        FirmwareDeviceIdentity.fromDeviceInfo({
          ...info,
          'hardwareId': 'wrong',
        }).canFlash,
        isFalse,
      );
      expect(releases.first.assetFor(FirmwareVariant.starThermal8Mb), isNull);
    },
  );

  test(
    'OTA tolerates split lines, a CRC retry and lost ACK; commits only after staged',
    () async {
      final stream = StreamController<Uint8List>(sync: true);
      final commands = <String>[];
      final packets = <Uint8List>[];
      void reply(String text) {
        final data = Uint8List.fromList(utf8.encode('!StarThermal/1 $text\n'));
        stream.add(Uint8List.sublistView(data, 0, 5));
        stream.add(Uint8List.sublistView(data, 5));
      }

      final ota = StarThermalOta(
        input: stream.stream,
        replyTimeout: const Duration(milliseconds: 15),
        write: (packet) async {
          final command = ascii.decode(packet.sublist(0, packet.indexOf(10)));
          commands.add(command);
          if (command == 'GetSysInfo') {
            final body = utf8.encode(jsonEncode(info));
            stream.add(
              Uint8List.fromList([
                ...utf8.encode(
                  '${jsonEncode({'api': 'GetSysInfo', 'ok': true, 'jsonLength': body.length, 'binaryLength': 0, 'crc32': crcHex(body)})}\n',
                ),
                ...body,
              ]),
            );
          } else if (command == 'OTA ENTER') {
            reply('ENTERING; WAIT FOR MODE READY');
            reply('MODE READY');
          } else if (command.startsWith('OTA BEGIN ')) {
            expect(
              command,
              'OTA BEGIN ${image.length} ${sha256.convert(image)} 4096',
            );
            reply('READY CHUNK=4096 SEQ=0');
          } else if (command.startsWith('OTA DATA ')) {
            packets.add(packet);
            final payload = packet.sublist(packet.indexOf(10) + 1);
            expect(payload, image);
            expect(command, 'OTA DATA 0 ${image.length} ${crcHex(image)}');
            if (packets.length == 1) reply('NAK CRC');
            if (packets.length == 3) reply('ACK 0 DUP');
          } else if (command == 'OTA END') {
            reply('STAGED; SEND OTA COMMIT TO REBOOT');
          } else if (command == 'OTA COMMIT') {
            reply('REBOOTING; DO NOT REMOVE POWER');
          }
        },
      );
      try {
        await ota.verifyIdentity(identity);
        await ota.transfer(image, tag: tag, onProgress: (_) {});
        expect(packets.length, 3);
        expect(packets[0], packets[2]);
        expect(commands.last, 'OTA COMMIT');
      } finally {
        await ota.dispose();
        await stream.close();
      }
    },
  );

  test('busy transition never sends firmware before mode ready', () async {
    final stream = StreamController<Uint8List>(sync: true);
    final commands = <String>[];
    final ota = StarThermalOta(
      input: stream.stream,
      write: (bytes) async {
        final command = ascii.decode(bytes).trim();
        commands.add(command);
        final reply = command == 'OTA ENTER'
            ? 'ERR MODE BUSY'
            : command == 'OTA STATUS'
            ? 'STATUS 0 0/0 ERR=0 MODE=2'
            : null;
        if (reply != null) {
          stream.add(
            Uint8List.fromList(
              ascii.encode('!$legacyStarThermalModel/1 $reply\n'),
            ),
          );
        }
      },
    );
    try {
      await expectLater(
        ota.transfer(image, tag: tag, onProgress: (_) {}),
        throwsStateError,
      );
      expect(commands.any((c) => c.startsWith('OTA BEGIN')), isFalse);
    } finally {
      await ota.dispose();
      await stream.close();
    }
  });

  test('wrong connected serial is rejected before OTA mutation', () async {
    final stream = StreamController<Uint8List>(sync: true);
    final ota = StarThermalOta(
      input: stream.stream,
      write: (_) async {
        final body = utf8.encode(jsonEncode({...info, 'SerialNum': 'BOARD-2'}));
        stream.add(
          Uint8List.fromList([
            ...utf8.encode(
              '${jsonEncode({'api': 'GetSysInfo', 'ok': true, 'jsonLength': body.length, 'binaryLength': 0, 'crc32': crcHex(body)})}\n',
            ),
            ...body,
          ]),
        );
      },
    );
    try {
      await expectLater(ota.verifyIdentity(identity), throwsStateError);
    } finally {
      await ota.dispose();
      await stream.close();
    }
  });
}

Map<String, dynamic> _release(String tag) => {
  'tag_name': tag,
  'html_url':
      'https://github.com/applenana/BananaThermalFirmware/releases/tag/$tag',
  'assets': [
    {
      'name': 'manifest.json',
      'size': 100,
      'browser_download_url':
          'https://github.com/applenana/BananaThermalFirmware/releases/download/$tag/manifest.json',
    },
  ],
};
