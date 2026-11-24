// Opt-in serial integration test; no widgets or UI acceptance.
// Set STARTHERMAL_TEST_PORT, LIBSERIALPORT_PATH and PATH to the Windows DLLs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:banana_thermal/serial/identity_handshake.dart';
import 'package:banana_thermal/serial/serial_service.dart';
import 'package:banana_thermal/starthermal/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final port = Platform.environment['STARTHERMAL_TEST_PORT'];
  test(
    'serial hardware reconnects at all retained rates and after streaming',
    () async {
      final service = SerialService();
      StarThermalClient? client;
      var probing = false;
      final results = <Map<String, dynamic>>[];
      final subscription = service.bytesStream.listen((bytes) {
        if (!probing) client?.feed(bytes);
      });

      Future<void> connect({int initialBaud = 115200}) async {
        client?.close();
        client = null;
        await service.open(port!, baud: initialBaud);
        probing = true;
        late SerialIdentity match;
        try {
          match = (await IdentityHandshake(
            bytes: service.bytesStream,
            write: service.writeAll,
            setBaud: service.setBaud,
          ).run([initialBaud, 115200, 2000000, 921600]))!;
        } finally {
          probing = false;
        }
        client = StarThermalClient(
          baud: match.baud,
          write: (line) =>
              service.writeAll(Uint8List.fromList(ascii.encode(line))),
          setHostBaud: service.setBaud,
          onStream: (_) {},
        );
        expect(match.info['deviceModel'], 'StarThermal');
      }

      try {
        await connect();
        for (var round = 1; round <= 3; round++) {
          for (final baud in [115200, 2000000, 921600]) {
            await client!.changeBaud(baud);
            // Simulate a prior host disconnecting part-way through a command.
            await service.writeAll(Uint8List.fromList(ascii.encode('Get')));
            await service.close();
            final clock = Stopwatch()..start();
            await connect();
            expect(client!.baud, baud);
            expect((await client!.once('\nGetBaud')).object['baud'], baud);
            results.add({
              'round': round,
              'retainedBaud': baud,
              'connectedBaud': client!.baud,
              'milliseconds': clock.elapsedMilliseconds,
            });
          }
        }

        await client!.changeBaud(2000000);
        await client!.once('StartY16Stream BP64');
        await service.close();
        // Start at the correct baud to exercise stream recovery before its
        // 3-second keepalive timeout, rather than waiting for natural expiry.
        await connect(initialBaud: 2000000);
        final info = (await client!.once('GetSysInfo')).object;
        expect(info['y16Stream']['active'], false);
        results.add({'streamRecovery': true, 'baud': client!.baud});

        // Exercise the real automatic-probe entry point and its port cleanup.
        await service.close();
        probing = true;
        final discovered = await SerialService.probeDevice(
          port!,
          baud: 2000000,
        );
        expect(discovered?['deviceModel'], 'StarThermal');
        await connect(initialBaud: 2000000);
        results.add({'discoveryAndReopen': true});

        await service.close();
        final searching = Completer<void>();
        final search = SerialService.searchTargetDevice(
          baud: 115200,
          allowedPorts: {port},
          onProbe: (_) {
            if (!searching.isCompleted) searching.complete();
          },
        );
        await searching.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await SerialService.cancelSearch();
        expect((await search).port, isNull);
        await connect(initialBaud: 2000000);
        results.add({'cancelSearchAndReopen': true});
      } finally {
        // Restore a known idle device state, even if an assertion fails.
        try {
          await connect();
          await client!.changeBaud(115200);
          expect((await client!.once('\nGetBaud')).object['baud'], 115200);
          results.add({'restoredBaud': 115200});
        } finally {
          client?.close();
          await subscription.cancel();
          await service.dispose();
        }
        final output = File('build/serial-connection-check.json');
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(results),
        );
      }
    },
    skip: port == null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
