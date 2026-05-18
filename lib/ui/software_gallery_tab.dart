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

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../fusion/fusion.dart';
import '../render/render_params.dart';
import '../render/render_pipeline.dart';
import '../storage/capture_package.dart';
import '../storage/capture_service.dart';
import 'widgets/rgb_image_view.dart';

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          '批量删除完成: 成功 $success${fail > 0 ? ", 失败 $fail" : ""}'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    softwareGalleryRefreshTrigger.addListener(_onTrigger);
  }

  @override
  void dispose() {
    softwareGalleryRefreshTrigger.removeListener(_onTrigger);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文件名非法')),
      );
      return;
    }
    try {
      final dir = p.dirname(it.path);
      final newPath = p.join(dir, '$newBase.btpkg');
      if (newPath == it.path) return;
      if (await File(newPath).exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('同名文件已存在')),
        );
        return;
      }
      await File(it.path).rename(newPath);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重命名失败: $e')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ----- 元数据 chips 卡 (紧凑) -----
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DefaultTextStyle(
            style: TextStyle(fontSize: 11.5, color: scheme.onSurface),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: metaChips,
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
                      // 主画面: 按帧槽位分支.
                      Positioned.fill(
                        child: Center(
                          child: _buildMainPreview(
                            f: f,
                            meta: meta,
                            params: params,
                            scheme: scheme,
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
        child: _ThermalImage(
          thermal: f.thermal!,
          width: meta.thermalW,
          height: meta.thermalH,
          params: params,
          visibleRgb888: useFusionRgb,
          visibleW: useFusionRgb != null ? _visW : 0,
          visibleH: useFusionRgb != null ? _visH : 0,
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