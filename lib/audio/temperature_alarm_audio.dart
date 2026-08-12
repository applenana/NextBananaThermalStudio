library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TemperatureAlarmSound {
  urgent('urgent', '高强度警报', 'audio/urgent_alarm.wav'),
  dualBeep('dual_beep', '双音蜂鸣', 'audio/dual_beep.wav'),
  slowPulse('slow_pulse', '缓速脉冲', 'audio/slow_pulse.wav'),
  silent('silent', '静音（仅视觉提示）', null);

  const TemperatureAlarmSound(this.id, this.label, this.assetPath);

  final String id;
  final String label;
  final String? assetPath;

  static TemperatureAlarmSound fromId(String? id) => values.firstWhere(
    (sound) => sound.id == id,
    orElse: () => TemperatureAlarmSound.urgent,
  );
}

class TemperatureAlarmAudioController {
  static const _soundPreferenceKey = 'temperature_alarm_sound';
  static const _volumePreferenceKey = 'temperature_alarm_volume';
  static const defaultSound = TemperatureAlarmSound.urgent;

  /// Deliberately louder than the former OS one-shot notification sound.
  static const defaultVolume = 1.0;

  static final AudioContext _alarmAudioContext = AudioContext(
    android: const AudioContextAndroid(
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gainTransient,
    ),
  );

  AudioPlayer? _alarmPlayer;
  AudioPlayer? _previewPlayer;
  SharedPreferences? _preferences;
  Future<void>? _initialization;
  int _syncGeneration = 0;
  bool _requestedActive = false;
  TemperatureAlarmSound? _playingSound;

  TemperatureAlarmSound sound = defaultSound;
  double volume = defaultVolume;
  bool ready = false;
  String? lastError;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      sound = TemperatureAlarmSound.fromId(
        _preferences?.getString(_soundPreferenceKey),
      );
      final savedVolume = _preferences?.getDouble(_volumePreferenceKey);
      if (savedVolume != null && savedVolume.isFinite) {
        volume = savedVolume.clamp(0.0, 1.0);
      }

      _alarmPlayer = AudioPlayer();
      _previewPlayer = AudioPlayer();
      await Future.wait([
        _alarmPlayer!.setAudioContext(_alarmAudioContext),
        _alarmPlayer!.setReleaseMode(ReleaseMode.loop),
        _alarmPlayer!.setVolume(volume),
        _previewPlayer!.setAudioContext(_alarmAudioContext),
        _previewPlayer!.setReleaseMode(ReleaseMode.stop),
        _previewPlayer!.setVolume(volume),
      ]);
      ready = true;
      lastError = null;
    } catch (error) {
      ready = false;
      lastError = '报警音频初始化失败：$error';
    }
  }

  Future<void> setSound(TemperatureAlarmSound value) async {
    await initialize();
    sound = value;
    await _preferences?.setString(_soundPreferenceKey, value.id);
    await _previewPlayer?.stop();
    if (_requestedActive) {
      await syncAlarm(active: true, forceRestart: true);
    }
  }

  Future<void> setVolume(double value, {bool persist = true}) async {
    final safeVolume = value.isFinite ? value.clamp(0.0, 1.0) : defaultVolume;
    await initialize();
    volume = safeVolume;
    try {
      await Future.wait([
        if (_alarmPlayer != null) _alarmPlayer!.setVolume(volume),
        if (_previewPlayer != null) _previewPlayer!.setVolume(volume),
      ]);
      if (persist) {
        await _preferences?.setDouble(_volumePreferenceKey, volume);
      }
      lastError = null;
    } catch (error) {
      lastError = '报警音量设置失败：$error';
      rethrow;
    }
  }

  Future<void> preview() async {
    await initialize();
    final assetPath = sound.assetPath;
    if (!ready || assetPath == null || _previewPlayer == null) return;
    try {
      await _previewPlayer!.stop();
      await _previewPlayer!.setReleaseMode(ReleaseMode.stop);
      await _previewPlayer!.play(
        AssetSource(assetPath),
        volume: volume,
        ctx: _alarmAudioContext,
      );
      lastError = null;
    } catch (error) {
      lastError = '报警音效试听失败：$error';
      rethrow;
    }
  }

  Future<void> resetSettings() async {
    await initialize();
    sound = defaultSound;
    volume = defaultVolume;
    await Future.wait([
      if (_preferences != null) _preferences!.remove(_soundPreferenceKey),
      if (_preferences != null) _preferences!.remove(_volumePreferenceKey),
      if (_alarmPlayer != null) _alarmPlayer!.setVolume(volume),
      if (_previewPlayer != null) _previewPlayer!.setVolume(volume),
      if (_previewPlayer != null) _previewPlayer!.stop(),
    ]);
    if (_requestedActive) {
      await syncAlarm(active: true, forceRestart: true);
    }
  }

  Future<void> syncAlarm({
    required bool active,
    bool forceRestart = false,
  }) async {
    _requestedActive = active;
    final generation = ++_syncGeneration;
    await initialize();
    final player = _alarmPlayer;
    if (!ready || player == null) return;

    final assetPath = sound.assetPath;
    if (!active || assetPath == null || volume <= 0) {
      _playingSound = null;
      await player.stop();
      return;
    }
    if (!forceRestart &&
        _playingSound == sound &&
        player.state == PlayerState.playing) {
      await player.setVolume(volume);
      return;
    }

    try {
      await player.stop();
      if (generation != _syncGeneration || !_requestedActive) return;
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(
        AssetSource(assetPath),
        volume: volume,
        ctx: _alarmAudioContext,
      );
      if (generation != _syncGeneration || !_requestedActive) {
        await player.stop();
        return;
      }
      _playingSound = sound;
      lastError = null;
    } catch (error) {
      _playingSound = null;
      lastError = '报警音效播放失败：$error';
    }
  }

  Future<void> dispose() async {
    _syncGeneration++;
    _requestedActive = false;
    await _alarmPlayer?.dispose();
    await _previewPlayer?.dispose();
    _alarmPlayer = null;
    _previewPlayer = null;
  }
}
