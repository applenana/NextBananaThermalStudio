import 'dart:async';
import 'dart:typed_data';

import '../starthermal/protocol.dart';

class SerialIdentity {
  const SerialIdentity(this.baud, this.info);
  final int baud;
  final Map<String, dynamic> info;
}

/// Shared by manual connections, desktop discovery and Android discovery.
/// Probing only changes the host rate; it never changes the device rate.
class IdentityHandshake {
  IdentityHandshake({
    required this.bytes,
    required this.write,
    required this.setBaud,
    this.onLog,
    this.perBaudTimeout = const Duration(seconds: 3),
    this.settleTime = const Duration(milliseconds: 150),
  });

  final Stream<Uint8List> bytes;
  final Future<void> Function(Uint8List) write;
  final Future<void> Function(int) setBaud;
  final void Function(String)? onLog;
  final Duration perBaudTimeout;
  final Duration settleTime;
  Completer<Map<String, dynamic>?>? _pending;
  IdentityProbe? _probe;
  Object? _readError;
  bool _cancelled = false;
  bool _started = false;

  void cancel() {
    _cancelled = true;
    _wake();
  }

  void _wake() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }

  void _checkActive() {
    if (_readError != null) throw _readError!;
    if (_cancelled) throw StateError('设备身份探测已取消');
  }

  Future<SerialIdentity?> run(Iterable<int> bauds) async {
    if (_started) throw StateError('设备身份探测不能重复运行');
    _started = true;
    var received = 0;
    String? parseError;
    var streamDetected = false;
    var streamTail = <int>[];
    final subscription = bytes.listen(
      (data) {
        received += data.length;
        // Recognize the bounded Y16 frame header across USB packet boundaries.
        // Only stop streaming after seeing this signature; legacy devices get
        // identity queries alone.
        final scan = [...streamTail, ...data];
        for (var i = 0; i + 5 < scan.length && !streamDetected; i++) {
          if (scan[i] == 89 &&
              scan[i + 1] == 49 &&
              scan[i + 2] == 54 &&
              scan[i + 3] == 70) {
            final length = scan[i + 4] | scan[i + 5] << 8;
            streamDetected = length >= 507 && length <= 21769;
          }
        }
        streamTail = scan.sublist((scan.length - 5).clamp(0, scan.length));
        final probe = _probe;
        if (probe == null) return;
        final info = probe.add(data);
        parseError = probe.lastError ?? parseError;
        final pending = _pending;
        if (info != null && pending != null && !pending.isCompleted) {
          pending.complete(info);
        }
      },
      onError: (Object error) {
        _readError = error;
        _wake();
      },
      onDone: () {
        _readError = StateError('串口接收已结束');
        _wake();
      },
    );
    try {
      for (final baud in bauds.toSet()) {
        _checkActive();
        _probe = null;
        received = 0;
        parseError = null;
        streamDetected = false;
        streamTail = [];
        await setBaud(baud);
        // Let USB/UART reconfiguration and old-rate bytes settle first.
        await Future<void>.delayed(settleTime);
        _checkActive();
        for (var attempt = 1; attempt <= 3; attempt++) {
          _checkActive();
          if (streamDetected) {
            _probe = null;
            onLog?.call('$baud bps 检测到残留热像推流，停止推流后重新查询');
            await write(Uint8List.fromList('\nStopY16Stream\n'.codeUnits));
            await Future<void>.delayed(settleTime);
            _checkActive();
            streamDetected = false;
            streamTail = [];
          }
          // A truncated response must not poison the next query indefinitely.
          _probe = IdentityProbe();
          final pending = _pending = Completer<Map<String, dynamic>?>();
          final response = pending.future.timeout(
            Duration(microseconds: perBaudTimeout.inMicroseconds ~/ 3),
            onTimeout: () => null,
          );
          onLog?.call('等待设备身份应答：$baud bps（$attempt/3）');
          // A wrong-rate probe can leave firmware discarding until newline.
          // The leading newline clears that state before the actual command.
          await write(Uint8List.fromList('\nGetSysInfo\n'.codeUnits));
          final info = await response;
          _checkActive();
          if (info != null) return SerialIdentity(baud, info);
        }
        onLog?.call(
          '$baud bps 探测超时：${received == 0 ? '未收到字节' : '收到 $received 字节，但无有效身份应答'}'
          '${parseError == null ? '' : '（$parseError）'}',
        );
      }
      return null;
    } finally {
      _probe = null;
      _wake();
      _pending = null;
      await subscription.cancel();
    }
  }
}
