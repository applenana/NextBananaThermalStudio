import 'dart:async';
import 'dart:typed_data';
import 'protocol.dart';

class DeviceApiError implements Exception {
  final String code;
  final String? api;
  DeviceApiError(this.code, {this.api});
  @override
  String toString() => api == null ? code : '$api: $code';
}

class SessionChanged implements Exception {
  @override
  String toString() => '设备会话已改变，请重新获取参数及照片';
}

class StarThermalClient {
  final Future<void> Function(String) write;
  final Future<void> Function(int) setHostBaud;
  final void Function(Uint8List) onStream;
  final ResponseParser _parser = ResponseParser();
  Completer<DeviceResponse>? _pending;
  String? _api;
  bool streaming = false, closed = false, _draining = false;
  int? sessionId, bootId;
  int baud, retries = 0;
  DateTime _lastByte = DateTime.now();
  StarThermalClient({
    required this.write,
    required this.setHostBaud,
    required this.onStream,
    required this.baud,
  });

  void feed(Uint8List bytes) {
    _lastByte = DateTime.now();
    if (closed || _draining) return;
    if (streaming) {
      onStream(bytes);
      return;
    }
    try {
      _parser.add(bytes);
      DeviceResponse? r;
      while ((r = _parser.next()) != null) {
        if (r!.header['api'] != _api) continue;
        final pending = _pending;
        if (pending == null || pending.isCompleted) continue;
        if (r.header['ok'] != true) {
          pending.completeError(
            DeviceApiError('${r.header['error']}', api: _api),
          );
        } else {
          if (_api == 'StartY16Stream') streaming = true;
          pending.complete(r);
        }
        if (streaming) {
          onStream(_parser.takeRemaining());
          break;
        }
      }
    } catch (e) {
      if (_pending != null && !_pending!.isCompleted) {
        _pending!.completeError(e);
      }
    }
  }

  Future<DeviceResponse> once(String command) async {
    if (closed) throw StateError('设备已断开');
    if (streaming || _pending != null) throw StateError('串口忙');
    _api = command.trim().split(' ').first;
    final pending = _pending = Completer<DeviceResponse>();
    // Attach timeout handler before writing (a synchronous fake transport can reply).
    final response = pending.future.timeout(const Duration(seconds: 8));
    try {
      await write('$command\n');
      return await response;
    } finally {
      _pending = null;
      _api = null;
    }
  }

  Future<void> drain() async {
    _draining = true;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    _lastByte = DateTime.now();
    try {
      while (DateTime.now().difference(_lastByte).inMilliseconds < 300) {
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('串口未恢复空闲');
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    } finally {
      _parser.reset();
      _draining = false;
    }
  }

  void _checkSession(DeviceResponse r) {
    if (sessionId != null &&
        (r.header['sessionId'] != sessionId || r.header['bootId'] != bootId)) {
      throw SessionChanged();
    }
  }

  Future<DeviceResponse> request(String command) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final r = await once(command);
        _checkSession(r);
        return r;
      } on SessionChanged {
        rethrow;
      } on DeviceApiError catch (e) {
        if (e.code != 'BUSY' || attempt == 2) rethrow;
        retries++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      } catch (_) {
        if (attempt == 2 || closed) rethrow;
        retries++;
        await drain();
        // Never silently create a different context while retrying a deletion.
        final barrier = await once('\nBeginTransfer');
        if (sessionId != null &&
            (barrier.object['sessionId'] != sessionId ||
                barrier.object['bootId'] != bootId)) {
          throw SessionChanged();
        }
        sessionId = barrier.object['sessionId'] as int;
        bootId = barrier.object['bootId'] as int;
      }
    }
  }

  Future<void> begin() async {
    final r = await once('BeginTransfer');
    if (r.object['protocolVersion'] != 2) {
      throw const FormatException('协议版本不支持');
    }
    sessionId = r.object['sessionId'] as int;
    bootId = r.object['bootId'] as int;
  }

  Future<void> end() async {
    if (closed) return;
    try {
      for (var i = 0; ; i++) {
        try {
          await once('EndTransfer');
          break;
        } catch (_) {
          if (i == 2) rethrow;
          await drain();
        }
      }
    } finally {
      sessionId = null;
      bootId = null;
    }
  }

  Future<void> changeBaud(int target) async {
    if (![115200, 921600, 2000000].contains(target)) {
      throw ArgumentError('不支持的速率');
    }
    final previous = baud;
    try {
      await once('SetBaud $target');
    } on DeviceApiError {
      rethrow;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 70));
    for (final speed in {target, previous}) {
      await setHostBaud(speed);
      baud = speed;
      _parser.reset();
      try {
        final r = await once('\nGetBaud');
        if (r.object['baud'] == speed) {
          if (speed != target) throw DeviceApiError('设备仍为 $speed bps');
          return;
        }
      } on DeviceApiError {
        rethrow;
      } catch (_) {}
    }
    throw StateError('无法确认设备速率，请重新连接');
  }

  Future<void> stop() async {
    if (closed) return;
    await write('StopY16Stream\n');
    streaming = false;
    await drain();
    final info = await once('GetSysInfo');
    if (info.object['y16Stream']?['active'] != false) throw StateError('推流未停止');
  }

  void close() {
    closed = true;
    streaming = false;
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError(StateError('设备已断开'));
    }
    _parser.reset();
  }
}
