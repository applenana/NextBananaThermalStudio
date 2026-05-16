import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io' show Platform;

import 'app_state.dart';
import 'ui/home_shell.dart';
import 'ui/window_size_ffi.dart';

// ====================================================================
// 全局设置: 默认值 + ValueNotifier + 持久化键
// 所有用户可调设置统一在这里管理, 入口处一次性加载, 监听器自动保存.
// ====================================================================

// 默认跟随系统深浅: 桌面/Android 均以系统设定为准, 用户在设置页可改.
const ThemeMode _defaultThemeMode = ThemeMode.system;
const double _defaultUiScale = 1.0;
const double _defaultWideBreakpoint = 800;
const bool _defaultConsoleExpanded = true;
const int _defaultWindowW = 1280;
const int _defaultWindowH = 820;

const String _kThemeMode = 'theme_mode'; // int: 0 system / 1 light / 2 dark
const String _kUiScale = 'ui_scale';
const String _kWideBreakpoint = 'wide_breakpoint';
const String _kConsoleExpanded = 'console_expanded';
const String _kPhotoDownloadDir = 'photo_download_dir';
const String _kWindowW = 'window_w';
const String _kWindowH = 'window_h';

/// 全局主题模式. 在 Header 的切换按钮里直接读写.
final ValueNotifier<ThemeMode> appThemeMode =
    ValueNotifier<ThemeMode>(_defaultThemeMode);

/// UI 缩放比例 (主要影响字体, 0.8 ~ 1.6).
final ValueNotifier<double> appUiScale = ValueNotifier<double>(_defaultUiScale);

/// 实时 Tab 宽屏 / 窄屏切换阈值.
final ValueNotifier<double> appWideBreakpoint =
    ValueNotifier<double>(_defaultWideBreakpoint);

/// 串口控制台展开 / 折叠.
final ValueNotifier<bool> appConsoleExpanded =
    ValueNotifier<bool>(_defaultConsoleExpanded);

/// 串口连接栏 (ConnectionBar) 展开 / 折叠 — 仅 Android 有折叠 UI.
/// 桌面上该物不起作用, ConnectionBar 总是完整呈现.
final ValueNotifier<bool> appConnectionBarExpanded =
    ValueNotifier<bool>(true);

/// 图库 Tab 是否处于"详情页"状态 (仅 Android 窄屏 list↔detail 切换时使用).
/// 用于让 Android 系统返回键能优先关闭详情页, 由 [PhotoDownloadTab] 维护.
final ValueNotifier<bool> appPhotoDetailOpen = ValueNotifier<bool>(false);

/// 当前是否激活图库 tab. true=用户停留在图库, false=已切走或从未进入.
/// 由 HomeShell._select 维护. PhotoTab._refresh 在重试循环里读取此值,
/// 一旦切走立即终止后续重试 (避免与 HomeShell 恢复推流的逻辑冲突).
final ValueNotifier<bool> appPhotoTabActive = ValueNotifier<bool>(false);

/// Android 返回键请求关闭图库详情的回调. 由 PhotoDownloadTab 在 initState
/// 内注册, dispose 内置 null. home_shell 拦截返回键时调用此回调.
VoidCallback? appClosePhotoDetail;

/// 图库文件下载根目录. null 表示用默认 `<Documents>/BananaThermalStudio`.
final ValueNotifier<String?> appPhotoDownloadDir =
    ValueNotifier<String?>(null);

SharedPreferences? _prefs;

/// 持久化下载路径. 传 null 清除 (恢复默认).
Future<void> setPhotoDownloadDir(String? path) async {
  appPhotoDownloadDir.value = path;
  final prefs = _prefs ?? await SharedPreferences.getInstance();
  if (path == null || path.isEmpty) {
    await prefs.remove(_kPhotoDownloadDir);
  } else {
    await prefs.setString(_kPhotoDownloadDir, path);
  }
}

/// 持久化窗口尺寸 + 实际调整窗口.
/// 仅桌面 (Windows) 有效, 移动端忽略.
Future<void> setWindowSizePersist(int w, int h) async {
  if (!Platform.isWindows) return;
  WindowSizeFfi.instance.setSize(w, h);
  final prefs = _prefs ?? await SharedPreferences.getInstance();
  await prefs.setInt(_kWindowW, w);
  await prefs.setInt(_kWindowH, h);
}

/// 启动时一次性加载所有持久化项, 然后给 notifier 绑定自动写回.
Future<void> _loadPersistedSettings() async {
  final prefs = await SharedPreferences.getInstance();
  _prefs = prefs;

  // ThemeMode
  final tm = prefs.getInt(_kThemeMode);
  if (tm != null && tm >= 0 && tm <= 2) {
    appThemeMode.value = ThemeMode.values[tm];
  }

  // UI scale
  final us = prefs.getDouble(_kUiScale);
  if (us != null && us >= 0.5 && us <= 2.5) {
    appUiScale.value = us;
  }

  // 响应式断点
  final wb = prefs.getDouble(_kWideBreakpoint);
  if (wb != null && wb >= 400 && wb <= 3000) {
    appWideBreakpoint.value = wb;
  }

  // 控制台展开
  final ce = prefs.getBool(_kConsoleExpanded);
  if (ce != null) appConsoleExpanded.value = ce;

  // 下载路径
  final pd = prefs.getString(_kPhotoDownloadDir);
  if (pd != null && pd.isNotEmpty) appPhotoDownloadDir.value = pd;

  // 窗口尺寸 (启动时尝试还原, 仅桌面)
  if (Platform.isWindows) {
    final ww = prefs.getInt(_kWindowW);
    final wh = prefs.getInt(_kWindowH);
    if (ww != null && wh != null && ww >= 600 && wh >= 400) {
      // 推迟一帧让 native window 完成初始化再 resize.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          WindowSizeFfi.instance.setSize(ww, wh);
        } catch (_) {}
      });
    }
  }

  // 自动持久化监听
  appThemeMode.addListener(() {
    _prefs?.setInt(_kThemeMode, appThemeMode.value.index);
  });
  appUiScale.addListener(() {
    _prefs?.setDouble(_kUiScale, appUiScale.value);
  });
  appWideBreakpoint.addListener(() {
    _prefs?.setDouble(_kWideBreakpoint, appWideBreakpoint.value);
  });
  appConsoleExpanded.addListener(() {
    _prefs?.setBool(_kConsoleExpanded, appConsoleExpanded.value);
  });
  // appPhotoDownloadDir 通过 setPhotoDownloadDir 单独写入, 不在此挂 listener.
}

/// 恢复所有设置到默认值 + 清除持久化 + 重置窗口尺寸.
Future<void> resetAllSettings() async {
  final prefs = _prefs ?? await SharedPreferences.getInstance();
  await prefs.remove(_kThemeMode);
  await prefs.remove(_kUiScale);
  await prefs.remove(_kWideBreakpoint);
  await prefs.remove(_kConsoleExpanded);
  await prefs.remove(_kPhotoDownloadDir);
  await prefs.remove(_kWindowW);
  await prefs.remove(_kWindowH);

  appThemeMode.value = _defaultThemeMode;
  appUiScale.value = _defaultUiScale;
  appWideBreakpoint.value = _defaultWideBreakpoint;
  appConsoleExpanded.value = _defaultConsoleExpanded;
  appPhotoDownloadDir.value = null;

  if (Platform.isWindows) {
    try {
      WindowSizeFfi.instance.setSize(_defaultWindowW, _defaultWindowH);
    } catch (_) {}
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadPersistedSettings();
  // 移动端: 状态栏与导航栏沉浸 (透明背景, 图标颜色随后随主题).
  if (Platform.isAndroid) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
    // Edge-to-edge: 让 body 能延伸到状态栏/导航栏下, 配合 SafeArea 控制内容.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    // 默认在移动端折叠串口控制台 (小屏寸土寸金).
    if (_prefs?.getBool(_kConsoleExpanded) == null) {
      appConsoleExpanded.value = false;
    }
    // 默认在移动端折叠串口连接栏, 同样节省纵向空间.
    appConnectionBarExpanded.value = false;
  }
  runApp(const BananaThermalApp());
}

class BananaThermalApp extends StatelessWidget {
  const BananaThermalApp({super.key});

  static const _seed = Color(0xFFFF7043);

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    final scheme = isDark
        ? base.copyWith(
            surface: const Color(0xFF111418),
            surfaceContainer: const Color(0xFF1B1F26),
            surfaceContainerHigh: const Color(0xFF232831),
            surfaceContainerHighest: const Color(0xFF2B313C),
            primary: const Color(0xFFFF8A65),
          )
        : base.copyWith(
            surface: const Color(0xFFF6F7FB),
            surfaceContainer: const Color(0xFFFFFFFF),
            surfaceContainerHigh: const Color(0xFFEEF0F5),
            surfaceContainerHighest: const Color(0xFFE3E6EE),
            primary: const Color(0xFFE85D2D),
          );
    return ThemeData(
          useMaterial3: true,
          colorScheme: scheme,
          fontFamily: 'SmileySans',
          scaffoldBackgroundColor: scheme.surface,
          cardTheme: CardThemeData(
            elevation: 0,
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            margin: EdgeInsets.zero,
          ),
          appBarTheme: AppBarTheme(
            backgroundColor: scheme.surface,
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: false,
            titleTextStyle: TextStyle(
              fontFamily: 'SmileySans',
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          dividerTheme: DividerThemeData(
            color: scheme.outlineVariant.withValues(alpha: 0.2),
            space: 1,
            thickness: 1,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: scheme.surfaceContainerHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: scheme.primary, width: 1.5),
            ),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          sliderTheme: SliderThemeData(
            trackHeight: 4,
            activeTrackColor: scheme.primary,
            inactiveTrackColor: scheme.surfaceContainerHighest,
            thumbColor: scheme.primary,
            overlayColor: scheme.primary.withValues(alpha: 0.12),
          ),
          switchTheme: SwitchThemeData(
            thumbColor: WidgetStateProperty.resolveWith((s) =>
                s.contains(WidgetState.selected)
                    ? scheme.primary
                    : scheme.onSurfaceVariant),
            trackColor: WidgetStateProperty.resolveWith((s) =>
                s.contains(WidgetState.selected)
                    ? scheme.primary.withValues(alpha: 0.4)
                    : scheme.surfaceContainerHighest),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: appThemeMode,
        builder: (context, mode, _) => MaterialApp(
          title: 'BananaThermalStudio',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          // DPI / UI 缩放: 同时缩放控件与字体.
          // 关键: 外层占位 = 父约束(窗口实际像素), 内部 child 约束 = 父约束/scale,
          //       再用 Transform.scale 把内容放大回父约束尺寸.
          // 否则 hit-test 区域 = SizedBox 尺寸 ≠ 视觉尺寸, 会出现点不到/黑边.
          builder: (ctx, child) {
            return ValueListenableBuilder<double>(
              valueListenable: appUiScale,
              builder: (c, scale, _) {
                return LayoutBuilder(
                  builder: (lc, cons) {
                    final mq = MediaQuery.of(lc);
                    final w = cons.maxWidth;
                    final h = cons.maxHeight;
                    final lw = w / scale;
                    final lh = h / scale;
                    return SizedBox(
                      width: w,
                      height: h,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: lw,
                          height: lh,
                          child: MediaQuery(
                            data: mq.copyWith(
                              size: Size(lw, lh),
                              devicePixelRatio:
                                  mq.devicePixelRatio * scale,
                              textScaler: const TextScaler.linear(1.0),
                            ),
                            child: child!,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
          home: const HomeShell(),
        ),
      ),
    );
  }
}
