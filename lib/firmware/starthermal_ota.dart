import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import '../starthermal/protocol.dart';
import 'firmware_update.dart';
import 'starthermal_package.dart';

/// Owns the serial response stream for one transfer. Never changes the baud.
class StarThermalOta {
  StarThermalOta({
    required Stream<Uint8List> input,
    required this.write,
    this.replyTimeout = const Duration(seconds: 4),
  }) {
    _subscription = input.listen(
      _feed,
      onError: (Object e) {
        _error = e;
        _wake?.complete();
        _wake = null;
      },
      onDone: () {
        _error = StateError('星像串口已断开');
        _wake?.complete();
        _wake = null;
      },
    );
  }
  final Future<void> Function(Uint8List) write;
  final Duration replyTimeout;
  late final StreamSubscription<Uint8List> _subscription;
  final Queue<String> _responses = Queue();
  final List<int> _line = [];
  Completer<void>? _wake;
  Object? _error;
  IdentityProbe? _probe;
  Completer<Map<String, dynamic>>? _identity;

  void _feed(Uint8List bytes) {
    final probe = _probe;
    if (probe != null) {
      final info = probe.add(bytes);
      if (info != null && _identity?.isCompleted == false) {
        _identity!.complete(info);
      }
    }
    for (final byte in bytes) {
      if (byte != 10) {
        _line.add(byte);
        if (_line.length > 8192) _line.clear();
        continue;
      }
      final line = utf8.decode(_line, allowMalformed: true).trim();
      _line.clear();
      for (final prefix in ['!StarThermal/1 ', '!$legacyStarThermalModel/1 ']) {
        if (!line.startsWith(prefix)) continue;
        if (_responses.length >= 128) _responses.removeFirst();
        _responses.add(line.substring(prefix.length));
        _wake?.complete();
        _wake = null;
        break;
      }
    }
  }

  Future<void> _send(String command) =>
      write(Uint8List.fromList(ascii.encode('$command\n')));

  Future<String> _response([Duration? timeout]) async {
    final deadline = DateTime.now().add(timeout ?? replyTimeout);
    while (_responses.isEmpty) {
      if (_error != null) throw _error!;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('星像 OTA 响应超时');
      final wake = _wake = Completer<void>();
      try {
        await wake.future.timeout(left);
      } finally {
        if (identical(_wake, wake)) _wake = null;
      }
    }
    return _responses.removeFirst();
  }

  Future<void> verifyIdentity(FirmwareDeviceIdentity expected) async {
    _probe = IdentityProbe();
    final pending = _identity = Completer<Map<String, dynamic>>();
    final response = pending.future.timeout(const Duration(seconds: 8));
    try {
      await _send('GetSysInfo');
      final actual = FirmwareDeviceIdentity.fromDeviceInfo(await response);
      if (!actual.canFlash ||
          !actual.isStarThermal ||
          expected.serialNumber == null ||
          expected.serialNumber!.isEmpty ||
          actual.serialNumber != expected.serialNumber ||
          actual.currentVersion != expected.currentVersion) {
        throw StateError('串口设备身份已改变，已停止星像升级');
      }
    } finally {
      _probe = null;
      _identity = null;
      _line.clear();
      _responses.clear();
    }
  }

  Future<void> transfer(
    Uint8List image, {
    required String tag,
    required void Function(double) onProgress,
  }) async {
    validateStarThermalImage(image, tag);
    await _send('LOG OFF');
    await _send('OTA ENTER');
    var response = await _response();
    if (response == 'ERR MODE BUSY') {
      await _send('OTA STATUS');
      response = await _response();
      if (response != 'MODE READY' &&
          !RegExp(r'^STATUS .*\bMODE=3(?:\s|$)').hasMatch(response)) {
        throw StateError('设备尚未准备好升级，请等待设备就绪后重试');
      }
    } else if (response == 'ENTERING; WAIT FOR MODE READY') {
      response = await _response(const Duration(seconds: 30));
      if (response != 'MODE READY') throw StateError('星像未进入升级模式：$response');
    } else {
      throw StateError('星像拒绝升级：$response');
    }
    await _send('OTA BEGIN ${image.length} ${sha256.convert(image)} 4096');
    response = await _response();
    final ready = RegExp(
      r'^READY CHUNK=(1024|2048|4096) SEQ=0$',
    ).firstMatch(response);
    if (ready == null) throw StateError('星像拒绝固件：$response');
    final chunk = int.parse(ready.group(1)!);
    var sequence = 0;
    for (var offset = 0; offset < image.length; offset += chunk, sequence++) {
      final end = (offset + chunk).clamp(0, image.length);
      final payload = Uint8List.sublistView(image, offset, end);
      final packet =
          (BytesBuilder()
                ..add(
                  ascii.encode(
                    'OTA DATA $sequence ${payload.length} ${crcHex(payload)}\n',
                  ),
                )
                ..add(payload))
              .takeBytes();
      var acknowledged = false;
      for (var attempt = 0; attempt < 4 && !acknowledged; attempt++) {
        await write(packet);
        final deadline = DateTime.now().add(replyTimeout);
        try {
          while (true) {
            response = await _response(deadline.difference(DateTime.now()));
            if (response == 'ACK $sequence' ||
                response == 'ACK $sequence DUP') {
              acknowledged = true;
              break;
            }
            // A late duplicate ACK for an earlier chunk is harmless.
            final ack = RegExp(r'^ACK (\d+)(?: DUP)?$').firstMatch(response);
            if (ack != null && int.parse(ack.group(1)!) < sequence) continue;
            if (response == 'NAK CRC') break;
            throw StateError('星像拒绝数据块：$response');
          }
        } on TimeoutException {
          if (attempt == 3) rethrow;
        }
      }
      if (!acknowledged) throw StateError('星像数据块校验连续失败');
      onProgress(end / image.length);
    }
    await _send('OTA END');
    response = await _response(const Duration(seconds: 20));
    if (response != 'STAGED; SEND OTA COMMIT TO REBOOT') {
      throw StateError('设备固件校验失败：$response');
    }
    await _send('OTA COMMIT');
    response = await _response();
    if (response != 'REBOOTING; DO NOT REMOVE POWER') {
      throw StateError('设备未确认重启：$response');
    }
  }

  Future<void> dispose() => _subscription.cancel();
}
