/// Windows 端: "夜间模式" 与应用主题的同步提示弹窗.
///
/// 触发条件:
///   1. 启动时一次性检查 — 当 [appThemeMode]==system, 且
///      Windows 应用模式与夜间模式不一致 (深+开/浅+关 为一致),
///      弹窗询问用户是否切换应用主题以对齐夜间模式.
///   2. 运行中 — 当 [appThemeMode]==system 且夜间模式开关被切换时,
///      弹窗询问是否同步切换应用主题.
///
/// 用户点 "切换" 会把 [appThemeMode] 设为 ThemeMode.dark/light
/// (随之退出跟随系统). "不切换" 仅关闭弹窗.
///
/// 仅 Windows 平台启用; 其它端此组件等价于透传 child.
library;

import 'dart:io' show Platform;
import 'package:flutter/material.dart';

import '../main.dart' show appThemeMode;
import 'windows_theme_ffi.dart';

class NightLightSyncWatcher extends StatefulWidget {
  final Widget child;
  const NightLightSyncWatcher({super.key, required this.child});

  @override
  State<NightLightSyncWatcher> createState() => _NightLightSyncWatcherState();
}

class _NightLightSyncWatcherState extends State<NightLightSyncWatcher> {
  bool? _prevNightLight;
  bool _startupChecked = false;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    _prevNightLight = windowsNightLightOn.value;
    windowsNightLightOn.addListener(_onNightLightChanged);
    windowsSystemBrightness.addListener(_tryStartupCheck);
    // 首帧后尝试启动一致性检查 (此时 FFI 已读过一次).
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryStartupCheck());
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowsNightLightOn.removeListener(_onNightLightChanged);
      windowsSystemBrightness.removeListener(_tryStartupCheck);
    }
    super.dispose();
  }

  // 启动一致性检查: 仅执行一次, 需两个值都已就绪.
  void _tryStartupCheck() {
    if (_startupChecked) return;
    if (!Platform.isWindows) return;
    final b = windowsSystemBrightness.value;
    final n = windowsNightLightOn.value;
    if (b == null || n == null) return;
    _startupChecked = true;
    _prevNightLight = n;
    if (appThemeMode.value != ThemeMode.system) return;
    final consistent = (b == Brightness.dark && n) ||
        (b == Brightness.light && !n);
    if (consistent) return;
    _showSyncDialog(
      nightLightOn: n,
      title: '主题与夜间模式不一致',
      body: n
          ? '当前 Windows 应用模式为浅色, 但夜间模式已开启.\n'
              '是否将应用切换为深色主题?'
          : '当前 Windows 应用模式为深色, 但夜间模式未开启.\n'
              '是否将应用切换为浅色主题?',
    );
  }

  void _onNightLightChanged() {
    if (!Platform.isWindows) return;
    final n = windowsNightLightOn.value;
    final prev = _prevNightLight;
    _prevNightLight = n;
    if (n == null || prev == null || n == prev) return;
    // 仅在 "跟随系统" 模式下提示.
    if (appThemeMode.value != ThemeMode.system) return;
    _showSyncDialog(
      nightLightOn: n,
      title: n ? '夜间模式已开启' : '夜间模式已关闭',
      body: n
          ? '是否将应用主题切换为深色?'
          : '是否将应用主题切换为浅色?',
    );
  }

  Future<void> _showSyncDialog({
    required bool nightLightOn,
    required String title,
    required String body,
  }) async {
    if (_dialogOpen) return;
    if (!mounted) return;
    _dialogOpen = true;
    try {
      final ctx = context;
      final res = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('不切换'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('切换'),
            ),
          ],
        ),
      );
      if (res == true) {
        appThemeMode.value =
            nightLightOn ? ThemeMode.dark : ThemeMode.light;
      }
    } finally {
      _dialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
