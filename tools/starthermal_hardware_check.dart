// Read-only hardware acceptance: same API, BP64 decoder and native temperature
// implementation as the app. Never deletes device photos or flashes firmware.
// Set LIBSERIALPORT_PATH and STARTHERMAL_RESTORE_LIBRARY to the built Windows DLLs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
// Standalone diagnostic uses the same transitive serial driver as Flutter.
import 'package:libserialport/libserialport.dart';
import 'package:image/image.dart' as img;
import 'package:banana_thermal/starthermal/client.dart';
import 'package:banana_thermal/starthermal/protocol.dart';
import 'package:banana_thermal/starthermal/restore.dart';
import 'package:banana_thermal/starthermal/temperature_context.dart';
import 'package:banana_thermal/serial/windows_rx_buffer.dart';
import 'package:banana_thermal/serial/desktop_serial_reader.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError(
      'Usage: dart run tools/starthermal_hardware_check.dart COM144',
    );
  }
  final port = SerialPort(args.first);
  if (!port.openReadWrite()) throw StateError('Cannot open ${args.first}');
  final config = SerialPortConfig()
    ..baudRate = 2000000
    ..bits = 8
    ..stopBits = 1
    ..parity = SerialPortParity.none
    ..setFlowControl(SerialPortFlowControl.none)
    ..dtr = SerialPortDtr.on
    ..rts = SerialPortRts.on;
  port.config = config;
  configureWindowsRxBuffer(port.address);
  final parser = Y16Parser('BP64');
  Uint8List? latest;
  Int16List? lut;
  Float32List? temperatures;
  var converted = 0;
  var hostBaud = 2000000;
  DesktopSerialReader? reader;
  StreamSubscription<Uint8List>? subscription;
  late StarThermalClient client;
  client = StarThermalClient(
    baud: 2000000,
    write: (line) async {
      final bytes = Uint8List.fromList(ascii.encode(line));
      if (port.write(bytes, timeout: 1000) != bytes.length) {
        throw StateError('Short write');
      }
    },
    setHostBaud: (baud) async {
      if (baud == hostBaud) return;
      hostBaud = baud;
      await subscription?.cancel();
      await reader?.close();
      final cfg = port.config;
      cfg.baudRate = baud;
      port.config = cfg;
      reader = await DesktopSerialReader.open(port.address);
      subscription = reader!.stream.listen(client.feed);
    },
    onStream: (bytes) {
      final decoded = parser.add(bytes);
      if (decoded == null) return;
      latest = decoded;
      if (lut != null) {
        temperatures = convertY16Temperatures(decoded, lut);
        converted++;
      }
    },
  );
  reader = await DesktopSerialReader.open(port.address);
  subscription = reader!.stream.listen(client.feed);
  Timer? heartbeat;
  final folder = await Directory(
    'build/starthermal-hardware-check',
  ).create(recursive: true);
  try {
    Map<String, dynamic>? info;
    for (final rate in [2000000, 115200, 921600]) {
      await client.setHostBaud(rate);
      client.baud = rate;
      await client.write('StopY16Stream\n');
      await client.drain();
      try {
        info = (await client.once('GetSysInfo')).object;
        break;
      } catch (_) {}
    }
    if (info == null) throw StateError('No StarThermal response');
    stdout.writeln(
      'Connected ${info['thermalModuleSerialNumber']} at ${client.baud}',
    );
    stdout.writeln(jsonEncode(info));
    for (var wait = 0; info!['nucReady'] != true && wait < 15; wait++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      info = (await client.once('GetSysInfo')).object;
    }
    await client.changeBaud(2000000);
    await client.begin();
    late Map<String, dynamic> snapshot;
    var photos = 0;
    final downloadClock = Stopwatch()..start();
    try {
      info = (await client.request('GetSysInfo')).object;
      final curves = await client.request('GetCurves');
      validateCurves(
        curves.object,
        curves.binary,
        info['curvesCrc32'] as String,
      );
      final nuc = await client.request('GetNucData');
      final parameters = (await client.request('GetSensorParams')).object;
      if (parameters['sequence'] != nuc.object['sequence']) {
        throw StateError('Inconsistent context');
      }
      final settings = (await client.request('GetSettings')).object;
      snapshot = {
        'device': info,
        'curves': curves.object,
        'curves_binary': base64Encode(curves.binary),
        'average_reference': nuc.object['average_reference'],
        'parameters': parameters,
        'settings': settings['settings'],
        'measurements': settings['measurements'],
      };
      final list = (await client.request('GetPicList')).json as List;
      for (final item in list) {
        final id = item['id'];
        final r = await client.request('GetPicWithID $id');
        final index = r.object['curve_index'] as int;
        final offset =
            index * 2400 +
            (settings['settings']['distance_mode'] == 'far' ? 1200 : 0);
        final curve = Uint8List.sublistView(
          curves.binary,
          offset,
          offset + 1200,
        );
        final restored = restorePhoto(r.binary, curve, snapshot);
        final lookup = buildTemperatureLut(curve, snapshot);
        final streamed = convertY16Temperatures(r.binary, lookup);
        for (var i = 0; i < 10800; i++) {
          if ((streamed[i] * 100).round() != restored.centiC[i]) {
            throw StateError('Temperature mismatch at $i');
          }
        }
        await File(
          '${folder.path}/$id.png',
        ).writeAsBytes(img.encodePng(img.decodeBmp(restored.bmp)!));
        photos++;
      }
    } finally {
      await client.end();
    }
    final downloadSeconds = downloadClock.elapsedMilliseconds / 1000;
    final choice = LiveCurveSelection().select(snapshot);
    lut = buildTemperatureLut(choice.curve, choice.context);
    await client.once('StartY16Stream BP64');
    heartbeat = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(client.write('Y16KeepAlive\n')),
    );
    final clock = Stopwatch()..start();
    await Future<void>.delayed(const Duration(seconds: 20));
    heartbeat.cancel();
    heartbeat = null;
    await client.stop();
    if (converted == 0 || latest == null || temperatures == null) {
      throw StateError('No temperature frames');
    }
    await File('${folder.path}/last.y16').writeAsBytes(latest!);
    var min = double.infinity, max = double.negativeInfinity;
    for (final value in temperatures!) {
      if (value < min) min = value;
      if (value > max) max = value;
    }
    final image = img.Image(width: 120, height: 90);
    for (var i = 0; i < 10800; i++) {
      final gray = ((temperatures![i] - min) / (max - min) * 255).round().clamp(
        0,
        255,
      );
      image.setPixelRgb(i % 120, i ~/ 120, gray, gray, gray);
    }
    await File(
      '${folder.path}/last-temperature.png',
    ).writeAsBytes(img.encodePng(image));
    final result = {
      'serial': info['thermalModuleSerialNumber'],
      'baud': client.baud,
      'photos': photos,
      'photoDownloadAndRestoreSeconds': downloadSeconds,
      'frames': parser.frames,
      'convertedFrames': converted,
      'crcErrors': parser.errors,
      'fps': parser.frames / (clock.elapsedMilliseconds / 1000),
      'curveIndex': choice.index,
      'minimumC': min,
      'maximumC': max,
      'retries': client.retries,
    };
    await File(
      '${folder.path}/result.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    stdout.writeln(jsonEncode(result));
  } finally {
    heartbeat?.cancel();
    try {
      if (client.streaming) await client.stop();
      await client.end();
      await client.changeBaud(115200);
    } catch (_) {}
    client.close();
    await subscription?.cancel();
    await reader?.close();
    port.close();
  }
}
