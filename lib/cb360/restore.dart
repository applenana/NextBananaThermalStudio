import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'context_keys.dart';

typedef _Native =
    Int32 Function(
      Pointer<Int16>,
      Pointer<Uint16>,
      Pointer<Int32>,
      Int32,
      Pointer<Uint8>,
      Pointer<Int16>,
    );
typedef _Restore =
    int Function(
      Pointer<Int16>,
      Pointer<Uint16>,
      Pointer<Int32>,
      int,
      Pointer<Uint8>,
      Pointer<Int16>,
    );

class RestoredPhoto {
  final Uint8List bmp;
  final Int16List centiC;
  RestoredPhoto(this.bmp, this.centiC);
}

/// Called in a worker isolate. Uses the firmware's exact integer arithmetic.
RestoredPhoto restorePhoto(
  Uint8List y16,
  Uint8List curve,
  Map<String, dynamic> context,
) {
  if (y16.length != 21600 || curve.length != 1200) {
    throw const FormatException('照片或曲线长度错误');
  }
  final lib = DynamicLibrary.open(
    Platform.environment['CB360_RESTORE_LIBRARY'] ??
        (Platform.isWindows
            ? '${File(Platform.resolvedExecutable).parent.path}/cb360_restore.dll'
            : 'libcb360_restore.so'),
  );
  final restore = lib.lookupFunction<_Native, _Restore>('cb360_restore');
  final pixels = calloc<Int16>(10800), selected = calloc<Uint16>(600);
  final values = calloc<Int32>(contextKeys.length);
  final bmp = calloc<Uint8>(230454), temperatures = calloc<Int16>(10800);
  try {
    final y = ByteData.sublistView(y16), c = ByteData.sublistView(curve);
    for (var i = 0; i < 10800; i++) {
      pixels[i] = y.getInt16(i * 2, Endian.little);
    }
    for (var i = 0; i < 600; i++) {
      selected[i] = c.getUint16(i * 2, Endian.little);
    }
    values.asTypedList(contextKeys.length).setAll(0, contextValues(context));
    final result = restore(
      pixels,
      selected,
      values,
      contextKeys.length,
      bmp,
      temperatures,
    );
    if (result != 0) throw StateError('照片还原失败 ($result)，原始数据已保留');
    return RestoredPhoto(
      Uint8List.fromList(bmp.asTypedList(230454)),
      Int16List.fromList(temperatures.asTypedList(10800)),
    );
  } finally {
    calloc.free(pixels);
    calloc.free(selected);
    calloc.free(values);
    calloc.free(bmp);
    calloc.free(temperatures);
  }
}

Int32List contextValues(Map<String, dynamic> context) {
  final values = Int32List(contextKeys.length);
  final settings = context['settings'] as Map;
  final parameters = context['parameters'] as Map;
  final measurements = context['measurements'] as Map;
  final points = measurements['points'] as List;
  final fields = <String, dynamic>{
    ...settings.cast<String, dynamic>(),
    ...parameters.cast<String, dynamic>(),
    'average_reference': context['average_reference'],
    'measurement_mode': measurements['mode'] == 'multiple' ? 1 : 0,
    'measurement_count': points.length,
    'distance_mode': settings['distance_mode'] == 'far' ? 1 : 0,
  };
  if (points.length > 5) throw const FormatException('测点数量错误');
  for (var i = 0; i < 5; i++) {
    fields['point_${i}_x'] = i < points.length ? points[i]['x'] : 0;
    fields['point_${i}_y'] = i < points.length ? points[i]['y'] : 0;
  }
  for (var i = 0; i < contextKeys.length; i++) {
    final v = fields[contextKeys[i]];
    if (v is! int && v is! bool) {
      throw FormatException('参数缺失: ${contextKeys[i]}');
    }
    values[i] = v is bool ? (v ? 1 : 0) : v as int;
  }
  return values;
}

typedef _LutNative =
    Int32 Function(Pointer<Uint16>, Pointer<Int32>, Int32, Pointer<Int16>);
typedef _Lut =
    int Function(Pointer<Uint16>, Pointer<Int32>, int, Pointer<Int16>);

Int16List buildTemperatureLut(Uint8List curve, Map<String, dynamic> context) {
  if (curve.length != 1200) throw const FormatException('曲线长度错误');
  final lib = DynamicLibrary.open(
    Platform.environment['CB360_RESTORE_LIBRARY'] ??
        (Platform.isWindows
            ? '${File(Platform.resolvedExecutable).parent.path}/cb360_restore.dll'
            : 'libcb360_restore.so'),
  );
  final function = lib.lookupFunction<_LutNative, _Lut>(
    'cb360_temperature_lut',
  );
  final selected = calloc<Uint16>(600),
      values = calloc<Int32>(contextKeys.length);
  final output = calloc<Int16>(65536);
  try {
    final bytes = ByteData.sublistView(curve);
    for (var i = 0; i < 600; i++) {
      selected[i] = bytes.getUint16(i * 2, Endian.little);
    }
    values.asTypedList(contextKeys.length).setAll(0, contextValues(context));
    final result = function(selected, values, contextKeys.length, output);
    if (result != 0) throw StateError('温度换算表生成失败 ($result)');
    return Int16List.fromList(output.asTypedList(65536));
  } finally {
    calloc.free(selected);
    calloc.free(values);
    calloc.free(output);
  }
}

Float32List convertY16Temperatures(Uint8List pixels, Int16List lut) {
  if (pixels.length != 21600 || lut.length != 65536) {
    throw const FormatException('温度帧尺寸错误');
  }
  final bytes = ByteData.sublistView(pixels);
  final temperatures = Float32List(10800);
  for (var i = 0; i < 10800; i++) {
    temperatures[i] = lut[bytes.getInt16(i * 2, Endian.little) + 32768] / 100.0;
  }
  return temperatures;
}
