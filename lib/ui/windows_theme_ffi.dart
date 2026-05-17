/// Windows 系统外观状态读取 (通过 dart:ffi 直接读注册表).
///
/// 暴露两个 [ValueNotifier]:
///   1. [windowsSystemBrightness]  — "应用模式" 深 / 浅
///      路径: HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize
///      值名: AppsUseLightTheme (REG_DWORD, 1=light, 0=dark)
///
///   2. [windowsNightLightOn]      — "夜间模式" 开 / 关
///      路径: HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\
///            DefaultAccount\Current\
///            default$windows.data.bluelightreduction.bluelightreductionstate\
///            windows.data.bluelightreduction.bluelightreductionstate
///      值名: Data (REG_BINARY)
///      判定: 如 BLOB 里包含字节序列 10 00 00 00 02 00 00 00 (社区共识标记),
///            视为 ON, 否则 OFF.
///
/// 背景: Flutter Windows embedder 在部分 Windows 10 LTSC 上读取
/// PlatformDispatcher.platformBrightness 不可靠, ThemeMode.system 失效;
/// 同时夜间模式 Flutter 根本不感知, 这里都自己读, 2 秒轮询.
///
/// 非 Windows 平台: 两个 notifier 始终为 null, 不启动 timer.
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
const int _rrfRtRegBinary = 0x00000008;

/// Windows "应用模式" 亮度. 仅 Windows 有效, 其它平台始终 null.
final ValueNotifier<Brightness?> windowsSystemBrightness =
    ValueNotifier<Brightness?>(null);

/// Windows "夜间模式" 状态. true=开启, false=关闭, null=未知/非 Windows.
final ValueNotifier<bool?> windowsNightLightOn = ValueNotifier<bool?>(null);

Timer? _pollTimer;
_RegGetValueWDart? _regGetValueW;

/// 启动监视: 立刻读一次, 然后每 [interval] 轮询. 非 Windows 直接返回.
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
    return;
  }
  _readAll();
  _pollTimer = Timer.periodic(interval, (_) => _readAll());
}

void _readAll() {
  _readAppsUseLightTheme();
  _readNightLight();
}

void _readAppsUseLightTheme() {
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

// 夜间模式 BLOB 内的特征字节序列. 开启时 BLOB 含此 8 字节.
const List<int> _kNightLightOnMarker = [
  0x10, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
];

void _readNightLight() {
  final fn = _regGetValueW;
  if (fn == null) return;
  final sub = ('Software\\Microsoft\\Windows\\CurrentVersion\\CloudStore\\Store'
          '\\DefaultAccount\\Current'
          '\\default\$windows.data.bluelightreduction.bluelightreductionstate'
          '\\windows.data.bluelightreduction.bluelightreductionstate')
      .toNativeUtf16();
  final val = 'Data'.toNativeUtf16();
  final cb = calloc<Uint32>();
  try {
    // 第一次: data=null, 让系统回填所需字节数.
    var status = fn(_hkcu, sub, val, _rrfRtRegBinary, nullptr, nullptr, cb);
    // 0 = ERROR_SUCCESS, 234 = ERROR_MORE_DATA, 均拿到大小.
    if (status != 0 && status != 234) return;
    final size = cb.value;
    if (size == 0 || size > 4096) return;
    final buf = calloc<Uint8>(size);
    cb.value = size;
    try {
      status = fn(_hkcu, sub, val, _rrfRtRegBinary, nullptr,
          buf.cast<Void>(), cb);
      if (status != 0) return;
      final on = _containsMarker(buf, cb.value, _kNightLightOnMarker);
      if (windowsNightLightOn.value != on) {
        windowsNightLightOn.value = on;
      }
    } finally {
      calloc.free(buf);
    }
  } finally {
    calloc.free(sub);
    calloc.free(val);
    calloc.free(cb);
  }
}

bool _containsMarker(Pointer<Uint8> buf, int len, List<int> marker) {
  if (len < marker.length) return false;
  final end = len - marker.length;
  outer:
  for (var i = 0; i <= end; i++) {
    for (var j = 0; j < marker.length; j++) {
      if (buf[i + j] != marker[j]) continue outer;
    }
    return true;
  }
  return false;
}
