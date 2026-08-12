library;

enum TemperatureAlarmKind { high, low }

/// Fixed, MCU-friendly event line emitted by firmware:
/// `!A,1,H,1,+0850` (kind H/L, state 1/0, temperature in 0.1 °C).
class TemperatureAlarmEvent {
  final TemperatureAlarmKind kind;
  final bool active;
  final double temperature;

  const TemperatureAlarmEvent({
    required this.kind,
    required this.active,
    required this.temperature,
  });

  /// Serialize the exact fixed-width line understood by the firmware and the
  /// dedicated buzzer MCU. Keeping one encoder prevents host forwarding from
  /// drifting away from the device protocol.
  String toWireLine() {
    final deci = (temperature * 10).round().clamp(-9999, 9999);
    final signed = deci < 0
        ? '-${(-deci).toString().padLeft(4, '0')}'
        : '+${deci.toString().padLeft(4, '0')}';
    return '!A,1,${kind == TemperatureAlarmKind.high ? 'H' : 'L'},'
        '${active ? 1 : 0},$signed\n';
  }

  static TemperatureAlarmEvent? tryParse(String line) {
    final text = line.trim();
    final parts = text.split(',');
    if (parts.length != 5 || parts[0] != '!A' || parts[1] != '1') {
      return null;
    }
    final kind = switch (parts[2]) {
      'H' => TemperatureAlarmKind.high,
      'L' => TemperatureAlarmKind.low,
      _ => null,
    };
    final active = switch (parts[3]) {
      '1' => true,
      '0' => false,
      _ => null,
    };
    final deci = int.tryParse(parts[4]);
    if (kind == null || active == null || deci == null) return null;
    if (deci < -9999 || deci > 9999) return null;
    return TemperatureAlarmEvent(
      kind: kind,
      active: active,
      temperature: deci / 10.0,
    );
  }
}

class TemperatureAlarmConfig {
  static const responseType = 'temperature_alarm';
  static const protocolVersion = 1;
  static const minimumTemperature = -40.0;
  static const maximumTemperature = 300.0;
  static const minimumHysteresis = 0.1;
  static const maximumHysteresis = 20.0;
  static const maximumDelayMs = 10000;
  static const minimumRepeatMs = 250;
  static const maximumRepeatMs = 60000;

  final bool masterEnabled;
  final bool highEnabled;
  final double highThreshold;
  final bool lowEnabled;
  final double lowThreshold;
  final double highHysteresis;
  final double lowHysteresis;
  final int triggerDelayMs;
  final int clearDelayMs;
  final bool latched;
  final int repeatMs;
  final bool highActive;
  final bool lowActive;
  final bool persisted;
  final String operation;

  const TemperatureAlarmConfig({
    this.masterEnabled = false,
    this.highEnabled = false,
    this.highThreshold = 60.0,
    this.lowEnabled = false,
    this.lowThreshold = 0.0,
    this.highHysteresis = 2.0,
    this.lowHysteresis = 2.0,
    this.triggerDelayMs = 500,
    this.clearDelayMs = 1000,
    this.latched = false,
    this.repeatMs = 1000,
    this.highActive = false,
    this.lowActive = false,
    this.persisted = false,
    this.operation = 'local',
  });

  bool get anyActive => highActive || lowActive;

  String? get validationError {
    if (!highThreshold.isFinite ||
        highThreshold < minimumTemperature + 1 ||
        highThreshold > maximumTemperature) {
      return '过热门槛必须在 -39.0 ~ 300.0 °C 之间';
    }
    if (!lowThreshold.isFinite ||
        lowThreshold < minimumTemperature ||
        lowThreshold > maximumTemperature - 1) {
      return '过冷门槛必须在 -40.0 ~ 299.0 °C 之间';
    }
    if (lowThreshold >= highThreshold) return '过冷门槛必须低于过热门槛';
    if (!highHysteresis.isFinite ||
        highHysteresis < minimumHysteresis ||
        highHysteresis > maximumHysteresis ||
        !lowHysteresis.isFinite ||
        lowHysteresis < minimumHysteresis ||
        lowHysteresis > maximumHysteresis) {
      return '迟滞必须在 0.1 ~ 20.0 °C 之间';
    }
    if (triggerDelayMs < 0 || triggerDelayMs > maximumDelayMs) {
      return '触发确认时间必须在 0 ~ 10000 ms 之间';
    }
    if (clearDelayMs < 0 || clearDelayMs > maximumDelayMs) {
      return '恢复确认时间必须在 0 ~ 10000 ms 之间';
    }
    if (repeatMs < 0 ||
        repeatMs > maximumRepeatMs ||
        (repeatMs != 0 && repeatMs < minimumRepeatMs)) {
      return '重复上报必须关闭(0)或在 250 ~ 60000 ms 之间';
    }
    return null;
  }

  String toSetCommand() {
    final error = validationError;
    if (error != null) throw ArgumentError(error);
    return 'alarm set '
        '${masterEnabled ? 1 : 0} '
        '${highEnabled ? 1 : 0} ${highThreshold.toStringAsFixed(1)} '
        '${lowEnabled ? 1 : 0} ${lowThreshold.toStringAsFixed(1)} '
        '${highHysteresis.toStringAsFixed(1)} '
        '${lowHysteresis.toStringAsFixed(1)} '
        '$triggerDelayMs $clearDelayMs ${latched ? 1 : 0} $repeatMs';
  }

  TemperatureAlarmConfig copyWith({
    bool? masterEnabled,
    bool? highEnabled,
    double? highThreshold,
    bool? lowEnabled,
    double? lowThreshold,
    double? highHysteresis,
    double? lowHysteresis,
    int? triggerDelayMs,
    int? clearDelayMs,
    bool? latched,
    int? repeatMs,
    bool? highActive,
    bool? lowActive,
    bool? persisted,
    String? operation,
  }) => TemperatureAlarmConfig(
    masterEnabled: masterEnabled ?? this.masterEnabled,
    highEnabled: highEnabled ?? this.highEnabled,
    highThreshold: highThreshold ?? this.highThreshold,
    lowEnabled: lowEnabled ?? this.lowEnabled,
    lowThreshold: lowThreshold ?? this.lowThreshold,
    highHysteresis: highHysteresis ?? this.highHysteresis,
    lowHysteresis: lowHysteresis ?? this.lowHysteresis,
    triggerDelayMs: triggerDelayMs ?? this.triggerDelayMs,
    clearDelayMs: clearDelayMs ?? this.clearDelayMs,
    latched: latched ?? this.latched,
    repeatMs: repeatMs ?? this.repeatMs,
    highActive: highActive ?? this.highActive,
    lowActive: lowActive ?? this.lowActive,
    persisted: persisted ?? this.persisted,
    operation: operation ?? this.operation,
  );

  static TemperatureAlarmConfig? tryParse(Map<String, dynamic> json) {
    if (json['type'] != responseType ||
        json['version'] != protocolVersion ||
        json['ok'] != true) {
      return null;
    }
    final highThreshold = (json['highThreshold'] as num?)?.toDouble();
    final lowThreshold = (json['lowThreshold'] as num?)?.toDouble();
    final highHysteresis = (json['highHysteresis'] as num?)?.toDouble();
    final lowHysteresis = (json['lowHysteresis'] as num?)?.toDouble();
    final triggerDelayMs = (json['triggerDelayMs'] as num?)?.toInt();
    final clearDelayMs = (json['clearDelayMs'] as num?)?.toInt();
    final repeatMs = (json['repeatMs'] as num?)?.toInt();
    if (json['master'] is! bool ||
        json['highEnabled'] is! bool ||
        json['lowEnabled'] is! bool ||
        json['latched'] is! bool ||
        json['highActive'] is! bool ||
        json['lowActive'] is! bool ||
        highThreshold == null ||
        lowThreshold == null ||
        highHysteresis == null ||
        lowHysteresis == null ||
        triggerDelayMs == null ||
        clearDelayMs == null ||
        repeatMs == null) {
      return null;
    }
    final result = TemperatureAlarmConfig(
      masterEnabled: json['master'] as bool,
      highEnabled: json['highEnabled'] as bool,
      highThreshold: highThreshold,
      lowEnabled: json['lowEnabled'] as bool,
      lowThreshold: lowThreshold,
      highHysteresis: highHysteresis,
      lowHysteresis: lowHysteresis,
      triggerDelayMs: triggerDelayMs,
      clearDelayMs: clearDelayMs,
      latched: json['latched'] as bool,
      repeatMs: repeatMs,
      highActive: json['highActive'] as bool,
      lowActive: json['lowActive'] as bool,
      persisted: json['persisted'] == true,
      operation: json['operation']?.toString() ?? 'get',
    );
    return result.validationError == null ? result : null;
  }
}
