/// 软件图库 tab: 仅消费 `<Documents>/BananaThermalStudio/SoftwareGallery`
/// 目录下的 `.btpkg`. 与设备图库 (PhotoDownloadTab) 物理 + 数据通路完全隔离.
///
/// 功能:
/// - 列表: 显示包名 / 创建时间 / 文件大小 / 帧数 / GPS 标识 / 备注.
/// - 详情: 选中一项后渲染首帧热成像 + 显示元数据; 视频包提供帧滑块.
/// - 操作: 重命名 (改文件名, 不动包内容) / 编辑备注 (改包内 meta) / 删除.
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

/// 全局软件图库刷新触发器: GalleryShell 在副tab 切到"软件图库"时 ++,
/// 已挂载的 SoftwareGalleryTab 监听后自动重扫目录.
/// 也可在拍摄/录制结束后从外部 ++ 触发列表更新.
final ValueNotifier<int> softwareGalleryRefreshTrigger = ValueNotifier<int>(0);

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
    if (!mounted) return;
    _refresh();
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
        // 维持选中 (按 path 匹配), 失效则取消.
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

  Future<void> _onRename(SoftwareGalleryItem it) async {
    final ctrl = TextEditingController(text: p.basenameWithoutExtension(it.name));
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
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
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
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存')),
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
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isWide = MediaQuery.of(context).size.width >= 720;
    final list = _buildList(scheme);
    if (!isWide) {
      // 窄屏: 列表为主, 选中后弹底部 sheet 看详情.
      return list;
    }
    return Row(
      children: [
        SizedBox(width: 320, child: list),
        const VerticalDivider(width: 1),
        Expanded(
          child: _selected == null
              ? Center(
                  child: Text(
                    '左侧选择一个数据包查看详情',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : _DetailView(
                  key: ValueKey(_selected!.path),
                  item: _selected!,
                  onRename: () => _onRename(_selected!),
                  onEditNote: () => _onEditNote(_selected!),
                  onDelete: () => _onDelete(_selected!),
                ),
        ),
      ],
    );
  }

  Widget _buildList(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Icon(Icons.collections_bookmark_rounded,
                  color: scheme.primary, size: 18),
              const SizedBox(width: 8),
              Text('软件图库',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface)),
              const Spacer(),
              Text('${_items.length} 项',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                onPressed: _loading ? null : _refresh,
                tooltip: '刷新',
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_error!, style: TextStyle(color: scheme.error)),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
                  ? Center(
                      child: Text(
                        '空空如也\n在实时画面用拍摄/录制按钮新建',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final it = _items[i];
                        final selected = _selected?.path == it.path;
                        final type = it.packageType == 1 ? '视频' : '照片';
                        final note = (it.meta?.note ?? '').trim();
                        final place = (it.meta?.place ?? '').trim();
                        return ListTile(
                          selected: selected,
                          dense: true,
                          leading: Icon(
                            it.packageType == 1
                                ? Icons.videocam_rounded
                                : Icons.photo_rounded,
                            color: scheme.primary,
                          ),
                          title: Text(it.name, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '$type · ${_fmtSize(it.sizeBytes)} · ${_fmtTime(it.mtime)}'
                            '${it.meta?.frameCount != null ? ' · ${it.meta!.frameCount}帧' : ''}'
                            '\n📍 ${place.isEmpty ? '位置未知' : place}'
                            '${note.isEmpty ? '' : '\n$note'}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () async {
                            setState(() => _selected = it);
                            if (!isWideOf(context)) {
                              await _openDetailSheet(it);
                            }
                          },
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              switch (v) {
                                case 'rename':
                                  _onRename(it);
                                  break;
                                case 'note':
                                  _onEditNote(it);
                                  break;
                                case 'delete':
                                  _onDelete(it);
                                  break;
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'rename', child: Text('重命名')),
                              PopupMenuItem(value: 'note', child: Text('编辑备注')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  bool isWideOf(BuildContext context) =>
      MediaQuery.of(context).size.width >= 720;

  Future<void> _openDetailSheet(SoftwareGalleryItem it) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SizedBox(
        height: MediaQuery.of(c).size.height * 0.85,
        child: _DetailView(
          item: it,
          onRename: () async {
            Navigator.pop(c);
            await _onRename(it);
          },
          onEditNote: () async {
            Navigator.pop(c);
            await _onEditNote(it);
          },
          onDelete: () async {
            Navigator.pop(c);
            await _onDelete(it);
          },
        ),
      ),
    );
  }
}

class _DetailView extends StatefulWidget {
  const _DetailView({
    super.key,
    required this.item,
    required this.onRename,
    required this.onEditNote,
    required this.onDelete,
  });
  final SoftwareGalleryItem item;
  final VoidCallback onRename;
  final VoidCallback onEditNote;
  final VoidCallback onDelete;

  @override
  State<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<_DetailView> {
  CapturePackageReader? _reader;
  CaptureFrame? _frame;
  // 当前帧的可见光 RGB888 (PNG 解码缓存, 供融合 pipeline 使用).
  Uint8List? _visRgb888;
  int _visRgbW = 0;
  int _visRgbH = 0;
  int _frameIndex = 0;
  bool _loading = false;
  String? _error;

  // 当前用于渲染的参数: 初始来自 meta.renderParams (老包则用 AppState.renderParams),
  // 用户可在 ExpansionTile 内即时修改, 仅影响本详情页, 不写回包.
  RenderParams? _params;

  // 视频播放
  Timer? _playTimer;
  bool _playing = false;

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
      // 初始参数: 包内 renderParams 优先, 否则用当前 AppState 的参数.
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
        await _selectFrameInternal(0);
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '解析失败: $e';
      });
    }
  }

  Future<void> _selectFrameInternal(int i) async {
    final r = _reader;
    if (r == null || i < 0 || i >= r.frameCount) return;
    final f = await r.readFrame(i);
    // 解 PNG → RGB888 用于融合 (空包/无可见光 → 跳过).
    Uint8List? rgb;
    int rgbW = 0, rgbH = 0;
    if (f.visiblePng.isNotEmpty) {
      try {
        final im = img.decodePng(f.visiblePng);
        if (im != null) {
          rgb = im.getBytes(order: img.ChannelOrder.rgb);
          rgbW = im.width;
          rgbH = im.height;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _frame = f;
      _visRgb888 = rgb;
      _visRgbW = rgbW;
      _visRgbH = rgbH;
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
    // 推断帧间隔: 用第一第二帧 ts 差 (毫秒). 取不到则按 100ms.
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
        await _selectFrameInternal(next);
      });
      setState(() => _playing = true);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.item.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: widget.onRename,
                  icon: const Icon(Icons.drive_file_rename_outline_rounded),
                  tooltip: '重命名',
                ),
                IconButton(
                  onPressed: widget.onEditNote,
                  icon: const Icon(Icons.edit_note_rounded),
                  tooltip: '编辑备注',
                ),
                IconButton(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: '删除',
                  color: scheme.error,
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: TextStyle(color: scheme.error)),
                      )
                    : _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final reader = _reader;
    final frame = _frame;
    final params = _params;
    if (reader == null || frame == null || params == null) {
      return const Center(child: Text('无可用帧'));
    }
    final scheme = Theme.of(context).colorScheme;
    final meta = reader.meta;
    final hasVis = meta.visibleW > 0 && meta.visibleH > 0;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      children: [
        AspectRatio(
          aspectRatio: meta.thermalW / meta.thermalH,
          child: _ThermalImage(
            thermal: frame.thermal,
            width: meta.thermalW,
            height: meta.thermalH,
            params: params,
            visibleRgb888: _visRgb888,
            visibleW: _visRgbW,
            visibleH: _visRgbH,
          ),
        ),
        if (hasVis && frame.visiblePng.isNotEmpty) ...[
          const SizedBox(height: 8),
          _MetaTile(
              label: '可见光帧',
              value: '${frame.visiblePng.length ~/ 1024} KB PNG'),
          Image.memory(frame.visiblePng, fit: BoxFit.contain),
        ] else ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    color: scheme.onSurfaceVariant, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '此次拍摄未保存可见光画面 (拍摄/录制时未开启可见光推流). '
                    '后续拍摄请先在实时画面打开可见光摄像头.',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (reader.type == CapturePackageHeader.typeVideo &&
            reader.frameCount > 1) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(_playing
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_filled_rounded),
                iconSize: 32,
                color: scheme.primary,
                tooltip: _playing ? '暂停' : '播放',
              ),
              Expanded(
                child: Text(
                  '帧 ${_frameIndex + 1} / ${reader.frameCount}  · ts ${frame.tsMs}ms',
                ),
              ),
            ],
          ),
          Slider(
            min: 0,
            max: (reader.frameCount - 1).toDouble(),
            divisions: reader.frameCount - 1,
            value: _frameIndex
                .toDouble()
                .clamp(0, (reader.frameCount - 1).toDouble()),
            onChanged: (v) {
              if (_playing) {
                _playTimer?.cancel();
                _playTimer = null;
                setState(() => _playing = false);
              }
              _selectFrameInternal(v.round());
            },
          ),
        ],
        const Divider(),
        _MetaTile(label: '创建时间', value: meta.createdAt.toLocal().toString()),
        if (meta.deviceSn != null)
          _MetaTile(label: '设备 SN', value: meta.deviceSn!),
        _MetaTile(
          label: '位置',
          value: (meta.place ?? '').isEmpty ? '未知' : meta.place!,
        ),
        if (meta.lat != null && meta.lng != null)
          _MetaTile(
            label: '经纬度',
            value:
                '${meta.lat!.toStringAsFixed(6)}, ${meta.lng!.toStringAsFixed(6)}'
                '${meta.alt != null ? ' · ${meta.alt!.toStringAsFixed(0)}m' : ''}',
          ),
        _MetaTile(
            label: '热成像',
            value:
                '${meta.thermalW} × ${meta.thermalH} · ${reader.frameCount} 帧'),
        if (meta.visibleW > 0)
          _MetaTile(
              label: '可见光', value: '${meta.visibleW} × ${meta.visibleH}'),
        _MetaTile(label: '备注', value: meta.note.isEmpty ? '(空)' : meta.note),
        const SizedBox(height: 12),
        _RenderParamsPanel(
          params: params,
          onChanged: (p) => setState(() => _params = p),
        ),
        _FusionParamsPanel(
          params: params.fusion,
          hasVisible: _visRgb888 != null,
          onChanged: (f) =>
              setState(() => _params = params.copyWith(fusion: f)),
        ),
      ],
    );
  }
}

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

/// 详情页可调"渲染参数"面板 (最小集: colormap / upsampleScale / 双边).
class _RenderParamsPanel extends StatelessWidget {
  const _RenderParamsPanel({required this.params, required this.onChanged});
  final RenderParams params;
  final ValueChanged<RenderParams> onChanged;

  static const _colormaps = [
    'jet', 'inferno', 'viridis', 'plasma', 'gray', 'hot', 'cool',
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        title: const Text('渲染参数'),
        leading: const Icon(Icons.tune_rounded),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Row(
            children: [
              const SizedBox(width: 80, child: Text('色板')),
              Expanded(
                child: DropdownButton<String>(
                  value: _colormaps.contains(params.colormapName)
                      ? params.colormapName
                      : 'jet',
                  isExpanded: true,
                  items: _colormaps
                      .map((m) =>
                          DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) onChanged(params.copyWith(colormapName: v));
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 80, child: Text('上采样')),
              Expanded(
                child: DropdownButton<int>(
                  value: params.upsampleScale,
                  isExpanded: true,
                  items: const [1, 2, 4, 8, 16]
                      .map((s) =>
                          DropdownMenuItem(value: s, child: Text('${s}x')))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) onChanged(params.copyWith(upsampleScale: v));
                  },
                ),
              ),
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('双边滤波'),
            value: params.bilateralEnabled,
            onChanged: (v) =>
                onChanged(params.copyWith(bilateralEnabled: v)),
          ),
        ],
      ),
    );
  }
}

/// 详情页可调"融合参数"面板.
class _FusionParamsPanel extends StatelessWidget {
  const _FusionParamsPanel({
    required this.params,
    required this.hasVisible,
    required this.onChanged,
  });
  final FusionParams params;
  final bool hasVisible;
  final ValueChanged<FusionParams> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        title: const Text('融合参数'),
        leading: const Icon(Icons.layers_rounded),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (!hasVisible)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('当前帧无可见光, 融合参数不会生效.',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          Row(
            children: [
              const SizedBox(width: 80, child: Text('模式')),
              Expanded(
                child: SegmentedButton<FusionMode>(
                  segments: const [
                    ButtonSegment(value: FusionMode.off, label: Text('关')),
                    ButtonSegment(value: FusionMode.blend, label: Text('混合')),
                    ButtonSegment(value: FusionMode.edge, label: Text('边缘')),
                  ],
                  selected: {params.mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      onChanged(params.copyWith(mode: s.first)),
                ),
              ),
            ],
          ),
          if (params.mode == FusionMode.blend) ...[
            _slider(
              label: 'alpha',
              value: params.alpha,
              min: 0,
              max: 1,
              onChanged: (v) => onChanged(params.copyWith(alpha: v)),
            ),
            _slider(
              label: 'gamma',
              value: params.gamma,
              min: 0.2,
              max: 3,
              onChanged: (v) => onChanged(params.copyWith(gamma: v)),
            ),
          ],
          if (params.mode == FusionMode.edge) ...[
            _slider(
              label: '强度',
              value: params.edgeStrength,
              min: 0,
              max: 1,
              onChanged: (v) =>
                  onChanged(params.copyWith(edgeStrength: v)),
            ),
            _slider(
              label: '阈值',
              value: params.edgeThresh,
              min: 0,
              max: 0.5,
              onChanged: (v) =>
                  onChanged(params.copyWith(edgeThresh: v)),
            ),
            _slider(
              label: '粗细',
              value: params.edgeWidth,
              min: 0,
              max: 6,
              onChanged: (v) =>
                  onChanged(params.copyWith(edgeWidth: v)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label)),
        Expanded(
          child: Slider(
            min: min,
            max: max,
            value: value.clamp(min, max),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
            width: 48,
            child: Text(value.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12))),
      ],
    );
  }
}

class _MetaTile extends StatelessWidget {
  const _MetaTile({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 72,
              child: Text(label,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 12))),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

String _fmtSize(int b) {
  if (b < 1024) return '${b}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
}

String _fmtTime(DateTime t) {
  final l = t.toLocal();
  String two(int x) => x.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}
