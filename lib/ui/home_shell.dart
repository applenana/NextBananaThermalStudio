/// 主框架: 左侧 NavigationRail + 顶部连接条 + 主区切换.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io' show Platform;

import '../main.dart'
    show
        appThemeMode,
        appUiScale,
        appWideBreakpoint,
        appPhotoDownloadDir,
        appPhotoDetailOpen,
        appPhotoTabActive,
        appClosePhotoDetail,
        appConnectionBarExpanded,
        appConsoleExpanded,
        setPhotoDownloadDir,
        setWindowSizePersist,
        resetAllSettings;
import 'connection_bar.dart';
import 'photo_download_tab.dart';
import 'realtime_tab.dart';
import 'widgets/window_title_bar.dart';
import 'window_size_ffi.dart';
import '../app_state.dart';
import 'package:provider/provider.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// 进入图库 tab 前的推流开关快照, 用于离开图库时恢复.
  /// null = 当前不在图库 tab.
  ({bool thermal, bool visible})? _savedStreamState;

  /// Android 双击返回退出: 记录上次返回键时间, 2 秒内再按一次才真正退出.
  DateTime? _lastBackAt;

  /// 调试: 已注册的 streamStopDebug listener (避免 didChangeDependencies
  /// 重复触发). 配合 dispose 释放.
  AppState? _streamStopHookedApp;
  void _onStreamStop() {
    final app = _streamStopHookedApp;
    if (app == null) return;
    final e = app.streamStopDebug.value;
    if (e == null) return;
    if (!mounted) return;
    // 一旦显示, 标记为已消费, 防止 dialog 关掉后再触发同一事件.
    app.streamStopDebug.value = null;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('推流停止 · ${e.channel}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('时间: ${e.timestamp.toIso8601String()}'),
              const SizedBox(height: 6),
              Text('来源: ${e.origin}'),
              const SizedBox(height: 6),
              Text('连接状态: ${e.status.name}'),
              const SizedBox(height: 12),
              const Text('调用栈:',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: SelectableText(
                  e.stack,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (!identical(app, _streamStopHookedApp)) {
      _streamStopHookedApp?.streamStopDebug.removeListener(_onStreamStop);
      _streamStopHookedApp = app;
      app.streamStopDebug.addListener(_onStreamStop);
    }
  }

  @override
  void dispose() {
    _streamStopHookedApp?.streamStopDebug.removeListener(_onStreamStop);
    super.dispose();
  }

  /// Android 系统返回键处理. 优先级:
  /// 1) 图库详情打开 \u2192 关闭详情
  /// 2) 串口栏 / 控制台展开 \u2192 折叠
  /// 3) 当前 tab != 实时 \u2192 切到实时
  /// 4) 已在实时 + 2 秒内重复按 \u2192 退出 App; 否则 toast 提示.
  Future<void> _handleAndroidBack() async {
    if (!Platform.isAndroid) return;
    if (appPhotoDetailOpen.value && appClosePhotoDetail != null) {
      appClosePhotoDetail!();
      return;
    }
    if (appConnectionBarExpanded.value) {
      appConnectionBarExpanded.value = false;
      return;
    }
    if (appConsoleExpanded.value) {
      appConsoleExpanded.value = false;
      return;
    }
    if (_index != 0) {
      _select(0);
      return;
    }
    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(seconds: 2)) {
      await SystemNavigator.pop();
      return;
    }
    _lastBackAt = now;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          '再按一次返回键退出 App',
          textAlign: TextAlign.center,
        ),
        // floating + 距底部 96 像素, 浮在 NavigationBar 上方而不是被遮挡.
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 96),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        duration: const Duration(milliseconds: 1800),
        elevation: 6,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaffold = Scaffold(
      // ExcludeSemantics 包整树: Flutter Windows accessibility_bridge
      // 在复杂 widget 树 (IndexedStack + Slider + Dropdown 等) 上有已知 bug
      // (issue #105538), 持续刷 AXTree "Nodes left pending" 错误并最终让
      // 任意 native 调用 (libserialport / user32) 概率性 segfault.
      // 桌面工具对无障碍需求很弱, 整树关闭 a11y 节点同步即治本.
      body: ExcludeSemantics(
        child: SafeArea(
          // 移动端要让状态栏/手势区不挡内容; 桌面 SafeArea 退化为 0 padding.
          top: !Platform.isWindows,
          bottom: !Platform.isWindows,
          left: false,
          right: false,
          child: Column(
          children: [
            // 自绘标题栏只在 Windows 上启用 (配合 win32_window WM_NCCALCSIZE),
            // 移动端 / 其它桌面平台用系统装饰.
            if (Platform.isWindows) const WindowTitleBar(),
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: appWideBreakpoint,
                builder: (context, breakpoint, _) {
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      // 主区可用宽度低于断点 → 切到底部导航的“手机模式”.
                      final narrow = constraints.maxWidth < breakpoint;
                      return narrow
                          ? _buildNarrow(scheme)
                          : _buildWide(scheme);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      ),
    );
    // Android 拦截系统返回键, 按层级关闭子视图 / 切 tab / 双击退出.
    if (Platform.isAndroid) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleAndroidBack();
        },
        child: scaffold,
      );
    }
    return scaffold;
  }

  // 宽屏: 左侧 NavigationRail.
  Widget _buildWide(ColorScheme scheme) {
    return Row(
      children: [
        Container(
          width: 84,
          color: scheme.surface,
          child: Column(
            children: [
              const SizedBox(height: 18),
              _BrandLogo(scheme: scheme),
              const SizedBox(height: 24),
              _NavItem(
                icon: Icons.thermostat_outlined,
                iconActive: Icons.thermostat,
                label: '实时',
                active: _index == 0,
                onTap: () => _select(0),
              ),
              _NavItem(
                icon: Icons.photo_library_outlined,
                iconActive: Icons.photo_library,
                label: '图库',
                active: _index == 1,
                onTap: () => _select(1),
              ),
              const Spacer(),
              _NavItem(
                icon: Icons.settings_outlined,
                iconActive: Icons.settings,
                label: '设置',
                active: _index == 2,
                onTap: () => _select(2),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        Expanded(child: _mainColumn(compact: false)),
      ],
    );
  }

  // 窄屏: 顶部 logo+标题精简; 底部 BottomNavigationBar.
  Widget _buildNarrow(ColorScheme scheme) {
    return Column(
      children: [
        Expanded(child: _mainColumn(compact: true)),
        _BottomNav(
          index: _index,
          onSelect: _select,
          scheme: scheme,
        ),
      ],
    );
  }

  Widget _mainColumn({required bool compact}) {
    final hPad = compact ? 12.0 : 18.0;
    // Android 手机上隐藏顶部 Header (品牌标题 + 主题切换), 以最大化主区可用高度.
    // 主题切换入口转移到设置页。
    // Android 同时不在顶部全局项出 ConnectionBar — 改为只在「实时」tab 内部以普通
    // 元素出现, 避免抢占「图库」「设置」的屏幕空间. 桌面依旧全局顶部.
    final showHeader = !Platform.isAndroid;
    final showGlobalConnBar = !Platform.isAndroid;
    return Column(
      children: [
        if (showHeader) ...[
          SizedBox(height: compact ? 10 : 14),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: _Header(compact: compact),
          ),
          const SizedBox(height: 12),
        ] else
          SizedBox(height: compact ? 6 : 10),
        if (showGlobalConnBar) ...[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: const ConnectionBar(),
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, 0, hPad, compact ? 8 : 18),
            child: IndexedStack(
              index: _index,
              children: const [
                RealtimeTab(),
                PhotoDownloadTab(),
                _SettingsPlaceholder(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _select(int i) {
    final from = _index;
    setState(() => _index = i);
    appPhotoTabActive.value = (i == 1);
    final app = context.read<AppState>();
    // 进入图库: 记录当前推流状态 (供离开时恢复), 并由 PhotoTab._refresh
    // 内部 stopAllStreams 处理实际停止.
    if (i == 1 && from != 1) {
      _savedStreamState = (
        thermal: app.thermalStreamEnabled,
        visible: app.visibleStreamEnabled,
      );
      photoTabRefreshTrigger.value++;
    }
    // 离开图库 (切到其他 tab): 恢复进入前的推流状态.
    if (from == 1 && i != 1 && _savedStreamState != null) {
      final saved = _savedStreamState!;
      _savedStreamState = null;
      if (app.status == ConnectionStatus.connected) {
        if (saved.thermal && !app.thermalStreamEnabled) {
          app.setThermalStream(true);
        }
        if (saved.visible && !app.visibleStreamEnabled) {
          app.setVisibleStream(true);
        }
      }
    }
  }
}

class _BrandLogo extends StatelessWidget {
  final ColorScheme scheme;
  const _BrandLogo({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary, const Color(0xFFFFB199)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      // Android 上用 emoji 香蕉 (与桌面 launcher 图标同源), 默认字体能正确渲染
      // 彩色 emoji; 桌面保留 PNG 香蕉 logo 以获得更锐利的质感.
      child: Platform.isAndroid
          ? const Center(
              child: Text(
                '🍌',
                style: TextStyle(fontSize: 26),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/icons/icon.png',
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  final ColorScheme scheme;
  const _BottomNav({
    required this.index,
    required this.onSelect,
    required this.scheme,
  });

  static const _items = <_BottomNavItemData>[
    _BottomNavItemData(
      icon: Icons.thermostat_outlined,
      iconActive: Icons.thermostat,
      label: '实时',
    ),
    _BottomNavItemData(
      icon: Icons.photo_library_outlined,
      iconActive: Icons.photo_library,
      label: '图库',
    ),
    _BottomNavItemData(
      icon: Icons.settings_outlined,
      iconActive: Icons.settings,
      label: '设置',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              for (int i = 0; i < _items.length; i++)
                Expanded(
                  child: _BottomNavItem(
                    data: _items[i],
                    active: index == i,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItemData {
  final IconData icon;
  final IconData iconActive;
  final String label;
  const _BottomNavItemData({
    required this.icon,
    required this.iconActive,
    required this.label,
  });
}

class _BottomNavItem extends StatelessWidget {
  final _BottomNavItemData data;
  final bool active;
  final VoidCallback onTap;
  const _BottomNavItem({
    required this.data,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(active ? data.iconActive : data.icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(
              data.label,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final bool compact;
  const _Header({this.compact = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (compact) ...[
          _BrandLogo(scheme: scheme),
          const SizedBox(width: 10),
        ],
        Text(
          'BananaThermal',
          style: TextStyle(
            fontSize: compact ? 20 : 26,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'Studio',
            style: TextStyle(
              fontSize: 12,
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Spacer(),
        if (!compact) ...[
          Text(
            '红外热成像上位机',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 12),
        ],
        const _ThemeToggle(),
      ],
    );
  }
}

class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  static (IconData, String) _modeMeta(ThemeMode m) {
    switch (m) {
      case ThemeMode.system:
        return (Icons.brightness_auto_rounded, '跟随');
      case ThemeMode.light:
        return (Icons.light_mode_rounded, '白天');
      case ThemeMode.dark:
        return (Icons.dark_mode_rounded, '夜间');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        final (icon, label) = _modeMeta(mode);
        return Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: PopupMenuButton<ThemeMode>(
            tooltip: '主题模式',
            initialValue: mode,
            onSelected: (v) => appThemeMode.value = v,
            position: PopupMenuPosition.under,
            itemBuilder: (_) => [
              for (final m in ThemeMode.values)
                PopupMenuItem(
                  value: m,
                  child: Row(
                    children: [
                      Icon(_modeMeta(m).$1, size: 16, color: scheme.primary),
                      const SizedBox(width: 10),
                      Text(_modeMeta(m).$2),
                      if (m == mode) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.check_rounded,
                            size: 14, color: scheme.primary),
                      ],
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_drop_down_rounded,
                      size: 16, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData iconActive;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.iconActive,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: Material(
            color: active
                ? scheme.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    active ? iconActive : icon,
                    color: active ? scheme.primary : scheme.onSurfaceVariant,
                    size: 22,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          active ? scheme.primary : scheme.onSurfaceVariant,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsPlaceholder extends StatefulWidget {
  const _SettingsPlaceholder();
  @override
  State<_SettingsPlaceholder> createState() => _SettingsPlaceholderState();
}

class _SettingsPlaceholderState extends State<_SettingsPlaceholder> {
  late final TextEditingController _wCtl;
  late final TextEditingController _hCtl;

  static const _presets = <(String, double, double)>[
    ('紧凑 1100 × 800', 1100, 800),
    ('标准 1280 × 800', 1280, 800),
    ('宽屏 1440 × 900', 1440, 900),
    ('大屏 1600 × 1000', 1600, 1000),
    ('超宽 1920 × 1080', 1920, 1080),
  ];

  @override
  void initState() {
    super.initState();
    _wCtl = TextEditingController(text: '935');
    _hCtl = TextEditingController(text: '755');
    _syncSizeFromWindow();
  }

  Future<void> _syncSizeFromWindow() async {
    try {
      final s = WindowSizeFfi.instance.getSize();
      if (!mounted || s == null) return;
      _wCtl.text = s.width.toString();
      _hCtl.text = s.height.toString();
      setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _wCtl.dispose();
    _hCtl.dispose();
    super.dispose();
  }

  Future<void> _applySize(double w, double h) async {
    await setWindowSizePersist(w.round(), h.round());
    _wCtl.text = w.round().toString();
    _hCtl.text = h.round().toString();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSection(
            icon: Icons.text_fields_rounded,
            title: '界面缩放 (DPI)',
            subtitle: '影响文字大小与控件密度, 0.8 ~ 1.6',
            child: ValueListenableBuilder<double>(
              valueListenable: appUiScale,
              builder: (_, scale, __) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          min: 0.8,
                          max: 1.6,
                          divisions: 16,
                          value: scale.clamp(0.8, 1.6),
                          label: scale.toStringAsFixed(2) + '×',
                          onChanged: (v) {
                            appUiScale.value = double.parse(v.toStringAsFixed(2));
                          },
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text(
                          scale.toStringAsFixed(2) + '×',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final v in const [0.85, 1.0, 1.15, 1.3, 1.5])
                        ChoiceChip(
                          label: Text('${v.toStringAsFixed(2)}×'),
                          selected: (scale - v).abs() < 0.005,
                          onSelected: (_) => appUiScale.value = v,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 主题模式 — 全平台可见 (Android 上顶部无 ThemeToggle, 这里是唯一入口).
          _SettingsSection(
            icon: Icons.brightness_6_rounded,
            title: '主题模式',
            subtitle: '跟随系统 / 白天 / 夜间',
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: appThemeMode,
              builder: (_, mode, __) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in ThemeMode.values)
                    ChoiceChip(
                      avatar: Icon(
                        m == ThemeMode.system
                            ? Icons.brightness_auto_rounded
                            : m == ThemeMode.light
                                ? Icons.light_mode_rounded
                                : Icons.dark_mode_rounded,
                        size: 16,
                        color: mode == m ? cs.primary : cs.onSurfaceVariant,
                      ),
                      label: Text(
                        m == ThemeMode.system
                            ? '跟随系统'
                            : m == ThemeMode.light
                                ? '白天'
                                : '夜间',
                      ),
                      selected: mode == m,
                      onSelected: (_) => appThemeMode.value = m,
                    ),
                ],
              ),
            ),
          ),
          // 响应式断点 / 窗口尺寸 仅桌面可见 (Android 无窗口概念, NavigationRail 也并不适用).
          if (!Platform.isAndroid) ...[
          const SizedBox(height: 12),
          _SettingsSection(
            icon: Icons.view_column_rounded,
            title: '响应式断点',
            subtitle: '主区宽度大于此阈值时切换宽屏布局 (默认 1100)',
            child: ValueListenableBuilder<double>(
              valueListenable: appWideBreakpoint,
              builder: (_, bp, __) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          min: 600,
                          max: 2000,
                          divisions: 28,
                          value: bp.clamp(600, 2000),
                          label: '${bp.round()} px',
                          onChanged: (v) {
                            appWideBreakpoint.value = v.roundToDouble();
                          },
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          '${bp.round()} px',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final v in const [800.0, 1000.0, 1100.0, 1300.0, 1500.0])
                        ChoiceChip(
                          label: Text('${v.round()}'),
                          selected: (bp - v).abs() < 0.5,
                          onSelected: (_) => appWideBreakpoint.value = v,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SettingsSection(
            icon: Icons.aspect_ratio_rounded,
            title: '窗口尺寸',
            subtitle: '调整应用窗口大小, 立即生效',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _wCtl,
                        decoration: const InputDecoration(
                          labelText: '宽 (px)',
                          prefixIcon: Icon(Icons.swap_horiz_rounded, size: 18),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _hCtl,
                        decoration: const InputDecoration(
                          labelText: '高 (px)',
                          prefixIcon: Icon(Icons.swap_vert_rounded, size: 18),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('应用'),
                      onPressed: () {
                        final w = double.tryParse(_wCtl.text.trim());
                        final h = double.tryParse(_hCtl.text.trim());
                        if (w == null || h == null || w < 600 || h < 400) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('宽高不合法 (最小 600 × 400)')),
                          );
                          return;
                        }
                        _applySize(w, h);
                      },
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('读取当前'),
                      onPressed: _syncSizeFromWindow,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('预设',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    )),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in _presets)
                      ActionChip(
                        avatar: const Icon(Icons.crop_landscape_rounded,
                            size: 16),
                        label: Text(p.$1),
                        onPressed: () => _applySize(p.$2, p.$3),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.fullscreen_rounded, size: 16),
                      label: const Text('最大化'),
                      onPressed: () {
                        WindowSizeFfi.instance.maximize();
                      },
                    ),
                    ActionChip(
                      avatar:
                          const Icon(Icons.fullscreen_exit_rounded, size: 16),
                      label: const Text('恢复'),
                      onPressed: () async {
                        WindowSizeFfi.instance.restore();
                        await _syncSizeFromWindow();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          ], // end if !Platform.isAndroid (响应式断点 + 窗口尺寸)
          const SizedBox(height: 12),
          _SettingsSection(
            icon: Icons.folder_open_rounded,
            title: '图库下载路径',
            subtitle: '下载的原始文件与导出的 PNG 都会保存到该目录下的 raw / exports 子文件夹, 已持久化',
            child: const _DownloadDirControl(),
          ),
          const SizedBox(height: 12),
          _SettingsSection(
            icon: Icons.restore_rounded,
            title: '恢复出厂设置',
            subtitle: '一键重置所有设置 (主题 / 缩放 / 断点 / 控制台 / 下载路径 / 窗口尺寸)',
            child: const _ResetSettingsControl(),
          ),
          const SizedBox(height: 12),
          _SettingsSection(
            icon: Icons.info_outline_rounded,
            title: '关于',
            child: Text(
              'BananaThermal Studio · Flutter 上位机\n用于双光 (热成像 + 可见光) 设备的实时显示, 融合与数据下载.',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「图库下载路径」控件: 显示当前路径 + 选择目录 + 恢复默认.
class _DownloadDirControl extends StatefulWidget {
  const _DownloadDirControl();
  @override
  State<_DownloadDirControl> createState() => _DownloadDirControlState();
}

class _DownloadDirControlState extends State<_DownloadDirControl> {
  String? _defaultPath;

  @override
  void initState() {
    super.initState();
    _loadDefault();
  }

  Future<void> _loadDefault() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _defaultPath = p.join(docs.path, 'BananaThermalStudio'));
    } catch (_) {}
  }

  Future<void> _pick() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择图库下载根目录',
    );
    if (picked == null || picked.isEmpty) return;
    await setPhotoDownloadDir(picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('下载路径已更新: $picked')),
    );
  }

  Future<void> _reset() async {
    await setPhotoDownloadDir(null);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复默认下载路径')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String?>(
      valueListenable: appPhotoDownloadDir,
      builder: (_, custom, __) {
        final effective = (custom != null && custom.isNotEmpty)
            ? custom
            : (_defaultPath ?? '(加载中…)');
        final isCustom = custom != null && custom.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  Icon(
                    isCustom ? Icons.folder_special_rounded : Icons.folder_rounded,
                    size: 18,
                    color: isCustom ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      effective,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (isCustom)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '自定义',
                        style: TextStyle(
                          fontSize: 10,
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.drive_folder_upload_rounded, size: 18),
                  label: const Text('选择目录'),
                  onPressed: _pick,
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('恢复默认'),
                  onPressed: isCustom ? _reset : null,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 「恢复出厂设置」按钮 + 二次确认对话框.
class _ResetSettingsControl extends StatelessWidget {
  const _ResetSettingsControl();

  Future<void> _confirm(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 32),
        title: const Text('恢复出厂设置?'),
        content: const Text(
          '将清除以下设置并恢复默认:\n'
          '· 主题模式 / 界面缩放 / 响应式断点\n'
          '· 控制台展开状态\n'
          '· 图库下载路径\n'
          '· 窗口尺寸\n\n'
          '已下载的文件不会被删除.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await resetAllSettings();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复出厂设置')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        FilledButton.tonalIcon(
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text('恢复出厂设置'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
          ),
          onPressed: () => _confirm(context),
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: cs.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subtitle!,
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                              )),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}
