import 'dart:async';
import 'dart:typed_data';

import 'package:banana_thermal/serial/identity_handshake.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_handshake_test.dart' show identity, reply;

void main() {
  for (final selected in [921600, 2000000]) {
    test(
      'selected $selected rate remains first with retries enabled',
      () async {
        final bytes = StreamController<Uint8List>.broadcast(sync: true);
        addTearDown(bytes.close);
        final rates = <int>[];
        var requests = 0;
        final handshake = IdentityHandshake(
          bytes: bytes.stream,
          settleTime: Duration.zero,
          perBaudTimeout: const Duration(milliseconds: 60),
          setBaud: (rate) async {
            rates.add(rate);
          },
          write: (data) async {
            expect(String.fromCharCodes(data), '\nGetSysInfo\n');
            if (++requests == 2) bytes.add(reply('GetSysInfo', identity));
          },
        );
        final result = await handshake.run([selected, 115200, 2000000, 921600]);
        expect(result?.baud, selected);
        expect(rates, [selected]);
        expect(requests, 2);
      },
    );
  }

  test(
    'selected rate failure preserves fallback order and removes duplicates',
    () async {
      final bytes = StreamController<Uint8List>.broadcast(sync: true);
      addTearDown(bytes.close);
      final rates = <int>[];
      final requests = <int, int>{};
      var current = 0;
      final handshake = IdentityHandshake(
        bytes: bytes.stream,
        settleTime: Duration.zero,
        perBaudTimeout: const Duration(milliseconds: 30),
        setBaud: (rate) async {
          current = rate;
          rates.add(rate);
        },
        write: (_) async {
          requests.update(current, (count) => count + 1, ifAbsent: () => 1);
          if (current == 2000000) bytes.add(reply('GetSysInfo', identity));
        },
      );
      expect(
        (await handshake.run([921600, 115200, 2000000, 921600]))?.baud,
        2000000,
      );
      expect(rates, [921600, 115200, 2000000]);
      expect(requests, {921600: 3, 115200: 3, 2000000: 1});
    },
  );

  test(
    'cancelled discovery cannot consume the subsequent manual identity',
    () async {
      final bytes = StreamController<Uint8List>.broadcast(sync: true);
      addTearDown(bytes.close);
      final sent = Completer<void>();
      var probeWrites = 0;
      final discovery = IdentityHandshake(
        bytes: bytes.stream,
        settleTime: Duration.zero,
        setBaud: (_) async {},
        write: (_) async {
          probeWrites++;
          sent.complete();
        },
      );
      final pending = discovery.run([115200, 2000000]);
      final cancelled = expectLater(pending, throwsStateError);
      await sent.future;
      discovery.cancel();
      await cancelled;
      expect(bytes.hasListener, false);
      final manual = IdentityHandshake(
        bytes: bytes.stream,
        settleTime: Duration.zero,
        setBaud: (_) async {},
        write: (_) async {
          bytes.add(reply('GetSysInfo', identity));
        },
      );
      expect((await manual.run([2000000]))?.baud, 2000000);
      expect(probeWrites, 1);
      expect(bytes.hasListener, false);
    },
  );
}
