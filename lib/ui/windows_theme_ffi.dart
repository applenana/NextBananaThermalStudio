/// 通过 dart:ffi 直接读注册表 HKCU\Software\Microsoft\Windows\CurrentVersion\
/// Themes\Personalize\AppsUseLightTheme, 判断 Windows 当前 "应用模式" 是否深色.
///
/// 背景: Flutter Windows embedder 在部分 Windows 10 LTSC 上读取
/// PlatformDispatcher.platformBrightness 不可靠 (始终返回 light), 导致
/// MaterialApp 的 ThemeMode.system 失效. 这里跳过 embedder, 自己读注册表,
/// 用 ValueNotifier 暴露给上层 + 2 秒轮询触发更新.
///
/// 非 Windows 平台: notifier 永远为 null, 不启动 timer, 不加载 advapi32.dll.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:flutter/widgets.dart' show Brightness, ValueNotifier;
import 'package:ffi/ffi.dart';

// LSTATUS RegGetValueW(HKEY hkey, LPCWSTR subKey, LPCWSTR value,
//                      DWORD flags, LPDWORD type, PVOID data, LPDWORD cbData)
typedef _RegGetValueWNative = Int32 Function(
    IntPtr hkey,
    Pointer<Utf16> subKey,
    Pointer<Utf16> value,
    Uint32 flags,
    Pointer<Uint32> type,
    Pointer<Void> data,
    Pointer<Uint32> cbData);
typedef _RegGetValueWDart = int Function(
    int hkey,
    Pointer<Utf16> subKey,
    Pointer<Utf16> value,
    int flags,
    Pointer<Uint32> type,
    Pointer<Void> data,
    Pointer<Uint32> cbData);

const int _hkcu = 0x80000001;
const int _rrfRtRegDword = 0x00000010;

/// Windows 系统当前 "应用模式" 亮度. 仅 Windows 有效, 其它平台始终为 null.
/// UI 层在 ThemeMode.system 时优先用这个值替代 PlatformDispatcher.
final ValueNotifier<Brightness?> windowsSystemBrightness =
    ValueNotifier<Brightness?>(null);

Timer? _pollTimer;
_RegGetValueWDart? _regGetValueW;

/// 启动监视: 立刻读一次注册表, 然后每 [interval] 轮询一次.
/// 在 main() 初始化阶段调用一次即可. 非 Windows 直接返回.
void startWindowsBrightnessWatcher({
  Duration interval = const Duration(seconds: 2),
}) {
  if (!Platform.isWindows) return;
  if (_pollTimer != null) return;
  try {
    final advapi = DynamicLibrary.open('advapi32.dll');
    _regGetValueW = advapi
        .lookupFunction<_RegGetValueWNative, _RegGetValueWDart>('RegGetValueW');
  } catch (_) {
    return; // 找不到就放弃, 上层会回落到 PlatformDispatcher.
  }
  _readOnce();
  _pollTimer = Timer.periodic(interval, (_) => _readOnce());
}

void _readOnce() {
  final fn = _regGetValueW;
  if (fn == null) return;
  final sub = 'Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize'
      .toNativeUtf16();
  final val = 'AppsUseLightTheme'.toNativeUtf16();
  final data = calloc<Uint32>();
  final cb = calloc<Uint32>()..value = 4;
  try {
    final status = fn(_hkcu, sub, val, _rrfRtRegDword, nullptr,
        data.cast<Void>(), cb);
    if (status == 0) {
      // AppsUseLightTheme: 1 = light, 0 = dark.
      final b = data.value == 0 ? Brightness.dark : Brightness.light;
      if (windowsSystemBrightness.value != b) {
        windowsSystemBrightness.value = b;
      }
    }
  } finally {
    calloc.free(sub);
    calloc.free(val);
    calloc.free(data);
    calloc.free(cb);
  }
}
