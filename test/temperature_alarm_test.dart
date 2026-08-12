import 'package:banana_thermal/protocol/temperature_alarm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TemperatureAlarmEvent', () {
    test('parses fixed overheat active packet', () {
      final event = TemperatureAlarmEvent.tryParse('!A,1,H,1,+0850\n');
      expect(event, isNotNull);
      expect(event!.kind, TemperatureAlarmKind.high);
      expect(event.active, isTrue);
      expect(event.temperature, 85.0);
    });

    test('parses signed overcool clear packet', () {
      final event = TemperatureAlarmEvent.tryParse('!A,1,L,0,-0050');
      expect(event, isNotNull);
      expect(event!.kind, TemperatureAlarmKind.low);
      expect(event.active, isFalse);
      expect(event.temperature, -5.0);
    });

    test('serializes the fixed line for host-to-buzzer forwarding', () {
      expect(
        const TemperatureAlarmEvent(
          kind: TemperatureAlarmKind.high,
          active: true,
          temperature: 85,
        ).toWireLine(),
        '!A,1,H,1,+0850\n',
      );
      expect(
        const TemperatureAlarmEvent(
          kind: TemperatureAlarmKind.low,
          active: false,
          temperature: -5,
        ).toWireLine(),
        '!A,1,L,0,-0050\n',
      );
    });

    test('rejects unknown versions and malformed fields', () {
      expect(TemperatureAlarmEvent.tryParse('!A,2,H,1,+0850'), isNull);
      expect(TemperatureAlarmEvent.tryParse('!A,1,X,1,+0850'), isNull);
      expect(TemperatureAlarmEvent.tryParse('!A,1,H,2,+0850'), isNull);
      expect(TemperatureAlarmEvent.tryParse('BEGIN'), isNull);
    });
  });

  group('TemperatureAlarmConfig', () {
    const response = <String, dynamic>{
      'type': 'temperature_alarm',
      'version': 1,
      'ok': true,
      'operation': 'get',
      'persisted': true,
      'master': true,
      'highEnabled': true,
      'highThreshold': 60.0,
      'lowEnabled': true,
      'lowThreshold': 0.0,
      'highHysteresis': 2.0,
      'lowHysteresis': 1.5,
      'triggerDelayMs': 500,
      'clearDelayMs': 1000,
      'latched': false,
      'repeatMs': 1000,
      'highActive': false,
      'lowActive': true,
    };

    test('parses complete firmware response', () {
      final config = TemperatureAlarmConfig.tryParse(response);
      expect(config, isNotNull);
      expect(config!.masterEnabled, isTrue);
      expect(config.highThreshold, 60.0);
      expect(config.lowHysteresis, 1.5);
      expect(config.lowActive, isTrue);
      expect(config.persisted, isTrue);
    });

    test('serializes positional set command exactly', () {
      final config = TemperatureAlarmConfig.tryParse(response)!;
      expect(
        config.toSetCommand(),
        'alarm set 1 1 60.0 1 0.0 2.0 1.5 500 1000 0 1000',
      );
    });

    test('rejects overlapping thresholds and invalid repeat interval', () {
      const overlap = TemperatureAlarmConfig(
        highThreshold: 10,
        lowThreshold: 10,
      );
      expect(overlap.validationError, isNotNull);
      expect(overlap.toSetCommand, throwsArgumentError);

      const tooFast = TemperatureAlarmConfig(repeatMs: 100);
      expect(tooFast.validationError, isNotNull);
    });

    test('rejects error or incomplete JSON responses', () {
      expect(
        TemperatureAlarmConfig.tryParse({
          ...response,
          'ok': false,
          'error': 'invalid parameters',
        }),
        isNull,
      );
      expect(
        TemperatureAlarmConfig.tryParse({...response}..remove('repeatMs')),
        isNull,
      );
    });
  });
}
