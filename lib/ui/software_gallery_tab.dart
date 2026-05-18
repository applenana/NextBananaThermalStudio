/// 软件图库 tab: 仅消费 `<Documents>/BananaThermalStudio/SoftwareGallery`
/// 目录下的 `.btpkg`. 与设备图库 (PhotoDownloadTab) 物理/数据通路完全隔离.
///
/// 本文件 UI 沿用 `photo_download_tab.dart` 同款 Card-based 双栏布局:
///   - 左 320 列表卡 (头部 + ListView 圆角磁贴)
///   - 右 详情卡 (头部 + 元数据 chips + 预览 + 参数横排 + 视频控件)
/// 避免黑框加粗元件, 调参面板默认展开并紧贴预览, 立即可见效果.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart'
    show appCloseSoftwareDetail, appSoftwareDetailOpen, appPhotoDownloadDir;
import '../fusion/fusion.dart';
import '../render/render_params.dart';
import '../render/render_pipeline.dart';
import '../storage/capture_package.dart';
import '../storage/capture_service.dart';
import 'widgets/rgb_image_view.dart';
import 'widgets/temp_overlay.dart';
import 'banana_toast.dart';

/// 全局软件图库刷新触发器: GalleryShell 在副 tab 切到"软件图库"时 ++,
/// 已挂载的 SoftwareGalleryTab 监听后自动重扫目录.
/// 也可在拍摄/录制结束后从外部 ++ 触发列表更新.
final ValueNotifier<int> softwareGalleryRefreshTrigger = ValueNotifier<int>(0);

// ============================================================
// 主 Tab
// ============================================================
class SoftwareGalleryTab extends StatefulWidget {
  const SoftwareGalleryTab({super.key});
  @override
  State<SoftwareGalleryTab> createState() => _SoftwareGalleryTabState();
}

class _SoftwareGalleryTabState extends State<SoftwareGalleryTab> {
  List<SoftwareGalleryItem> _items = const [];
  SoftwareGalleryItem? _selected;
  bool _loading = false;
  String? _error;
  // 手机模式: 是否进入详情页 (列表 / 详情 单页切换).
  bool _phoneShowDetail = false;
  // 多选模式 + 已选路径集合 (按文件路径作为唯一键).
  bool _multiMode = false;
  final Set<String> _selectedPaths = <String>{};

  void _enterMultiWith(String path) {
    setState(() {
      _multiMode = true;
      _selectedPaths.add(path);
    });
  }

  void _exitMulti() {
    setState(() {
      _multiMode = false;
      _selectedPaths.clear();
    });
  }

  void _toggleSelectPath(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
        if (_selectedPaths.isEmpty) _multiMode = false;
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(_items.map((e) => e.path));
    });
  }

  Future<void> _bulkDelete() async {
    if (_selectedPaths.isEmpty) return;
    final n = _selectedPaths.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 30),
        title: Text('删除 $n 个数据包?'),
        content: const Text('该操作不可恢复. 已选中的所有 .btpkg 将从磁盘永久删除.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除 $n 项'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    int success = 0, fail = 0;
    for (final pth in _selectedPaths.toList()) {
      try {
        await File(pth).delete();
        _GalleryThumbCache.evict(pth);
        success++;
      } catch (_) {
        fail++;
      }
    }
    if (_selected != null && _selectedPaths.contains(_selected!.path)) {
      _selected = null;
    }
    _exitMulti();
    await _refresh();
    if (!mounted) return;
    BananaToast.show(
      context,
      '批量删除完成: 成功 $success${fail > 0 ? ", 失败 $fail" : ""}',
      icon: Icons.delete_sweep_rounded,
    );
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    softwareGalleryRefreshTrigger.addListener(_onTrigger);
    // Android 返回键 / sub-tab 切换 请求关闭详情页的全局钩子.
    appCloseSoftwareDetail = () {
      if (!mounted) return;
      if (_phoneShowDetail) _setPhoneShowDetail(false);
    };
  }

  @override
  void dispose() {
    softwareGalleryRefreshTrigger.removeListener(_onTrigger);
    appCloseSoftwareDetail = null;
    appSoftwareDetailOpen.value = false;
    super.dispose();
  }

  void _onTrigger() {
    if (mounted) _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await SoftwareGalleryIndex.list();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
        if (_selected != null) {
          final hit = list.where((e) => e.path == _selected!.path).toList();
          _selected = hit.isEmpty ? null : hit.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败: $e';
      });
    }
  }

  void _setPhoneShowDetail(bool v) {
    if (_phoneShowDetail == v) return;
    setState(() => _phoneShowDetail = v);
    appSoftwareDetailOpen.value = v;
  }

  // ---------------- 列表操作 ----------------
  Future<void> _onRename(SoftwareGalleryItem it) async {
    final ctrl =
        TextEditingController(text: p.basenameWithoutExtension(it.name));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(suffixText: '.btpkg'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    final newBase = ctrl.text.trim();
    if (newBase.isEmpty || newBase.contains(RegExp(r'[\\/:*?"<>|]'))) {
      if (!mounted) return;
      BananaToast.show(context, '文件名非法',
          icon: Icons.error_outline_rounded);
      return;
    }
    try {
      final dir = p.dirname(it.path);
      final newPath = p.join(dir, '$newBase.btpkg');
      if (newPath == it.path) return;
      if (await File(newPath).exists()) {
        if (!mounted) return;
        BananaToast.show(context, '同名文件已存在',
            icon: Icons.error_outline_rounded);
        return;
      }
      await File(it.path).rename(newPath);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      BananaToast.show(context, '重命名失败: $e',
          icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _onEditNote(SoftwareGalleryItem it) async {
    final ctrl = TextEditingController(text: it.meta?.note ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('编辑备注'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '场景 / 标签 / 任何文字'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CapturePackageReader.editNote(it.path, ctrl.text);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      BananaToast.show(context, '保存失败: $e',
          icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _onDelete(SoftwareGalleryItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除数据包?'),
        content: Text('将永久删除 ${it.name}, 此操作不可撤销.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await File(it.path).delete();
      if (_selected?.path == it.path) _selected = null;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      BananaToast.show(context, '删除失败: $e',
          icon: Icons.error_outline_rounded);
    }
  }

  // ---------------- 布局 ----------------
  @override
  Widget build(BuildContext context) {
    // Android 手机: 列表 / 详情单页切换, 平板/桌面双栏.
    if (Platform.isAndroid) {
      return LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 760;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 320, child: _buildListCard()),
              const SizedBox(width: 12),
              Expanded(child: _buildDetailCard()),
            ],
          );
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1.0).animate(anim),
              child: child,
            ),
          ),
          child: _phoneShowDetail
              ? KeyedSubtree(
                  key: const ValueKey('soft-detail'),
                  child: _buildDetailCard(phone: true),
                )
              : KeyedSubtree(
                  key: const ValueKey('soft-list'),
                  child: _buildListCard(phone: true),
                ),
        );
      });
    }
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth > 760;
      if (wide) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 320, child: _buildListCard()),
            const SizedBox(width: 12),
            Expanded(child: _buildDetailCard()),
          ],
        );
      }
      return Column(
        children: [
          Expanded(flex: 2, child: _buildListCard()),
          const SizedBox(height: 12),
          Expanded(flex: 3, child: _buildDetailCard()),
        ],
      );
    });
  }

  Widget _buildListCard({bool phone = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_multiMode) ...[
                  IconButton(
                    tooltip: '退出多选',
                    onPressed: _exitMulti,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                  Text(
                    '已选 ${_selectedPaths.length}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _items.isEmpty ? null : _selectAll,
                    icon: const Icon(Icons.select_all_rounded, size: 16),
                    label: const Text('全选'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed:
                        _selectedPaths.isEmpty ? null : _bulkDelete,
                    icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                    label: const Text('删除选中'),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
                ] else ...[
                  const Icon(Icons.collections_bookmark_rounded, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    '软件图库',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const Spacer(),
                  Text(
                    '${_items.length} 项',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '多选',
                    onPressed: _items.isEmpty
                        ? null
                        : () => setState(() => _multiMode = true),
                    icon: const Icon(Icons.checklist_rounded, size: 18),
                  ),
                  FilledButton.icon(
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('刷新'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(_error!,
                    style: TextStyle(fontSize: 11, color: scheme.error)),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? Center(
                          child: Text(
                            '空空如也\n请到实时画面用拍摄/录制按钮新建',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, i) => const SizedBox(height: 6),
                          itemBuilder: (_, i) {
                            final it = _items[i];
                            final isSel = _selected?.path == it.path;
                            final inMulti = _multiMode;
                            final checked = _selectedPaths.contains(it.path);
                            return _PkgTile(
                              item: it,
                              selected: isSel,
                              multiMode: inMulti,
                              checked: checked,
                              onTap: () {
                                if (inMulti) {
                                  _toggleSelectPath(it.path);
                                  return;
                                }
                                setState(() => _selected = it);
                                if (phone) _setPhoneShowDetail(true);
                              },
                              onLongPress: () {
                                if (!inMulti) _enterMultiWith(it.path);
                              },
                              onRename: () => _onRename(it),
                              onEditNote: () => _onEditNote(it),
                              onDelete: () => _onDelete(it),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailCard({bool phone = false}) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (phone) ...[
                  IconButton(
                    tooltip: '返回列表',
                    onPressed: () => _setPhoneShowDetail(false),
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                  ),
                  const SizedBox(width: 4),
                ],
                const Icon(Icons.image_search_rounded, size: 18),
                const SizedBox(width: 8),
                const Text(
                  '详情 / 预览',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const Spacer(),
                if (sel != null) ...[
                  IconButton(
                    tooltip: '重命名',
                    onPressed: () => _onRename(sel),
                    icon: const Icon(
                        Icons.drive_file_rename_outline_rounded,
                        size: 18),
                  ),
                  IconButton(
                    tooltip: '编辑备注',
                    onPressed: () => _onEditNote(sel),
                    icon: const Icon(Icons.edit_note_rounded, size: 18),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: () => _onDelete(sel),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    color: scheme.error,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            if (sel == null)
              Expanded(
                child: Center(
                  child: Text(
                    '在左侧选择一个数据包',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              Expanded(child: _DetailBody(key: ValueKey(sel.path), item: sel)),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 列表磁贴 (无黑框, 圆角 + InkWell, 选中态 primary 16%)
// ============================================================
class _PkgTile extends StatelessWidget {
  const _PkgTile({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onEditNote,
    required this.onDelete,
    this.multiMode = false,
    this.checked = false,
    this.onLongPress,
  });
  final SoftwareGalleryItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onEditNote;
  final VoidCallback onDelete;
  final bool multiMode;
  final bool checked;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = item.meta;
    final isVideo = item.packageType == 1;
    final type = isVideo ? '视频' : '照片';
    final place = (m?.place ?? '').trim();
    final note = (m?.note ?? '').trim();
    // 多选高亮优先级高于单选高亮.
    final highlight = multiMode ? checked : selected;
    return Material(
      color: highlight
          ? scheme.primary.withValues(alpha: 0.16)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              // 多选模式: 复选框; 否则: 缩略图(优先) 或 类型图标.
              if (multiMode)
                SizedBox(
                  width: 30,
                  height: 30,
                  child: Checkbox(
                    value: checked,
                    onChanged: (_) => onTap(),
                    visualDensity: VisualDensity.compact,
                  ),
                )
              else
                _TileThumb(item: item, isVideo: isVideo, selected: selected),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$type · ${_fmtSize(item.sizeBytes)}'
                      '${m?.frameCount != null ? ' · ${m!.frameCount}帧' : ''}'
                      ' · ${_fmtTime(item.mtime)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (place.isNotEmpty || note.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (place.isNotEmpty) '📍 $place',
                          if (note.isNotEmpty) note,
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!multiMode)
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: Icon(Icons.more_vert_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
                  onSelected: (v) {
                    switch (v) {
                      case 'rename':
                        onRename();
                        break;
                      case 'note':
                        onEditNote();
                        break;
                      case 'delete':
                        onDelete();
                        break;
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'note', child: Text('编辑备注')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// 列表磁贴缩略图: 优先显示首帧 visiblePng, 否则显示类型图标.
class _TileThumb extends StatelessWidget {
  const _TileThumb({
    required this.item,
    required this.isVideo,
    required this.selected,
  });
  final SoftwareGalleryItem item;
  final bool isVideo;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallbackIcon = Icon(
      isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
      size: 16,
      color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        color:
            selected ? scheme.primary : scheme.surfaceContainerHighest,
        child: FutureBuilder<Uint8List?>(
          future: _GalleryThumbCache.get(item.path, item.mtime),
          builder: (_, snap) {
            final bytes = snap.data;
            if (bytes != null && bytes.isNotEmpty) {
              return Image.memory(
                bytes,
                width: 30,
                height: 30,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
                errorBuilder: (_, __, ___) => fallbackIcon,
              );
            }
            return fallbackIcon;
          },
        ),
      ),
    );
  }
}

String _fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
}

String _fmtTime(DateTime t) {
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

// ============================================================
// 图库缩略图缓存
// 以 (path, mtime) 为键, 异步打开 .btpkg 取首帧 visiblePng 作为缩略图.
// 纯热成像 / 空帧返回 null, 由调用方降级显示图标.
// 内存级 LRU, 上限 256 项, 防止超长图库导致 OOM.
// ============================================================
class _GalleryThumbCache {
  static final Map<String, Future<Uint8List?>> _futures =
      <String, Future<Uint8List?>>{};
  static final Map<String, int> _mtimes = <String, int>{};
  // LRU access order: 通过 LinkedHashMap 顺序 + 移除再插入维护.
  static const int _maxItems = 256;

  static Future<Uint8List?> get(String path, DateTime mtime) {
    final mt = mtime.millisecondsSinceEpoch;
    final prev = _mtimes[path];
    if (prev != null && prev != mt) {
      // 文件被改写, 失效旧缓存.
      _futures.remove(path);
      _mtimes.remove(path);
    }
    final existing = _futures[path];
    if (existing != null) {
      // LRU touch: 移除再放尾.
      _futures.remove(path);
      _futures[path] = existing;
      return existing;
    }
    final f = _load(path);
    _futures[path] = f;
    _mtimes[path] = mt;
    if (_futures.length > _maxItems) {
      final oldest = _futures.keys.first;
      _futures.remove(oldest);
      _mtimes.remove(oldest);
    }
    return f;
  }

  static void evict(String path) {
    _futures.remove(path);
    _mtimes.remove(path);
  }

  static Future<Uint8List?> _load(String path) async {
    try {
      final r = await CapturePackageReader.open(path);
      if (r.frameCount == 0) return null;
      final f = await r.readFrame(0);
      // 优先热成像缩略图 (即使没有可见光也能预览温度分布).
      if (f.thermal != null && f.thermal!.isNotEmpty) {
        final png = _renderThermalThumb(
            f.thermal!, r.meta.thermalW, r.meta.thermalH);
        if (png != null) return png;
      }
      // 次选可见光首帧.
      if (f.visiblePng != null && f.visiblePng!.isNotEmpty) {
        return f.visiblePng;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // 极简热成像 -> Iron 调色板 -> PNG. 仅用于列表缩略图(小尺寸, 一次缓存).
  static Uint8List? _renderThermalThumb(Float32List data, int w, int h) {
    if (w <= 0 || h <= 0 || data.length < w * h) return null;
    double mn = double.infinity, mx = -double.infinity;
    for (final v in data) {
      if (v.isNaN) continue;
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    if (!mn.isFinite || !mx.isFinite) return null;
    final span = (mx - mn).abs() < 1e-6 ? 1.0 : (mx - mn);
    final image = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final v = data[y * w + x];
        double t = (v - mn) / span;
        if (t.isNaN) t = 0;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        // Iron 调色板 5 段: 黑 -> 紫 -> 红 -> 黄 -> 白.
        final rgb = _ironRgb(t);
        image.setPixelRgb(x, y, rgb[0], rgb[1], rgb[2]);
      }
    }
    return Uint8List.fromList(img.encodePng(image, level: 6));
  }

  // Iron 调色板查表 (近似): t in [0,1] -> RGB.
  static List<int> _ironRgb(double t) {
    // 5 段: (0.00) 黑(0,0,0) -> (0.25) 紫(80,0,128)
    // -> (0.50) 红(230,40,40) -> (0.75) 黄(255,200,0) -> (1.00) 白(255,255,255).
    const stops = <List<num>>[
      [0.00, 0, 0, 0],
      [0.25, 80, 0, 128],
      [0.50, 230, 40, 40],
      [0.75, 255, 200, 0],
      [1.00, 255, 255, 255],
    ];
    for (int i = 0; i < stops.length - 1; i++) {
      final a = stops[i];
      final b = stops[i + 1];
      if (t >= a[0] && t <= b[0]) {
        final k = (t - a[0]) / (b[0] - a[0]);
        final r = (a[1] + (b[1] - a[1]) * k).round();
        final g = (a[2] + (b[2] - a[2]) * k).round();
        final bb = (a[3] + (b[3] - a[3]) * k).round();
        return [r, g, bb];
      }
    }
    return [255, 255, 255];
  }
}

// ============================================================
// 详情主体: 元数据 chips + 预览 + 参数横排 + 视频控件
// ============================================================
class _DetailBody extends StatefulWidget {
  const _DetailBody({super.key, required this.item});
  final SoftwareGalleryItem item;
  @override
  State<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends State<_DetailBody> {
  CapturePackageReader? _reader;
  CaptureFrame? _frame;
  Uint8List? _visRgb888;
  int _visW = 0, _visH = 0;
  int _frameIndex = 0;
  bool _loading = false;
  String? _error;
  RenderParams? _params;
  Timer? _playTimer;
  bool _playing = false;
  // 可见光画面默认隐藏, 与设备图库一致, 用户点按钮才显示.
  bool _showVisible = false;
  // 左上角温度叠加 (MAX/MIN/AVG) 开关, 默认开. 视频回放每帧 setState 触发刷新.
  bool _tempOverlayEnabled = true;
  // 顶部元数据卡是否展开 (默认折叠, 单行摘要).
  bool _metaExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await CapturePackageReader.open(widget.item.path);
      _reader = r;
      if (mounted) {
        if (r.meta.renderParams != null) {
          try {
            _params = RenderParams.fromJson(r.meta.renderParams!);
          } catch (_) {
            _params = context.read<AppState>().renderParams;
          }
        } else {
          _params = context.read<AppState>().renderParams;
        }
      }
      if (r.frameCount > 0) {
        await _selectFrame(0);
      }
      if (!mounted) return;
      setState(() => _loading = false);
      if (r.type == CapturePackageHeader.typeVideo && r.frameCount > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_playing) _togglePlay();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '解析失败: $e';
      });
    }
  }

  Future<void> _selectFrame(int i) async {
    final r = _reader;
    if (r == null || i < 0 || i >= r.frameCount) return;
    final f = await r.readFrame(i);
    Uint8List? rgb;
    int w = 0, h = 0;
    final vpng = f.visiblePng;
    if (vpng != null && vpng.isNotEmpty) {
      try {
        final im = img.decodePng(vpng);
        if (im != null) {
          rgb = im.getBytes(order: img.ChannelOrder.rgb);
          w = im.width;
          h = im.height;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _frame = f;
      _visRgb888 = rgb;
      _visW = w;
      _visH = h;
      _frameIndex = i;
    });
  }

  void _togglePlay() {
    final r = _reader;
    if (r == null || r.frameCount < 2) return;
    if (_playing) {
      _playTimer?.cancel();
      _playTimer = null;
      setState(() => _playing = false);
      return;
    }
    int frameMs = 100;
    () async {
      try {
        final a = await r.readFrame(0);
        final b = await r.readFrame(1);
        final d = (b.tsMs - a.tsMs).abs();
        if (d > 10 && d < 2000) frameMs = d;
      } catch (_) {}
      if (!mounted) return;
      _playTimer = Timer.periodic(Duration(milliseconds: frameMs), (_) async {
        if (!mounted || _reader == null) return;
        final next = _frameIndex + 1;
        if (next >= _reader!.frameCount) {
          _playTimer?.cancel();
          _playTimer = null;
          if (mounted) setState(() => _playing = false);
          return;
        }
        await _selectFrame(next);
      });
      setState(() => _playing = true);
    }();
  }

  // ============================================================
  // 导出: 与设备图库 (PhotoDownloadTab) 一致, 落到 <root>/exports/
  // 并在 Android 上同步写入系统相册 (BananaThermal album).
  // ============================================================

  bool _exporting = false;

  Future<Directory> _ensureExportRoot() async {
    final custom = appPhotoDownloadDir.value;
    final root = (custom != null && custom.isNotEmpty)
        ? Directory(custom)
        : Directory(p.join(
            (await getApplicationDocumentsDirectory()).path,
            'BananaThermalStudio',
          ));
    if (!await root.exists()) await root.create(recursive: true);
    final dir = Directory(p.join(root.path, 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<bool> _saveToGalleryIfAndroid({
    required Uint8List bytes,
    required String name,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) return false;
      }
      await Gal.putImageBytes(bytes, album: 'BananaThermal', name: name);
      return true;
    } catch (e) {
      if (mounted) BananaToast.show(context, '相册保存失败: $e');
      return false;
    }
  }

  /// 把单帧渲染结果 + (可选)温度叠加烘焙成 RGBA bytes (8-bit per channel).
  /// 返回 (rgba, width, height). 用于 PNG / MP4 编码的统一源.
  Future<({Uint8List rgba, int width, int height})> _renderFrameToRgba(
    RenderedFrame r, {
    double? overlayMin,
    double? overlayMax,
    double? overlayAvg,
  }) async {
    final rgba = Uint8List(r.width * r.height * 4);
    for (var i = 0, j = 0; i < r.rgb.length; i += 3, j += 4) {
      rgba[j] = r.rgb[i];
      rgba[j + 1] = r.rgb[i + 1];
      rgba[j + 2] = r.rgb[i + 2];
      rgba[j + 3] = 255;
    }
    final hasOverlay =
        overlayMin != null && overlayMax != null && overlayAvg != null;
    if (!hasOverlay) {
      return (rgba: rgba, width: r.width, height: r.height);
    }
    // 需要烘焙叠加: 走 Canvas, 之后再 toByteData(rawRgba).
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      r.width,
      r.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final baseImg = await completer.future;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder,
        Rect.fromLTWH(0, 0, r.width.toDouble(), r.height.toDouble()));
    canvas.drawImage(baseImg, Offset.zero, Paint());
    _drawTempOverlayOnCanvas(canvas, r.width.toDouble(),
        r.height.toDouble(), overlayMin, overlayMax, overlayAvg);
    final picture = recorder.endRecording();
    final outImg = await picture.toImage(r.width, r.height);
    final bd = await outImg.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) throw 'toByteData rawRgba null';
    return (
      rgba: bd.buffer.asUint8List(),
      width: r.width,
      height: r.height,
    );
  }

  /// 把单帧渲染结果 + (可选)温度叠加烘焙成 PNG bytes.
  Future<Uint8List> _renderFrameToPng(
    RenderedFrame r, {
    double? overlayMin,
    double? overlayMax,
    double? overlayAvg,
  }) async {
    // PNG 编码路径仍走 Canvas (无叠加时也走, 以保持单一码路径并避免分支).
    final rgba = Uint8List(r.width * r.height * 4);
    for (var i = 0, j = 0; i < r.rgb.length; i += 3, j += 4) {
      rgba[j] = r.rgb[i];
      rgba[j + 1] = r.rgb[i + 1];
      rgba[j + 2] = r.rgb[i + 2];
      rgba[j + 3] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      r.width,
      r.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final baseImg = await completer.future;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder,
        Rect.fromLTWH(0, 0, r.width.toDouble(), r.height.toDouble()));
    canvas.drawImage(baseImg, Offset.zero, Paint());
    if (overlayMin != null && overlayMax != null && overlayAvg != null) {
      _drawTempOverlayOnCanvas(canvas, r.width.toDouble(),
          r.height.toDouble(), overlayMin, overlayMax, overlayAvg);
    }
    final picture = recorder.endRecording();
    final outImg = await picture.toImage(r.width, r.height);
    final bytes = await outImg.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw 'toByteData null';
    return bytes.buffer.asUint8List();
  }

  void _drawTempOverlayOnCanvas(
    Canvas canvas,
    double canvasW,
    double canvasH,
    double tMin,
    double tMax,
    double tAvg,
  ) {
    final shortSide = canvasW < canvasH ? canvasW : canvasH;
    final fontSize = (shortSide / 26).clamp(9.0, 22.0);
    final labelSize = (fontSize * 0.72).clamp(7.0, 16.0);
    final padH = fontSize * 0.85;
    final padV = fontSize * 0.55;
    final gap = fontSize * 0.7;
    final dotR = (fontSize * 0.28).clamp(2.0, 6.0);

    TextPainter mk(String s, double size, FontWeight w, Color c) => TextPainter(
          text: TextSpan(
            text: s,
            style: TextStyle(
              fontSize: size,
              fontWeight: w,
              color: c,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

    final items = <({Color color, TextPainter label, TextPainter value})>[
      (
        color: const Color(0xFFFF6E40),
        label: mk('MAX', labelSize, FontWeight.w600, Colors.white70),
        value: mk('${tMax.toStringAsFixed(1)}°', fontSize, FontWeight.w700,
            Colors.white),
      ),
      (
        color: const Color(0xFF40C4FF),
        label: mk('MIN', labelSize, FontWeight.w600, Colors.white70),
        value: mk('${tMin.toStringAsFixed(1)}°', fontSize, FontWeight.w700,
            Colors.white),
      ),
      (
        color: const Color(0xFFFFD740),
        label: mk('AVG', labelSize, FontWeight.w600, Colors.white70),
        value: mk('${tAvg.toStringAsFixed(1)}°', fontSize, FontWeight.w700,
            Colors.white),
      ),
    ];

    double itemW(({Color color, TextPainter label, TextPainter value}) it) {
      final textW =
          it.label.width > it.value.width ? it.label.width : it.value.width;
      return dotR * 2 + 4 + textW;
    }

    double totalW = 0;
    for (var i = 0; i < items.length; i++) {
      totalW += itemW(items[i]);
      if (i != items.length - 1) totalW += gap;
    }
    final itemH = items.first.value.height + items.first.label.height + 2;
    final boxW = totalW + padH * 2;
    final boxH = itemH + padV * 2;
    const margin = 8.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(margin, margin, boxW, boxH),
        const Radius.circular(10),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    double x = margin + padH;
    final yTop = margin + padV;
    for (final it in items) {
      final w = itemW(it);
      canvas.drawCircle(
        Offset(x + dotR, yTop + itemH / 2),
        dotR,
        Paint()..color = it.color,
      );
      final textX = x + dotR * 2 + 4;
      it.label.paint(canvas, Offset(textX, yTop));
      it.value.paint(canvas, Offset(textX, yTop + it.label.height + 2));
      x += w + gap;
    }
  }

  /// 通用: 把指定 CaptureFrame 走 renderPipeline (含热像才有效) +
  /// 温度统计. 用于 PNG / MP4 双路径共享.
  ///   - 返回 null: 帧无热像数据.
  ///   - rendered: 渲染结果, t{Min,Max,Avg}: 当 _tempOverlayEnabled 时非空.
  Future<({RenderedFrame rendered, double? tMin, double? tMax, double? tAvg})?>
      _renderThermalFrame(CaptureFrame frame, CaptureMeta meta) async {
    if (!(frame.hasThermal && frame.thermal != null)) return null;
    Uint8List? visRgb;
    int vw = 0, vh = 0;
    final vpng = frame.visiblePng;
    if (vpng != null && vpng.isNotEmpty) {
      try {
        final im = img.decodePng(vpng);
        if (im != null) {
          visRgb = im.getBytes(order: img.ChannelOrder.rgb);
          vw = im.width;
          vh = im.height;
        }
      } catch (_) {}
    }
    final r = renderPipeline(
      thermalFrame: frame.thermal!,
      srcW: meta.thermalW,
      srcH: meta.thermalH,
      params: _params ?? const RenderParams(),
      visibleRgb: visRgb,
      visibleW: vw,
      visibleH: vh,
    );
    double? tMin, tMax, tAvg;
    if (_tempOverlayEnabled) {
      double mn = double.infinity;
      double mx = -double.infinity;
      double s = 0;
      int n = 0;
      for (final v in frame.thermal!) {
        if (v.isFinite) {
          if (v < mn) mn = v;
          if (v > mx) mx = v;
          s += v;
          n++;
        }
      }
      if (n > 0) {
        tMin = mn;
        tMax = mx;
        tAvg = s / n;
      }
    }
    return (rendered: r, tMin: tMin, tMax: tMax, tAvg: tAvg);
  }

  /// 把指定 CaptureFrame 输出为 PNG bytes.
  /// - 含热成像: 走 renderPipeline + 温度叠加 (按当前 _tempOverlayEnabled).
  /// - 纯可见光: 直接返回 visiblePng (调用方决定文件扩展名).
  /// 返回 (bytes, ext: 'png' 或 'png'/'jpg').
  Future<(Uint8List bytes, String ext)?> _bakeFrame(
      CaptureFrame frame, CaptureMeta meta) async {
    final th = await _renderThermalFrame(frame, meta);
    if (th != null) {
      final png = await _renderFrameToPng(th.rendered,
          overlayMin: th.tMin, overlayMax: th.tMax, overlayAvg: th.tAvg);
      return (png, 'png');
    }
    if (frame.hasVisible && frame.visiblePng != null) {
      return (frame.visiblePng!, 'png');
    }
    return null;
  }

  /// 把指定 CaptureFrame 输出为 RGBA bytes (含可选温度叠加). 用于 MP4 编码.
  /// - 含热像: renderPipeline + Canvas 叠加, 输出 (rgba, w, h).
  /// - 纯可见光: 解码 PNG → RGB888 → 填充 alpha. 没有温度叠加.
  /// - 都无: null.
  Future<({Uint8List rgba, int width, int height})?> _bakeFrameToRgba(
      CaptureFrame frame, CaptureMeta meta) async {
    final th = await _renderThermalFrame(frame, meta);
    if (th != null) {
      return _renderFrameToRgba(th.rendered,
          overlayMin: th.tMin, overlayMax: th.tMax, overlayAvg: th.tAvg);
    }
    if (frame.hasVisible && frame.visiblePng != null) {
      try {
        final im = img.decodePng(frame.visiblePng!);
        if (im == null) return null;
        final rgb = im.getBytes(order: img.ChannelOrder.rgb);
        final rgba = Uint8List(im.width * im.height * 4);
        for (var i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
          rgba[j] = rgb[i];
          rgba[j + 1] = rgb[i + 1];
          rgba[j + 2] = rgb[i + 2];
          rgba[j + 3] = 255;
        }
        return (rgba: rgba, width: im.width, height: im.height);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 把 RGBA 缓冲 (srcW x srcH, stride=srcW*4) 截取出左上 dstW x dstH 子区域,
  /// 返回新 RGBA buffer (stride=dstW*4). dstW/dstH 必须 <= srcW/srcH.
  /// 用于 MP4 编码前把帧宽/高 floor 到偶数 (H264 要求).
  Uint8List _cropRgba(Uint8List src, int srcW, int srcH, int dstW, int dstH) {
    if (srcW == dstW && srcH == dstH) return src;
    final out = Uint8List(dstW * dstH * 4);
    final srcStride = srcW * 4;
    final dstStride = dstW * 4;
    for (var y = 0; y < dstH; y++) {
      final s = y * srcStride;
      final d = y * dstStride;
      out.setRange(d, d + dstStride, src, s);
    }
    return out;
  }

  Future<void> _exportCurrentFrame() async {
    final f = _frame;
    final r = _reader;
    if (f == null || r == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final baked = await _bakeFrame(f, r.meta);
      if (baked == null) {
        if (mounted) BananaToast.show(context, '当前帧无可导出内容');
        return;
      }
      final (bytes, ext) = baked;
      final base = p.basenameWithoutExtension(widget.item.path);
      final name = r.frameCount > 1 ? '${base}_f$_frameIndex' : base;
      final dir = await _ensureExportRoot();
      final file = File(p.join(dir.path, '$name.$ext'));
      await file.writeAsBytes(bytes);
      final albumOk =
          await _saveToGalleryIfAndroid(bytes: bytes, name: name);
      if (!mounted) return;
      BananaToast.show(
          context,
          albumOk
              ? '已导出 ${p.basename(file.path)} (相册已保存)'
              : '已导出 ${p.basename(file.path)}');
    } catch (e) {
      if (!mounted) return;
      BananaToast.show(context, '导出失败: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 视频包导出为 MP4:
  /// - Android/iOS/macOS: flutter_quick_video_encoder (MediaCodec / AVFoundation)
  /// - Windows/Linux: 调用系统 ffmpeg (libx264) 通过 stdin 接收 raw rgba
  /// - 找不到 ffmpeg 时回退到逐帧 PNG 批量导出, 并提示用户安装 ffmpeg.
  Future<void> _exportAllFrames() async {
    final r = _reader;
    if (r == null || _exporting) return;
    if (r.frameCount <= 1) {
      await _exportCurrentFrame();
      return;
    }
    if (_playing) {
      _playTimer?.cancel();
      _playTimer = null;
      setState(() => _playing = false);
    }
    final usePlugin =
        Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    setState(() => _exporting = true);
    try {
      // 1) 探测 fps: 取首两帧时间差.
      int frameMs = 100;
      try {
        final a = await r.readFrame(0);
        final b = await r.readFrame(1);
        final d = (b.tsMs - a.tsMs).abs();
        if (d > 10 && d < 2000) frameMs = d;
      } catch (_) {}
      final fps = (1000 / frameMs).round().clamp(1, 60);
      // 2) 烘焙首帧, 确定画面尺寸 (强制偶数, 满足 H264 要求).
      final first = await _bakeFrameToRgba(await r.readFrame(0), r.meta);
      if (first == null) {
        if (!mounted) return;
        BananaToast.show(context, '首帧无可导出内容');
        return;
      }
      final w = first.width & ~1;
      final h = first.height & ~1;
      if (w < 16 || h < 16) {
        if (!mounted) return;
        BananaToast.show(context, '画面尺寸过小, 无法编码 MP4');
        return;
      }
      final base = p.basenameWithoutExtension(widget.item.path);
      final dir = await _ensureExportRoot();
      final outPath = p.join(dir.path, '$base.mp4');
      final bitrate =
          (w * h * fps * 0.12).round().clamp(500000, 20000000);

      if (usePlugin) {
        // 移动 / macOS: 走原生硬件编码插件.
        await FlutterQuickVideoEncoder.setup(
          width: w,
          height: h,
          fps: fps,
          videoBitrate: bitrate,
          profileLevel: ProfileLevel.high40,
          audioChannels: 0,
          audioBitrate: 0,
          sampleRate: 0,
          filepath: outPath,
        );
        await FlutterQuickVideoEncoder.appendVideoFrame(
            _cropRgba(first.rgba, first.width, first.height, w, h));
        for (var i = 1; i < r.frameCount; i++) {
          final f = await r.readFrame(i);
          final bake = await _bakeFrameToRgba(f, r.meta);
          if (bake == null) continue;
          await FlutterQuickVideoEncoder.appendVideoFrame(
              _cropRgba(bake.rgba, bake.width, bake.height, w, h));
          if (!mounted) {
            await FlutterQuickVideoEncoder.finish();
            return;
          }
          if (i % 10 == 0) {
            BananaToast.show(context, '编码中 $i / ${r.frameCount} ...');
          }
        }
        await FlutterQuickVideoEncoder.finish();
        bool albumOk = false;
        if (Platform.isAndroid || Platform.isIOS) {
          try {
            final has = await Gal.hasAccess();
            if (!has) await Gal.requestAccess();
            await Gal.putVideo(outPath, album: 'BananaThermal');
            albumOk = true;
          } catch (e) {
            if (mounted) BananaToast.show(context, '相册保存失败: $e');
          }
        }
        if (!mounted) return;
        BananaToast.show(
            context, albumOk ? '已导出 $base.mp4 (相册已保存)' : '已导出 $outPath');
        return;
      }

      // 桌面 Windows/Linux: 通过外部 ffmpeg 编码.
      final ffmpegPath = await _resolveFfmpegPath();
      if (ffmpegPath == null) {
        if (!mounted) return;
        BananaToast.show(
          context,
          '未检测到 ffmpeg, 回退逐帧 PNG. 将 ffmpeg 加入 PATH 后可直接导出 MP4.',
          duration: const Duration(seconds: 5),
          icon: Icons.warning_amber_rounded,
        );
        await _exportAllFramesAsPngBatch(setExportingFlag: false);
        return;
      }
      final args = <String>[
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-f', 'rawvideo',
        '-pix_fmt', 'rgba',
        '-s', '${w}x$h',
        '-r', '$fps',
        '-i', 'pipe:0',
        '-c:v', 'libx264',
        '-pix_fmt', 'yuv420p',
        '-preset', 'medium',
        '-b:v', '$bitrate',
        outPath,
      ];
      final proc = await Process.start(ffmpegPath, args);
      final stderrBuf = StringBuffer();
      proc.stderr.transform(const SystemEncoding().decoder).listen(stderrBuf.write);
      proc.stdout.drain<void>();
      // 写入首帧
      proc.stdin.add(_cropRgba(first.rgba, first.width, first.height, w, h));
      for (var i = 1; i < r.frameCount; i++) {
        final f = await r.readFrame(i);
        final bake = await _bakeFrameToRgba(f, r.meta);
        if (bake == null) continue;
        proc.stdin.add(_cropRgba(bake.rgba, bake.width, bake.height, w, h));
        await proc.stdin.flush();
        if (!mounted) {
          await proc.stdin.close();
          await proc.exitCode;
          return;
        }
        if (i % 10 == 0) {
          BananaToast.show(context, '编码中 $i / ${r.frameCount} ...');
        }
      }
      await proc.stdin.flush();
      await proc.stdin.close();
      final code = await proc.exitCode;
      if (!mounted) return;
      if (code != 0) {
        BananaToast.show(
            context, 'ffmpeg 编码失败 (code=$code): ${stderrBuf.toString().trim()}');
        return;
      }
      BananaToast.show(context, '已导出 $outPath');
    } catch (e) {
      if (!mounted) return;
      BananaToast.show(context, '视频导出失败: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 解析可用的 ffmpeg 可执行路径:
  /// 1. 优先使用与 app exe 同目录的 ffmpeg(.exe) (Windows 打包随附);
  /// 2. 否则回退到系统 PATH 中的 ffmpeg.
  /// 若都不可用返回 null.
  Future<String?> _resolveFfmpegPath() async {
    final exeName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = p.join(exeDir, exeName);
      if (await File(bundled).exists()) {
        return bundled;
      }
    } catch (_) {}
    try {
      final r = await Process.run(exeName, ['-version']);
      if (r.exitCode == 0) return exeName;
    } catch (_) {}
    return null;
  }

  /// Windows/Linux 桌面回退: 逐帧 PNG 写入 exports/<base>/ 子目录.
  Future<void> _exportAllFramesAsPngBatch({bool setExportingFlag = true}) async {
    final r = _reader;
    if (r == null) return;
    if (setExportingFlag) setState(() => _exporting = true);
    try {
      final base = p.basenameWithoutExtension(widget.item.path);
      final root = await _ensureExportRoot();
      final subDir = Directory(p.join(root.path, base));
      if (!await subDir.exists()) await subDir.create(recursive: true);
      int ok = 0;
      for (var i = 0; i < r.frameCount; i++) {
        final f = await r.readFrame(i);
        final baked = await _bakeFrame(f, r.meta);
        if (baked == null) continue;
        final (bytes, ext) = baked;
        final file = File(p.join(subDir.path,
            '${base}_f${i.toString().padLeft(4, '0')}.$ext'));
        await file.writeAsBytes(bytes);
        ok++;
        if (!mounted) return;
        if (i % 5 == 0) {
          BananaToast.show(context, '导出中 $i / ${r.frameCount} ...');
        }
      }
      if (!mounted) return;
      BananaToast.show(context, '已导出 $ok 帧到 ${subDir.path}');
    } catch (e) {
      if (!mounted) return;
      BananaToast.show(context, '批量导出失败: $e');
    } finally {
      if (setExportingFlag && mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(_error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    final r = _reader;
    final f = _frame;
    final params = _params;
    if (r == null || f == null || params == null) {
      return const Center(child: Text('无可用帧'));
    }
    final scheme = Theme.of(context).colorScheme;
    final meta = r.meta;
    // 包级是否含可见光/热成像 (用于元数据 chips 与录制时间轴色条).
    final hasVisInPkg = meta.hasAnyVisible;
    final hasThermalInPkg = meta.hasAnyThermal;
    // 当前帧的槽位状态.
    final fHasT = f.hasThermal;
    final fHasV = f.hasVisible;
    final hasVisInFrame = _visRgb888 != null;
    final isVideo = r.type == CapturePackageHeader.typeVideo;

    String pkgSlotDesc() {
      if (hasThermalInPkg && hasVisInPkg) return '双光 (热+可见)';
      if (hasThermalInPkg) return '纯热成像';
      if (hasVisInPkg) return '纯可见光';
      return '空包 (无任何槽位)';
    }

    // 顶部元数据 chips.
    final metaChips = <Widget>[
      _kv('文件', widget.item.name),
      _kv('类型', '${isVideo ? '视频' : '照片'} · ${r.frameCount} 帧'),
      _kv('槽位', pkgSlotDesc()),
      _kv('创建', _fmtTime(meta.createdAt.toLocal())),
      if (meta.deviceSn != null) _kv('设备', meta.deviceSn!),
      _kv('位置', (meta.place ?? '').isEmpty ? '未知' : meta.place!),
      if (meta.lat != null && meta.lng != null)
        _kv('经纬',
            '${meta.lat!.toStringAsFixed(5)}, ${meta.lng!.toStringAsFixed(5)}'),
      if (hasThermalInPkg)
        _kv('热成像', '${meta.thermalW} × ${meta.thermalH}')
      else
        _kv('热成像', '未保存'),
      if (hasVisInPkg)
        _kv('可见光', '${meta.visibleW} × ${meta.visibleH}')
      else
        _kv('可见光', '未保存'),
      if (meta.note.isNotEmpty) _kv('备注', meta.note),
    ];

    // 不滚动: Column + Expanded 让"主画面"自适应剩余高度.
    // 计算本帧温度统计 (MAX/MIN/AVG) 用于左上角温度叠加. 视频回放每帧自动重算.
    double? tMin, tMax, tAvg;
    if (fHasT && f.thermal != null) {
      double mn = double.infinity;
      double mx = -double.infinity;
      double s = 0;
      int n = 0;
      for (final v in f.thermal!) {
        if (v.isFinite) {
          if (v < mn) mn = v;
          if (v > mx) mx = v;
          s += v;
          n++;
        }
      }
      if (n > 0) {
        tMin = mn;
        tMax = mx;
        tAvg = s / n;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ----- 元数据卡: 默认折叠到单行摘要, 点击展开/收起 -----
        Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _metaExpanded = !_metaExpanded),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _metaExpanded
                          ? DefaultTextStyle(
                              key: const ValueKey('soft-meta-expanded'),
                              style: TextStyle(
                                  fontSize: 11.5, color: scheme.onSurface),
                              child: Wrap(
                                spacing: 16,
                                runSpacing: 4,
                                children: metaChips,
                              ),
                            )
                          : Padding(
                              key: const ValueKey('soft-meta-collapsed'),
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '${widget.item.name}  ·  '
                                '${isVideo ? '视频' : '照片'} · ${r.frameCount} 帧'
                                '${meta.deviceSn != null ? '  ·  ${meta.deviceSn}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 导出本帧
                  Tooltip(
                    message: _exporting ? '导出中…' : '导出本帧 (PNG)',
                    child: InkResponse(
                      radius: 18,
                      onTap: _exporting ? null : _exportCurrentFrame,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: _exporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(Icons.download_rounded,
                                size: 20, color: scheme.primary),
                      ),
                    ),
                  ),
                  // 视频: 导出 MP4 (桌面回退逐帧 PNG)
                  if (isVideo && r.frameCount > 1) ...[
                    const SizedBox(width: 2),
                    Tooltip(
                      message: '导出 MP4 视频',
                      child: InkResponse(
                        radius: 18,
                        onTap: _exporting ? null : _exportAllFrames,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.movie_creation_rounded,
                              size: 20, color: scheme.primary),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    _metaExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // ----- 参数横排 -----
        _ParamsRow(
          hasVisible: hasVisInFrame,
          params: params,
          onParamsChanged: (v) => setState(() => _params = v),
        ),
        const SizedBox(height: 8),
        // ----- 主预览区 (占满剩余高度) -----
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: Stack(
                    children: [
                      // 主画面: 按帧槽位分支. 温度叠加 (MAX/MIN/AVG) 作为
                      // topLeftBadge 注入到 AspectRatio 内部, 确保叠加贴在
                      // 真实画面左上角 (而不是外层 box 的左上, 与导出图一致).
                      Positioned.fill(
                        child: Center(
                          child: _buildMainPreview(
                            f: f,
                            meta: meta,
                            params: params,
                            scheme: scheme,
                            topLeftBadge: (_tempOverlayEnabled &&
                                    tMin != null &&
                                    tMax != null &&
                                    tAvg != null)
                                ? TempOverlay(
                                    tMax: tMax,
                                    tMin: tMin,
                                    tAvg: tAvg,
                                    compact: MediaQuery.of(context)
                                            .size
                                            .shortestSide <
                                        600,
                                  )
                                : null,
                          ),
                        ),
                      ),
                      // 右上: 可见光显示开关 (仅本帧含可见光时才出现).
                      if (fHasV && fHasT)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: _OverlayIconButton(
                            tooltip: _showVisible ? '隐藏可见光' : '显示可见光',
                            icon: _showVisible
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            onTap: () => setState(
                                () => _showVisible = !_showVisible),
                          ),
                        ),
                      // 左上偏右: 温度叠加开关 (仅含热成像才出现).
                      if (fHasT)
                        Positioned(
                          top: 6,
                          right: (fHasV && fHasT) ? 44 : 6,
                          child: _OverlayIconButton(
                            tooltip: _tempOverlayEnabled
                                ? '隐藏温度叠加'
                                : '显示温度叠加',
                            icon: _tempOverlayEnabled
                                ? Icons.thermostat
                                : Icons.thermostat_outlined,
                            onTap: () => setState(() =>
                                _tempOverlayEnabled = !_tempOverlayEnabled),
                          ),
                        ),
                      // 视频控件: 半透明叠加在画面底部 (Web 视频风格).
                      if (isVideo && r.frameCount > 1)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 槽位色条: 每帧一个细格, 颜色=该帧实际槽位.
                              _SlotTimelineBar(
                                masks: r.frameSlotMasks,
                                cursor: _frameIndex,
                              ),
                              _VideoOverlay(
                                playing: _playing,
                                frameIndex: _frameIndex,
                                frameCount: r.frameCount,
                                tsMs: f.tsMs,
                                onToggle: _togglePlay,
                                onSeek: (i) {
                                  if (_playing) {
                                    _playTimer?.cancel();
                                    _playTimer = null;
                                    setState(() => _playing = false);
                                  }
                                  _selectFrame(i);
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 可见光小窗: 仅当本帧含可见光 + 同时含热成像 + 用户开关开启时显示.
              if (_showVisible && fHasT && fHasV) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 220,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.image_outlined,
                                size: 13, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '可见光 · ${(f.visiblePng!.length / 1024).toStringAsFixed(1)} KB',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: scheme.onSurfaceVariant),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(
                              f.visiblePng!,
                              fit: BoxFit.contain,
                              alignment: Alignment.topCenter,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 12, color: scheme.onSurface),
        children: [
          TextSpan(
            text: '$k  ',
            style: TextStyle(
                color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500),
          ),
          TextSpan(text: v),
        ],
      ),
    );
  }

  /// 主预览区: 按本帧槽位状态分支渲染.
  ///
  /// - 双光: 热成像主画面 + 可见光融合参数生效.
  /// - 纯热: 仅热成像 (融合相关参数忽略).
  /// - 纯可见: 直接 Image.memory 显示可见光 PNG.
  /// - 空帧: 占位文案, 提示该帧无任何槽位数据.
  Widget _buildMainPreview({
    required CaptureFrame f,
    required CaptureMeta meta,
    required RenderParams params,
    required ColorScheme scheme,
    Widget? topLeftBadge,
  }) {
    final hasT = f.hasThermal;
    final hasV = f.hasVisible;
    if (!hasT && !hasV) {
      return Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_clear_rounded,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(
              '本帧无任何数据 (空槽位)',
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (hasT) {
      // 含热成像: 走原渲染管线; 是否融合可见光由 _visRgb888/_showVisible 控制.
      final useFusionRgb = (hasV && _visRgb888 != null) ? _visRgb888 : null;
      return AspectRatio(
        aspectRatio: meta.thermalW / meta.thermalH,
        child: Stack(
          children: [
            Positioned.fill(
              child: _ThermalImage(
                thermal: f.thermal!,
                width: meta.thermalW,
                height: meta.thermalH,
                params: params,
                visibleRgb888: useFusionRgb,
                visibleW: useFusionRgb != null ? _visW : 0,
                visibleH: useFusionRgb != null ? _visH : 0,
              ),
            ),
            if (topLeftBadge != null)
              Positioned(top: 8, left: 8, child: topLeftBadge),
          ],
        ),
      );
    }
    // 纯可见光帧.
    final vpng = f.visiblePng!;
    return AspectRatio(
      aspectRatio: meta.visibleW > 0 && meta.visibleH > 0
          ? meta.visibleW / meta.visibleH
          : 4 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        // gaplessPlayback: 视频连续帧刷新时保留旧画面直到新帧 decode 完成,
        // 避免纯可见光视频回放出现"一闪一闪"的空白.
        child: Image.memory(vpng, fit: BoxFit.contain, gaplessPlayback: true),
      ),
    );
  }
}

/// 帧时间轴下方的槽位色条: 每帧一个细格, 颜色反映该帧实际包含的槽位.
///
/// - 热成像 only: 橙色.
/// - 可见光 only: 青色.
/// - 双光: 蓝绿(theme primary).
/// - 空帧: 半透明灰.
/// - 当前帧位置叠加一条白色游标.
class _SlotTimelineBar extends StatelessWidget {
  const _SlotTimelineBar({required this.masks, required this.cursor});
  final List<int> masks;
  final int cursor;

  static const Color _cThermal = Color(0xFFFF8A65);
  static const Color _cVisible = Color(0xFF4DD0E1);
  static const Color _cBoth = Color(0xFF4DB6AC);

  Color _colorOf(int mask, ColorScheme scheme) {
    final hasT = (mask & FrameSlot.thermal) != 0;
    final hasV = (mask & FrameSlot.visible) != 0;
    if (hasT && hasV) return _cBoth;
    if (hasT) return _cThermal;
    if (hasV) return _cVisible;
    return scheme.outlineVariant.withValues(alpha: 0.4);
  }

  @override
  Widget build(BuildContext context) {
    if (masks.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      height: 6,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(3),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LayoutBuilder(builder: (ctx, box) {
          return Stack(
            children: [
              Row(
                children: [
                  for (final m in masks)
                    Expanded(
                      child: Container(color: _colorOf(m, scheme)),
                    ),
                ],
              ),
              // 游标
              if (cursor >= 0 && cursor < masks.length)
                Positioned(
                  left: (cursor / masks.length) * box.maxWidth,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 2,
                    color: Colors.white.withValues(alpha: 0.95),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }
}

// ============================================================
// 热图渲染 widget (调用 renderPipeline, 支持融合可见光)
// ============================================================
class _ThermalImage extends StatelessWidget {
  const _ThermalImage({
    required this.thermal,
    required this.width,
    required this.height,
    required this.params,
    this.visibleRgb888,
    this.visibleW = 0,
    this.visibleH = 0,
  });
  final Float32List thermal;
  final int width;
  final int height;
  final RenderParams params;
  final Uint8List? visibleRgb888;
  final int visibleW;
  final int visibleH;

  @override
  Widget build(BuildContext context) {
    final rendered = renderPipeline(
      thermalFrame: thermal,
      srcW: width,
      srcH: height,
      params: params,
      visibleRgb: visibleRgb888,
      visibleW: visibleW,
      visibleH: visibleH,
    );
    return RgbImageView(
      rgb: rendered.rgb,
      width: rendered.width,
      height: rendered.height,
      fit: BoxFit.contain,
    );
  }
}

// ============================================================
// 横排参数行 (复制 photo_download_tab.dart 同款风格)
// ============================================================
const Map<String, String> _colormapZh = {
  'jet': '喷流',
  'hot': '热焰',
  'cool': '冷蓝',
  'gray': '灰度',
  'rainbow': '彩虹',
  'viridis': '翠绿',
  'plasma': '等离子',
  'inferno': '炽焰',
};

class _ParamsRow extends StatelessWidget {
  const _ParamsRow({
    required this.hasVisible,
    required this.params,
    required this.onParamsChanged,
  });
  final bool hasVisible;
  final RenderParams params;
  final ValueChanged<RenderParams> onParamsChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget label(String t) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(t,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant)),
        );

    final row1 = <Widget>[
      label('颜色映射'),
      _Dropdown<String>(
        value: _colormapZh.containsKey(params.colormapName)
            ? params.colormapName
            : 'jet',
        items: _colormapZh.keys.toList(),
        onChanged: (v) => onParamsChanged(
            params.copyWith(colormapName: v, useCustomColors: false)),
        labelOf: (v) => _colormapZh[v] ?? v,
      ),
      const SizedBox(width: 14),
      label('上采样'),
      _Dropdown<int>(
        value: const [1, 2, 4, 8, 16].contains(params.upsampleScale)
            ? params.upsampleScale
            : 8,
        items: const [1, 2, 4, 8, 16],
        onChanged: (v) => onParamsChanged(params.copyWith(upsampleScale: v)),
        labelOf: (v) => '${v}x',
      ),
      const SizedBox(width: 14),
      // 双边滤波: 紧凑 FilterChip, 避免大 Switch 显得不协调.
      FilterChip(
        label: const Text('双边滤波', style: TextStyle(fontSize: 11)),
        selected: params.bilateralEnabled,
        showCheckmark: true,
        visualDensity: const VisualDensity(horizontal: -2, vertical: -3),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: -2),
        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
        onSelected: (v) =>
            onParamsChanged(params.copyWith(bilateralEnabled: v)),
      ),
      if (hasVisible) ...[
        const SizedBox(width: 14),
        label('融合模式'),
        _Dropdown<FusionMode>(
          value: params.fusion.mode,
          items: FusionMode.values,
          onChanged: (v) => onParamsChanged(params.copyWith(
              fusion: params.fusion.copyWith(mode: v))),
          labelOf: (v) => switch (v) {
            FusionMode.off => '关闭',
            FusionMode.blend => '混合',
            FusionMode.edge => '边缘',
          },
        ),
      ],
    ];

    final row2 = <Widget>[];
    if (hasVisible && params.fusion.mode != FusionMode.off) {
      final f = params.fusion;
      if (f.mode == FusionMode.blend) {
        row2.addAll([
          _slider(context,
              title: '混合度',
              value: f.alpha,
              min: 0,
              max: 1,
              onChanged: (v) => onParamsChanged(
                  params.copyWith(fusion: f.copyWith(alpha: v)))),
          _slider(context,
              title: '伽马值',
              value: f.gamma,
              min: 0.3,
              max: 3.0,
              onChanged: (v) => onParamsChanged(
                  params.copyWith(fusion: f.copyWith(gamma: v)))),
        ]);
      } else if (f.mode == FusionMode.edge) {
        row2.addAll([
          _slider(context,
              title: '伽马值',
              value: f.gamma,
              min: 0.3,
              max: 3.0,
              onChanged: (v) => onParamsChanged(
                  params.copyWith(fusion: f.copyWith(gamma: v)))),
          _slider(context,
              title: '强度',
              value: f.edgeStrength,
              min: 0,
              max: 1,
              onChanged: (v) => onParamsChanged(
                  params.copyWith(fusion: f.copyWith(edgeStrength: v)))),
          _slider(context,
              title: '阈值',
              value: f.edgeThresh,
              min: 0,
              max: 0.5,
              digits: 3,
              onChanged: (v) => onParamsChanged(
                  params.copyWith(fusion: f.copyWith(edgeThresh: v)))),
          _slider(context,
              title: '粗细',
              value: f.edgeWidth,
              min: 0,
              max: 6,
              onChanged: (v) => onParamsChanged(
                  params.copyWith(fusion: f.copyWith(edgeWidth: v)))),
        ]);
      }
    }

    Widget shell(List<Widget> kids) => Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: kids,
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        shell(row1),
        if (row2.isNotEmpty) ...[
          const SizedBox(height: 6),
          shell(row2),
        ],
      ],
    );
  }

  Widget _slider(BuildContext ctx,
      {required String title,
      required double value,
      required double min,
      required double max,
      required ValueChanged<double> onChanged,
      int digits = 2}) {
    final scheme = Theme.of(ctx).colorScheme;
    return SizedBox(
      width: 230,
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(title,
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(ctx).copyWith(
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              value.toStringAsFixed(digits),
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelOf,
  });
  final T value;
  final List<T> items;
  final void Function(T) onChanged;
  final String Function(T)? labelOf;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isDense: true,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        items: [
          for (final it in items)
            DropdownMenuItem<T>(
              value: it,
              child: Text(labelOf?.call(it) ?? it.toString()),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

// ============================================================
// 画面叠加: 右上角小圆按钮 (可见光显隐切换等).
// ============================================================
class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

// ============================================================
// 画面叠加: 底部半透明视频控件 (播放/暂停 + 帧信息 + 进度).
// 仿 Web 视频播放器风格, 减少占用画面外的额外纵向空间.
// ============================================================
class _VideoOverlay extends StatelessWidget {
  const _VideoOverlay({
    required this.playing,
    required this.frameIndex,
    required this.frameCount,
    required this.tsMs,
    required this.onToggle,
    required this.onSeek,
  });
  final bool playing;
  final int frameIndex;
  final int frameCount;
  final int tsMs;
  final VoidCallback onToggle;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.55),
              Colors.black.withValues(alpha: 0.7),
            ],
            stops: const [0, 0.4, 1],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(4, 12, 8, 4),
        child: Row(
          children: [
            InkResponse(
              onTap: onToggle,
              radius: 20,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 22,
                  color: Colors.white,
                ),
              ),
            ),
            SizedBox(
              width: 88,
              child: Text(
                '${frameIndex + 1}/$frameCount  ${tsMs}ms',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  min: 0,
                  max: (frameCount - 1).toDouble(),
                  divisions: frameCount > 1 ? frameCount - 1 : null,
                  value: frameIndex
                      .toDouble()
                      .clamp(0, (frameCount - 1).toDouble()),
                  onChanged: (v) => onSeek(v.round()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}