import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'protocol.dart';
import 'restore.dart';

class StreamWorker {
  Isolate? _isolate;
  ReceivePort? _receive;
  SendPort? _send;
  Future<void> start(
    Uint8List curve,
    Map<String, dynamic> snapshot,
    void Function(Map<String, dynamic>) onFrame,
  ) async {
    final ready = Completer<void>();
    final receive = _receive = ReceivePort();
    receive.listen((message) {
      if (message is SendPort) {
        _send = message;
        ready.complete();
      } else if (message is Map &&
          message['error'] != null &&
          !ready.isCompleted) {
        ready.completeError(StateError('${message['error']}'));
      } else {
        onFrame((message as Map).cast<String, dynamic>());
        _send?.send('next');
      }
    });
    _isolate = await Isolate.spawn(_entry, (receive.sendPort, curve, snapshot));
    await ready.future.timeout(const Duration(seconds: 10));
  }

  void feed(Uint8List bytes) => _send?.send(bytes);
  void dispose() {
    _isolate?.kill();
    _receive?.close();
    _isolate = null;
    _send = null;
  }
}

void _entry((SendPort, Uint8List, Map<String, dynamic>) args) {
  final output = args.$1;
  try {
    final lut = buildTemperatureLut(args.$2, args.$3);
    final input = ReceivePort();
    final parser = Y16Parser('BP64');
    final clock = Stopwatch()..start();
    Uint8List? latest;
    var awaitingUi = false;
    void publish() {
      if (latest == null || awaitingUi) return;
      final bytes = latest!;
      latest = null;
      awaitingUi = true;
      final temperatures = convertY16Temperatures(bytes, lut);
      var min = double.infinity, max = double.negativeInfinity, sum = 0.0;
      for (final value in temperatures) {
        if (value < min) min = value;
        if (value > max) max = value;
        sum += value;
      }
      output.send({
        'temperatures': temperatures,
        'min': min,
        'max': max,
        'avg': sum / temperatures.length,
        'y16': bytes,
        'frames': parser.frames,
        'errors': parser.errors,
        'fps':
            parser.frames * 1000 / clock.elapsedMilliseconds.clamp(1, 1 << 40),
        'ratio': parser.frames * 21600 / parser.payloadBytes.clamp(1, 1 << 40),
      });
    }

    output.send(input.sendPort);
    input.listen((message) {
      if (message == 'next') {
        awaitingUi = false;
      } else {
        latest = parser.add(message as Uint8List) ?? latest;
      }
      publish();
    });
  } catch (e) {
    output.send({'error': '$e'});
  }
}
