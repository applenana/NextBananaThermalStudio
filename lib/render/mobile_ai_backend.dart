import 'dart:ffi';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MobileAiBackend { cpu, gpu }

class MobileAiSettings {
  static bool get supported => Abi.current() == Abi.androidArm64;
  static const key = 'ai.mobile.preferredBackend';
  static final preferred = ValueNotifier(MobileAiBackend.cpu);

  static void load(SharedPreferences prefs) {
    preferred.value = prefs.getString(key) == 'gpu'
        ? MobileAiBackend.gpu
        : MobileAiBackend.cpu;
  }

  static Future<void> select(MobileAiBackend value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, value.name)) throw StateError('无法保存处理器设置');
    preferred.value = value;
  }
}
