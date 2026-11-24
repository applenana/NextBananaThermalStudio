import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:banana_thermal/serial/identity_handshake.dart';
import 'package:banana_thermal/starthermal/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const identity = {'deviceModel': 'StarThermal', 'protocolVersion': 2};

Uint8List reply(String api, Map<String, dynamic> body, {bool corrupt = false}) {
  final payload = utf8.encode(jsonEncode(body));
  return Uint8List.fromList([
    ...utf8.encode(
      '${jsonEncode({'api': api, 'ok': true, 'jsonLength': payload.length, 'binaryLength': 0, 'crc32': corrupt ? '00000000' : crcHex(payload)})}\n',
    ),
    ...payload,
  ]);
}

void main() {
  test('coalesced stale response does not hide the identity response', () {
    expect(
      IdentityProbe().add(
        Uint8List.fromList([
          ...reply('GetBaud', {'baud': 2000000}),
          ...reply('GetSysInfo', identity),
        ]),
      ),
      identity,
    );
  });

  test('bad CRC is rejected even with a newline after the identity body', () {
    final probe = IdentityProbe();
    expect(
      probe.add(
        Uint8List.fromList([
          ...reply('GetSysInfo', {
            ...identity,
            'SerialNum': 'test',
          }, corrupt: true),
          10,
        ]),
      ),
      isNull,
    );
    expect(probe.lastError, contains('CRC32'));
  });

  test('bad frame followed by valid identity in one packet recovers', () {
    expect(
      IdentityProbe().add(
        Uint8List.fromList([
          ...reply('GetSysInfo', identity, corrupt: true),
          ...reply('GetSysInfo', identity),
        ]),
      ),
      identity,
    );
  });

  test('wrong API and orphaned v2 body are not identity responses', () {
    final probe = IdentityProbe();
    expect(probe.add(reply('GetSettings', identity)), isNull);
    expect(
      probe.add(
        Uint8List.fromList(
          utf8.encode('\n${jsonEncode({...identity, 'SerialNum': 'test'})}\n'),
        ),
      ),
      isNull,
    );
  });

  test('bounded parser recovers after excessive garbage', () {
    final probe = IdentityProbe();
    expect(probe.add(Uint8List(2 * 1024 * 1024 + 1)), isNull);
    expect(probe.add(reply('GetSysInfo', identity)), identity);
  });

  for (final deviceBaud in [115200, 2000000, 921600]) {
    test('wrong-rate damage is cleared before probing $deviceBaud', () async {
      final bytes = StreamController<Uint8List>(sync: true);
      addTearDown(bytes.close);
      var hostBaud = 0, discardUntilNewline = false;
      var command = '';
      final rates = <int>[];
      final handshake = IdentityHandshake(
        bytes: bytes.stream,
        settleTime: Duration.zero,
        perBaudTimeout: const Duration(milliseconds: 30),
        setBaud: (baud) async {
          hostBaud = baud;
          rates.add(baud);
        },
        write: (data) async {
          if (hostBaud != deviceBaud) {
            discardUntilNewline = true;
            return;
          }
          for (final byte in data) {
            if (byte == 10) {
              if (!discardUntilNewline && command == 'GetSysInfo') {
                bytes.add(reply('GetSysInfo', identity));
              }
              command = '';
              discardUntilNewline = false;
            } else if (!discardUntilNewline) {
              command += String.fromCharCode(byte);
            }
          }
        },
      );
      final match = await handshake.run([115200, 2000000, 921600]);
      expect(match?.baud, deviceBaud);
      expect(match?.info, identity);
      expect(rates.last, deviceBaud);
    });
  }

  test(
    'lost first query retries at same baud and resets truncated response',
    () async {
      final bytes = StreamController<Uint8List>(sync: true);
      addTearDown(bytes.close);
      var writes = 0, changes = 0;
      final handshake = IdentityHandshake(
        bytes: bytes.stream,
        settleTime: Duration.zero,
        perBaudTimeout: const Duration(milliseconds: 60),
        setBaud: (_) async {
          changes++;
        },
        write: (_) async {
          writes++;
          if (writes == 1) {
            bytes.add(
              Uint8List.fromList(
                utf8.encode(
                  '{"api":"GetSysInfo","ok":true,"jsonLength":50000,"binaryLength":0}\npartial',
                ),
              ),
            );
          } else {
            final response = reply('GetSysInfo', identity);
            for (final byte in response) {
              bytes.add(Uint8List.fromList([byte]));
            }
          }
        },
      );
      expect((await handshake.run([2000000]))?.info, identity);
      expect(writes, 2);
      expect(changes, 1);
    },
  );

  test(
    'remaining Y16 stream is stopped only after detecting its header',
    () async {
      final bytes = StreamController<Uint8List>(sync: true);
      addTearDown(bytes.close);
      var streaming = true;
      final commands = <String>[];
      final handshake = IdentityHandshake(
        bytes: bytes.stream,
        settleTime: Duration.zero,
        perBaudTimeout: const Duration(milliseconds: 60),
        setBaud: (_) async {},
        write: (data) async {
          final command = ascii.decode(data);
          commands.add(command);
          if (command.contains('StopY16Stream')) {
            streaming = false;
            return;
          }
          if (streaming) {
            bytes.add(Uint8List.fromList([89, 49]));
            bytes.add(Uint8List.fromList([54, 70, 0x60, 0x54]));
          } else {
            bytes.add(reply('GetSysInfo', identity));
          }
        },
      );
      expect((await handshake.run([2000000]))?.info, identity);
      expect(commands, [
        '\nGetSysInfo\n',
        '\nStopY16Stream\n',
        '\nGetSysInfo\n',
      ]);
    },
  );

  test('legacy device needs no stream or baud-changing command', () async {
    final bytes = StreamController<Uint8List>(sync: true);
    addTearDown(bytes.close);
    final handshake = IdentityHandshake(
      bytes: bytes.stream,
      settleTime: Duration.zero,
      setBaud: (_) async {},
      write: (data) async {
        expect(ascii.decode(data), '\nGetSysInfo\n');
        bytes.add(Uint8List.fromList(ascii.encode('{"SerialNum":"legacy"}\n')));
      },
    );
    expect((await handshake.run([115200]))?.info['SerialNum'], 'legacy');
  });

  test('no response is bounded and releases the listener', () async {
    final bytes = StreamController<Uint8List>(sync: true);
    addTearDown(bytes.close);
    final messages = <String>[];
    var writes = 0;
    final handshake = IdentityHandshake(
      bytes: bytes.stream,
      settleTime: Duration.zero,
      perBaudTimeout: const Duration(milliseconds: 15),
      setBaud: (_) async {},
      write: (_) async {
        writes++;
      },
      onLog: messages.add,
    );
    expect(await handshake.run([115200, 115200, 2000000]), isNull);
    expect(writes, 6);
    expect(messages.where((s) => s.contains('未收到字节')), hasLength(2));
    expect(bytes.hasListener, isFalse);
  });

  test('read errors abort immediately instead of trying other rates', () async {
    final bytes = StreamController<Uint8List>(sync: true);
    addTearDown(bytes.close);
    var writes = 0;
    final handshake = IdentityHandshake(
      bytes: bytes.stream,
      settleTime: Duration.zero,
      setBaud: (_) async {},
      write: (_) async {
        writes++;
        bytes.addError(StateError('unplugged'));
      },
    );
    await expectLater(handshake.run([115200, 2000000]), throwsStateError);
    expect(writes, 1);
    expect(bytes.hasListener, isFalse);
  });

  test(
    'cancel during query prevents further writes and releases listener',
    () async {
      final bytes = StreamController<Uint8List>(sync: true);
      addTearDown(bytes.close);
      var writes = 0;
      late IdentityHandshake handshake;
      handshake = IdentityHandshake(
        bytes: bytes.stream,
        settleTime: Duration.zero,
        setBaud: (_) async {},
        write: (_) async {
          writes++;
          handshake.cancel();
        },
      );
      await expectLater(handshake.run([115200, 2000000]), throwsStateError);
      expect(writes, 1);
      expect(bytes.hasListener, isFalse);
    },
  );
}
