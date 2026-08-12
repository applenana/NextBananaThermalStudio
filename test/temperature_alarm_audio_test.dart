import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:banana_thermal/audio/temperature_alarm_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('alarm audio defaults to the loud urgent sound', () {
    expect(
      TemperatureAlarmAudioController.defaultSound,
      TemperatureAlarmSound.urgent,
    );
    expect(TemperatureAlarmAudioController.defaultVolume, 1.0);
    expect(
      TemperatureAlarmSound.fromId('unknown'),
      TemperatureAlarmSound.urgent,
    );
    expect(TemperatureAlarmSound.silent.assetPath, isNull);
  });

  for (final sound in TemperatureAlarmSound.values.where(
    (sound) => sound.assetPath != null,
  )) {
    test('${sound.id} is a loud, cross-platform PCM WAV asset', () {
      final file = File('assets/${sound.assetPath}');
      expect(file.existsSync(), isTrue, reason: file.path);
      final bytes = file.readAsBytesSync();
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
      expect(ascii.decode(bytes.sublist(12, 16)), 'fmt ');

      final data = ByteData.sublistView(bytes);
      expect(data.getUint16(20, Endian.little), 1, reason: 'PCM encoding');
      expect(data.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(data.getUint32(24, Endian.little), 22050);
      expect(data.getUint16(34, Endian.little), 16);
      expect(ascii.decode(bytes.sublist(36, 40)), 'data');

      var peak = 0;
      for (var offset = 44; offset + 1 < bytes.length; offset += 2) {
        final sample = data.getInt16(offset, Endian.little).abs();
        if (sample > peak) peak = sample;
      }
      expect(peak, greaterThan(28000), reason: 'default alarm must be loud');
      expect(bytes.length, greaterThan(40000));
    });
  }
}
