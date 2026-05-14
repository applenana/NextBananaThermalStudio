/// 主框架: 左侧 NavigationRail + 顶部连接条 + 主区切换.
library;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../main.dart'
    show
        appThemeMode,
        appUiScale,
        appWideBreakpoint,
        appPhotoDownloadDir,
        setPhotoDownloadDir,
        setWindowSizePersist,
        resetAllSettings;
import 'connection_bar.dart';
import 'photo_download_tab.dart';
import 'realtime_tab.dart';
import 'widgets/window_title_bar.dart';
import 'window_size_ffi.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // ExcludeSemantics 包整树: Flutter Windows accessibility_bridge
      // 在复杂 widget 树 (IndexedStack + Slider + Dropdown 等) 上有已知 bug
      // (issue #105538), 持续刷 AXTree "Nodes left pending" 错误并最终让
      // 任意 native 调用 (libserialport / user32) 概率性 segfault.
      // 桌面工具对无障碍需求很弱, 整树关闭 a11y 节点同步即治本.
      body: ExcludeSemantics(
        child: Column(
          children: [
            const WindowTitleBar(),
            Expanded(
              child: Row(
        children: [
          // 左侧导航
          Container(
            width: 84,
            color: scheme.surface,
            child: Column(
              children: [
                const SizedBox(height: 18),
                Container(
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
                  child: const Center(
                    child: Text('🍌', style: TextStyle(fontSize: 24)),
                  ),
                ),
                const SizedBox(height: 24),
                _NavItem(
                  icon: Icons.thermostat_outlined,
                  iconActive: Icons.thermostat,
                  label: '实时',
                  active: _index == 0,
                  onTap: () => setState(() => _index = 0),
                ),
                _NavItem(
                  icon: Icons.photo_library_outlined,
                  iconActive: Icons.photo_library,
                  label: '图库',
                  active: _index == 1,
                  onTap: () {
                    setState(() => _index = 1);
                    // 切到图库时若已连接则自动刷新图片列表; 即使已经在该 tab
                    // 上, 再次点击也会重新拉取一次, 符合用户预期.
                    photoTabRefreshTrigger.value++;
                  },
                ),
                const Spacer(),
                _NavItem(
                  icon: Icons.settings_outlined,
                  iconActive: Icons.settings,
                  label: '设置',
                  active: _index == 2,
                  onTap: () => setState(() => _index = 2),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          // 主区
          Expanded(
            child: Column(
              children: [
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18),
                  child: _Header(),
                ),
                const SizedBox(height: 12),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18),
                  child: ConnectionBar(),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
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
            ),
          ),
        ],
      ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'BananaThermal',
          style: TextStyle(
            fontSize: 26,
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
        Text(
          '红外热成像上位机',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: 12),
        const _ThemeToggle(),
      ],
    );
  }
}

class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        return Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => appThemeMode.value =
                isDark ? ThemeMode.light : ThemeMode.dark,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    isDark
                        ? Icons.dark_mode_rounded
                        : Icons.light_mode_rounded,
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isDark ? '夜间' : '白天',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
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
