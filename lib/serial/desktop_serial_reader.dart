import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
// Pure Dart driver also lets the hardware diagnostic use this exact RX path.
import 'package:libserialport/libserialport.dart';

/// Owns a cooperative nonblocking reader. Closing waits for the isolate to exit,
/// so the owner can safely reconfigure or close the borrowed native port.
class DesktopSerialReader {
  final _bytes = StreamController<Uint8List>();
  final _messages = ReceivePort();
  final _exits = ReceivePort();
  final _ready = Completer<void>();
  final _exited = Completer<void>();
  SendPort? _commands;
  bool _closing = false;
  Future<void>? _close;

  Stream<Uint8List> get stream => _bytes.stream;

  static Future<DesktopSerialReader> open(int address) async {
    final reader = DesktopSerialReader();
    reader._messages.listen((message) {
      if (message is SendPort) {
        reader._commands = message;
        reader._ready.complete();
      } else if (message is Uint8List) {
        if (!reader._closing) reader._bytes.add(message);
      } else if (!reader._closing) {
        reader._bytes.addError(StateError('串口读取失败: $message'));
      }
    });
    reader._exits.listen((_) {
      if (!reader._ready.isCompleted) {
        reader._ready.completeError(StateError('串口读取线程启动失败'));
      }
      if (!reader._exited.isCompleted) reader._exited.complete();
    });
    try {
      await Isolate.spawn(
        _read,
        (address, reader._messages.sendPort),
        onExit: reader._exits.sendPort,
        onError: reader._messages.sendPort,
      );
      await reader._ready.future;
      return reader;
    } catch (_) {
      reader._messages.close();
      reader._exits.close();
      unawaited(reader._bytes.close());
      rethrow;
    }
  }

  Future<void> close() => _close ??= _stop();

  Future<void> _stop() async {
    _closing = true;
    _commands?.send(null);
    await _exited.future;
    _messages.close();
    _exits.close();
    unawaited(_bytes.close());
  }

  static void _read((int, SendPort) args) {
    // This wrapper borrows the pointer. Only SerialService owns its lifetime.
    final port = SerialPort.fromAddress(args.$1);
    final commands = ReceivePort();
    Timer? timer;
    void stop() {
      timer?.cancel();
      commands.close();
    }

    commands.listen((_) => stop());
    args.$2.send(commands.sendPort);
    timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
      try {
        final available = port.bytesAvailable;
        if (available < 0) throw StateError('${SerialPort.lastError}');
        if (available == 0) return;
        // Bounded nonblocking calls leave room for stop commands, even at 2M.
        final bytes = port.read(available.clamp(1, 65536));
        if (bytes.isNotEmpty) args.$2.send(bytes);
      } catch (error) {
        args.$2.send('$error');
        stop();
      }
    });
  }
}
