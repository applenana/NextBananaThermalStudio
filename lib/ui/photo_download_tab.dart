/// 图库 Tab: 拉取设备 flash 中的图片列表, 下载并按协议解析渲染.
///
/// - 进入 tab 自动停止所有推流, 避免帧字节与文件数据混流.
/// - 点击列表项后自动下载 + 解析 + 渲染.
/// - 预览区复用 [ThermalCanvas]: hover 取温 + 点击放置固定温度标记.
/// - 右上角提供颜色映射 / 曲线 / 融合模式下拉 + 清除标记 + 导出 PNG.
/// - 解析逻辑见 [PhotoDecoder] (v1-simple / v1-full / v2/v3-HTPH / JPEG).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../fusion/fusion.dart';
import 'banana_toast.dart';
import 'app_font.dart';
import '../main.dart'
    show
        appPhotoDownloadDir,
        appPhotoDetailOpen,
        appPhotoTabActive,
        appClosePhotoDetail;
import '../protocol/photo_cache_index.dart';
import '../protocol/photo_decoder.dart';
import '../render/render_params.dart';
import '../render/render_pipeline.dart';
import 'widgets/rgb_image_view.dart';
import 'widgets/temp_overlay.dart';
import 'widgets/thermal_canvas.dart';

/// 外部触发图库刷新的通道. 每次 value++ 表示请求一次刷新,
/// 由 [_PhotoDownloadTabState] 监听并在已连接 / 非忙时执行.
final ValueNotifier<int> photoTabRefreshTrigger = ValueNotifier<int>(0);

class PhotoDownloadTab extends StatefulWidget {
  const PhotoDownloadTab({super.key});

  @override
  State<PhotoDownloadTab> createState() => _PhotoDownloadTabState();
}

class _PhotoDownloadTabState extends State<PhotoDownloadTab> {
  List<PhotoMeta> _list = const [];
  PhotoMeta? _selected;
  bool _busy = false;
  String? _statusText;

  /// 下载排队: 一次仅 1 个 in-flight + 1 个 pending. 用户连点 A→B→C:
  /// A 处理中, _pending 由 B 替换为 C, B 任务直接丢弃, A 完毕后接 C.
  PhotoMeta? _pendingDownload;

  Uint8List? _raw;
  PhotoDecoded? _decoded;

  /// 图库预览专用的临时渲染参数: 每张图独立, 不与实时投屏共享
  /// [AppState.renderParams]. 点开一张新图时重置为默认值; 如果是双光图
  /// (visibleRgb 非空) 则解码完成后自动将 fusion 模式升为 blend.
  /// 用户在预览详情里调参只影响本页, 切图 / 退出后丝毫不注入实时面板.
  RenderParams _photoParams = const RenderParams();
  bool _photoThermalViewApplied = false;

  /// 用户点击固定的温度标记 (坐标以渲染后帧像素为准).
  final List<TempMarker> _markers = [];

  /// 可见光小窗显示开关 (默认隐藏, 主视图只显示热成像).
  bool _showVisible = false;

  /// 详情页温度叠加 (左上角 MAX/MIN/AVG 半透明胶囊) 开关, 默认开.
  bool _tempOverlayEnabled = true;

  /// 详情页顶部“详细元数据”是否展开 (默认折叠, 只显单行摘要).
  bool _metaExpanded = false;

  /// 单次会话缓存: filename → (raw, decoded, thumb).
  /// 仅当前 tab state 生命周期内生效, 刷新按钮 / dispose 都会清空.
  /// 与位于磁盘 raw/ 目录 + sha256 指纹的「持久缓存」 (PhotoCacheIndex) 互不干涉.
  final Map<String, _PhotoSessionEntry> _session =
      <String, _PhotoSessionEntry>{};

  /// 下载阶段描述: 请求中 / 接收数据 / 解析中 / 完成.
  String? _stage;

  /// 上次触发部分解码时累计字节, 用于节流避免每个 packet 都解析.
  int _lastPartialBytes = 0;

  int _progress = 0;
  int _progressTotal = 0;

  /// Android 手机上是否处于详情页 (true=详情全屏, false=列表全屏).
  /// 桌面不走这个状态 (一直是左右分栏).
  bool _phoneShowDetail = false;

  /// 切换详情页并同步全局 [appPhotoDetailOpen] 状态, 供返回键拦截判断.
  void _setPhoneShowDetail(bool v) {
    if (_phoneShowDetail == v) return;
    setState(() => _phoneShowDetail = v);
    appPhotoDetailOpen.value = v;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // bug 修复: 旋转 (例 全屏入场) 会让 home_shell LayoutBuilder 从 narrow
      // 切到 wide, IndexedStack 父级重建导致所有 children 重 mount,
      // 此 initState 再次跑会无差别 stopAllStreams() 关掉用户正在使用的
      // 实时 tab 推流. 守门: 仅当用户当前确实在图库 tab 才停推流.
      if (!appPhotoTabActive.value) return;
      context.read<AppState>().stopAllStreams();
    });
    photoTabRefreshTrigger.addListener(_onExternalRefresh);
    // 注册全局关闭回调, 供 Android 系统返回键拦截调用.
    appClosePhotoDetail = () {
      if (!mounted) return;
      if (_phoneShowDetail) _setPhoneShowDetail(false);
    };
  }

  @override
  void dispose() {
    photoTabRefreshTrigger.removeListener(_onExternalRefresh);
    appClosePhotoDetail = null;
    appPhotoDetailOpen.value = false;
    _clearSession();
    super.dispose();
  }

  /// 清空单次缓存 + dispose 所有缩略图 ui.Image.
  /// 不调 setState —— 调用方 (_refresh / dispose) 自行决定是否重建画面.
  void _clearSession() {
    for (final e in _session.values) {
      e.thumb?.dispose();
    }
    _session.clear();
  }

  /// 把刚下完的 raw + decoded 写入单次缓存, 并异步生成列表缩略图.
  void _storeSession(PhotoMeta sel, Uint8List raw, PhotoDecoded dec) {
    final entry = _PhotoSessionEntry(raw: raw, decoded: dec);
    _session[sel.filename] = entry;
    if (dec.thermal != null) {
      entry.thermalAvgC = computeAvgC(dec.thermal!);
    }
    // ignore: unawaited_futures
    _buildSessionThumb(sel.filename);
  }

  /// 为单次缓存条目异步渲染列表缩略图: 优先热成像, 退化到 JPEG.
  Future<void> _buildSessionThumb(String key) async {
    final entry = _session[key];
    if (entry == null) return;
    final dec = entry.decoded;
    try {
      ui.Image? img;
      if (dec.thermal != null) {
        // 列表缩略 —— 关掉融合, 只展示热成像本身. 颜色映射沿用当前图片页,
        // 但每张照片必须使用自己随文件保存的热像视图, 不能被当前选中图片污染.
        final thumbParams = _photoParams.copyWith(
          thermalView: dec.thermalView ?? const ThermalViewParams(),
        );
        final r = renderPipeline(
          thermalFrame: dec.thermal!,
          srcW: dec.srcW,
          srcH: dec.srcH,
          params: thumbParams,
          visibleRgb: null,
          visibleW: 0,
          visibleH: 0,
          minOverride: dec.tMin,
          maxOverride: dec.tMax,
        );
        img = await _rgbToUiImage(r.rgb, r.width, r.height);
      } else if (dec.jpegBytes != null) {
        final codec = await ui.instantiateImageCodec(
          dec.jpegBytes!,
          targetWidth: 96,
        );
        final frame = await codec.getNextFrame();
        img = frame.image;
      }
      if (!mounted || img == null) {
        img?.dispose();
        return;
      }
      // tab dispose 之后 _session 已 clear, 这里写入会变成野指针, 守一下:
      final cur = _session[key];
      if (cur == null) {
        img.dispose();
        return;
      }
      cur.thumb?.dispose();
      cur.thumb = img;
      setState(() {});
    } catch (_) {
      // 缩略图失败不阻断主流程, 列表保留索引数字.
    }
  }

  Future<ui.Image> _rgbToUiImage(Uint8List rgb888, int w, int h) async {
    final rgba = Uint8List(w * h * 4);
    for (var i = 0, j = 0; i < rgb888.length; i += 3, j += 4) {
      rgba[j] = rgb888[i];
      rgba[j + 1] = rgb888[i + 1];
      rgba[j + 2] = rgb888[i + 2];
      rgba[j + 3] = 255;
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  void _onExternalRefresh() {
    if (!mounted) return;
    // 切到图库 tab 时, Android 端强制回到列表视图 (而非停留在详情页).
    // 桌面端不走 _phoneShowDetail.
    if (_phoneShowDetail) _setPhoneShowDetail(false);
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) return;
    if (_busy) return;
    _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    final app = context.read<AppState>();
    if (app.status != ConnectionStatus.connected) {
      _toast('请先连接串口');
      return;
    }
    setState(() {
      _busy = true;
      _statusText = '正在获取列表 ...';
      // 刷新即销毁单次会话缓存 (列表缩略图 + 已下载 raw/decoded), 但保留
      // 位于磁盘 + sha256 指纹的「持久缓存」, 让命中热成像头数据时依旧秒拉.
      _clearSession();
    });
    // 进入图库后, 心跳 stream 字节还会陆续到达 ~1s 才停, 此时 check 响应可能
    // 被污染 (FormatException) 或被 stream 帧填满缓冲 (TimeoutException).
    // 策略: 最多重试 _maxRefreshAttempts 次, 每次失败等 1s 让残余字节排空再发.
    const maxAttempts = 8;
    const retryWait = Duration(seconds: 1);
    Object? lastErr;
    try {
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        if (!mounted) return;
        // 用户已经切走图库 tab: 立即放弃, 让 HomeShell 的"恢复推流"逻辑生效.
        if (!appPhotoTabActive.value) {
          lastErr = StateError('已切换 tab');
          break;
        }
        if (app.status != ConnectionStatus.connected) {
          lastErr = StateError('已断开');
          break;
        }
        // 每次 attempt 前先停推流: 覆盖 Android 自动重连成功后再次开流的情形,
        // 同时给设备 ~200ms 排空残余字节, 减少 check 响应被污染的概率.
        app.stopAllStreams();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        try {
          final res = await app.fetchPhotoList();
          if (!mounted) return;
          setState(() {
            _list = res;
            _statusText = '共 ${res.length} 张';
            if (_selected != null) {
              _selected = res.firstWhere(
                (e) => e.filename == _selected!.filename,
                orElse: () => res.isNotEmpty ? res.first : _selected!,
              );
            }
          });
          return;
        } on TimeoutException catch (e) {
          lastErr = e;
        } on FormatException catch (e) {
          lastErr = e;
        } catch (e) {
          lastErr = e;
          rethrow;
        }
        if (mounted) {
          setState(() {
            _statusText = '等待设备响应 ... ($attempt/$maxAttempts)';
          });
        }
        await Future<void>.delayed(retryWait);
      }
      if (!mounted) return;
      setState(() => _statusText = '失败: $lastErr');
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = '失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 排队入口: 任意时刻调用. 若当前已有 download 在跑, 把 _pendingDownload
  /// 替换为最新选择 (旧 pending 直接丢弃); 否则启动 dispatch loop.
  Future<void> _download() async {
    final sel = _selected;
    if (sel == null) return;
    // 单次会话缓存命中: 跳过设备 IO + 协议解析, 直接复用上次的 raw + decoded.
    // 注意此处不读「持久缓存」(那条路径在 _doDownload 中由 fetchPhotoBytes 命中),
    // 这里只关心同一次 tab state 内反复点同一张图的秒开体验.
    final hit = _session[sel.filename];
    if (hit != null && !_busy) {
      if (!mounted) return;
      setState(() {
        _selected = sel;
        _raw = hit.raw;
        _decoded = hit.decoded;
        _markers.clear();
        _resetPhotoParams();
        _applyDecodedPhotoParams(hit.decoded);
        _statusText = '秒开 · 内存缓存 · ${sel.filename}';
        _stage = '完成';
        _progress = hit.raw.length;
        _progressTotal = hit.raw.length;
      });
      return;
    }
    if (_busy) {
      // 排队: 替换 pending. 旧 pending 不再处理.
      if (!mounted) return;
      setState(() {
        _pendingDownload = sel;
        _statusText = '排队中 · ${sel.filename}';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final app = context.read<AppState>();
    PhotoMeta? cur = sel;
    try {
      while (cur != null && mounted) {
        // 进入处理前: 清掉指向自己的 pending (若有), 进入下一个时再读 _pendingDownload.
        if (_pendingDownload?.filename == cur.filename) {
          _pendingDownload = null;
        }
        await _doDownload(cur);
        if (!mounted) break;
        // 等设备发完 END FILE DATA, 释放 _photoMode, 否则下一次 download 抛 "图库忙".
        try {
          await app.waitForPhotoIdle();
        } catch (_) {}
        // 取下一个: 若 pending 仍在则继续, 否则结束 loop.
        cur = _pendingDownload;
        _pendingDownload = null;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 实际下载一张图. 不管理 _busy / 排队, 由 [_download] dispatch loop 负责.
  Future<void> _doDownload(PhotoMeta sel) async {
    final app = context.read<AppState>();
    if (!mounted) return;
    setState(() {
      _selected = sel;
      _stage = '请求文件…';
      _statusText = '下载中 · ${sel.filename}';
      _raw = null;
      _decoded = null;
      _progress = 0;
      _progressTotal = sel.size;
      _lastPartialBytes = 0;
      _markers.clear();
      // 点击新图: 重置预览参数为默认值, 不使用上一张图、也不使用实时面板的任何状态.
      _resetPhotoParams();
    });
    // 缓存指纹联动: onEarlyBytes 累计到 ~4 KB 时算 sha256 查 index,
    // 命中即调 abortPhotoDownload, 主流程 catch PhotoDownloadAbortedException
    // 后读 raw/ 缓存秒开. shaC 用于完成后补写 index.
    final root = await _ensureRoot();
    final shaC = Completer<String>();
    final hitC = Completer<PhotoCacheEntry?>();
    try {
      final data = await app.downloadPhoto(
        sel.filename,
        sel.size,
        onProgress: (r, t) {
          if (!mounted) return;
          // 阶段切换: 首包到达 → 接收数据.
          final newStage = (r > 0) ? '接收数据' : '请求文件…';
          setState(() {
            _progress = r;
            _progressTotal = t;
            _stage = newStage;
          });
          _tryPartialDecode(sel);
        },
        onEarlyBytes: (head) {
          () async {
            // HTPH v3 的缩放/偏移在文件尾，前 4 KB 不足以唯一识别照片。
            // 必须收完整文件后再计算“头 + 尾”指纹，避免错误复用另一张图。
            if (PhotoCacheIndex.requiresCompleteFile(head)) {
              if (!hitC.isCompleted) hitC.complete(null);
              return;
            }
            final sha = PhotoCacheIndex.fingerprint(head);
            if (!shaC.isCompleted) shaC.complete(sha);
            try {
              final idx = await PhotoCacheIndex.open(root);
              final hit = await idx.lookup(sha);
              if (hit != null) {
                app.abortPhotoDownload();
                if (!hitC.isCompleted) hitC.complete(hit);
              } else {
                if (!hitC.isCompleted) hitC.complete(null);
              }
            } catch (_) {
              if (!hitC.isCompleted) hitC.complete(null);
            }
          }();
        },
      );

      if (!mounted) return;
      setState(() {
        _stage = '解析中…';
      });

      // 保存原始
      final dir = await _ensureRawDir();
      final outFile = File(p.join(dir.path, sel.filename));
      await outFile.writeAsBytes(data);

      // 写 / 更新缓存索引. 小文件 (<4KB) onEarlyBytes 不会触发, 这里兜底算指纹.
      String sha;
      if (shaC.isCompleted) {
        sha = await shaC.future;
      } else {
        sha = PhotoCacheIndex.fingerprint(data);
      }
      try {
        final idx = await PhotoCacheIndex.open(root);
        await idx.remember(sha, sel.filename, sel.size);
      } catch (_) {}

      // 解析 (渲染在 build 中实时计算, 以响应参数变化)
      final dec = PhotoDecoder.decode(data, sel);

      if (!mounted) return;
      setState(() {
        _raw = data;
        _decoded = dec;
        _markers.clear();
        _applyDecodedPhotoParams(dec);
        _stage = '完成';
        _statusText = '已保存: ${outFile.path}  ·  ${dec.summary}';
      });
      _storeSession(sel, data, dec);
    } on PhotoDownloadAbortedException {
      // 缓存命中路径: 从本地 raw 加载 + 解析 + 渲染.
      if (!mounted) return;
      PhotoCacheEntry? hit;
      try {
        hit = await hitC.future.timeout(const Duration(seconds: 5));
      } catch (_) {}
      if (hit == null) {
        if (!mounted) return;
        setState(() {
          _stage = '失败';
          _statusText = '缓存读取失败 (索引超时)';
        });
        return;
      }
      try {
        final dir = await _ensureRawDir();
        final f = File(p.join(dir.path, hit.filename));
        final cached = await f.readAsBytes();
        final dec = PhotoDecoder.decode(cached, sel);
        if (!mounted) return;
        setState(() {
          _raw = cached;
          _decoded = dec;
          _markers.clear();
          _applyDecodedPhotoParams(dec);
          _progress = cached.length;
          _progressTotal = cached.length;
          _stage = '完成';
          _statusText = '秒开 · 命中缓存 (${hit!.filename})  ·  ${dec.summary}';
        });
        _storeSession(sel, cached, dec);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _stage = '失败';
          _statusText = '缓存读取失败: $e';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = '失败';
        _statusText = '下载失败: $e';
      });
    }
  }

  /// 划到一张新图时调用: 重置 _photoParams 为默认值 (不读任何实时面板状态).
  /// 解码完成后可再调 [_applyDecodedPhotoParams] 合入照片自带的热像视图.
  void _resetPhotoParams() {
    _photoParams = const RenderParams();
    _photoThermalViewApplied = false;
  }

  /// 把照片文件自身的设备视图参数应用到图片页的独立 RenderParams.
  ///
  /// 仅首次合入，避免分块下载的多次部分解码覆盖用户随后在详情页做的调整。
  /// v1/v2 没有该元数据时维持旧行为；它们不会借用实时页当前激活的参数。
  void _applyDecodedPhotoParams(PhotoDecoded dec) {
    if (!_photoThermalViewApplied && dec.thermalView != null) {
      _photoParams = _photoParams.copyWith(thermalView: dec.thermalView);
      _photoThermalViewApplied = true;
    }
    if (dec.visibleRgb != null && _photoParams.fusion.mode == FusionMode.off) {
      _photoParams = _photoParams.copyWith(
        fusion: const FusionParams(mode: FusionMode.blend),
      );
    }
  }

  /// 节流型的部分解码: 每收到 >= 8KB 增量或 越过 50% 进度时调一次,
  /// 让热成像画面在下载完成前就出现.
  void _tryPartialDecode(PhotoMeta sel) {
    final app = context.read<AppState>();
    final buf = app.photoPartialBytes;
    if (buf == null || buf.length < 32) return;
    if (buf.length - _lastPartialBytes < 8 * 1024 &&
        buf.length < _progressTotal) {
      return;
    }
    _lastPartialBytes = buf.length;
    final dec = PhotoDecoder.decode(buf, sel);
    if (dec.format == PhotoFormat.unknown) return;
    if (!mounted) return;
    setState(() {
      _raw = buf;
      _decoded = dec;
      _applyDecodedPhotoParams(dec);
    });
  }

  Future<Directory> _ensureRawDir() async {
    final root = await _ensureRoot();
    final dir = Directory(p.join(root.path, 'raw'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 返回用户配置的下载根目录, 或默认 `<Documents>/BananaThermalStudio`.
  Future<Directory> _ensureRoot() async {
    final custom = appPhotoDownloadDir.value;
    final root = (custom != null && custom.isNotEmpty)
        ? Directory(custom)
        : Directory(
            p.join(
              (await getApplicationDocumentsDirectory()).path,
              'BananaThermalStudio',
            ),
          );
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  void _toast(String msg) {
    if (!mounted) return;
    BananaToast.show(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    // Android 手机: 列表 / 详情单页切换, 两者之间用 fade+scale 动画.
    // Android 平板 (宽屏): 走桌面同款双栏布局, 抛弃 phone 单页切换栈.
    if (Platform.isAndroid) {
      return LayoutBuilder(
        builder: (context, c) {
          // 安卓平板横屏 (主区宽 > 760) 走双栏; 手机/平板竖屏走 phone 切换栈.
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
                    key: const ValueKey('photo-detail'),
                    child: _buildDetailCard(phone: true),
                  )
                : KeyedSubtree(
                    key: const ValueKey('photo-list'),
                    child: _buildListCard(phone: true),
                  ),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
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
      },
    );
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
                const Icon(Icons.photo_library_rounded, size: 18),
                const SizedBox(width: 8),
                const Text(
                  '设备图库',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('刷新'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_statusText != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _statusText!,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            Expanded(
              child: _list.isEmpty
                  ? Center(
                      child: Text(
                        _busy ? '加载中...' : '点击刷新获取设备图片列表',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (_, i) {
                        final e = _list[i];
                        final isSel = _selected?.filename == e.filename;
                        return _PhotoTile(
                          meta: e,
                          selected: isSel,
                          queued: _pendingDownload?.filename == e.filename,
                          thumb: _session[e.filename]?.thumb,
                          onTap: () {
                            // 任意时刻可点. 切到新图先清画面, 避免旧帧残留 + 新元数据混淆.
                            setState(() {
                              _selected = e;
                              // 重置预览参数: 上一张图调过的参数不应带到下一张.
                              _resetPhotoParams();
                              if (_busy) {
                                // 排队场景: 等待时不展示旧画面.
                                _raw = null;
                                _decoded = null;
                                _markers.clear();
                              }
                            });
                            if (phone) _setPhoneShowDetail(true);
                            _download();
                          },
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
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const Spacer(),
                if (_decoded?.thermal != null) ...[
                  if (_decoded?.visibleRgb != null)
                    IconButton(
                      tooltip: _showVisible ? '隐藏可见光小窗' : '显示可见光小窗',
                      onPressed: () =>
                          setState(() => _showVisible = !_showVisible),
                      icon: Icon(
                        _showVisible
                            ? Icons.image_rounded
                            : Icons.image_outlined,
                        size: 18,
                      ),
                    ),
                  IconButton(
                    tooltip: '清除所有温度标记',
                    onPressed: _markers.isEmpty
                        ? null
                        : () => setState(() => _markers.clear()),
                    icon: const Icon(Icons.layers_clear_rounded, size: 18),
                  ),
                  IconButton(
                    tooltip: '导出 PNG',
                    onPressed: _busy ? null : _exportPng,
                    icon: const Icon(Icons.save_alt_rounded, size: 18),
                  ),
                ],
                if (sel != null && _raw == null && _busy == false)
                  FilledButton.icon(
                    onPressed: _download,
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: const Text('重试下载'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (sel == null)
              Expanded(
                child: Center(
                  child: Text(
                    '在左侧选择一张图片',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            else
              Expanded(child: _buildDetailBody(sel, phone: phone)),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailBody(PhotoMeta sel, {bool phone = false}) {
    final scheme = Theme.of(context).colorScheme;
    // 实时根据参数重新渲染 (点下拉后预览立即变化).
    final dec = _decoded;
    RenderedFrame? rendered;
    if (dec?.thermal != null) {
      rendered = renderPipeline(
        thermalFrame: dec!.thermal!,
        srcW: dec.srcW,
        srcH: dec.srcH,
        params: _photoParams,
        visibleRgb: dec.visibleRgb,
        visibleW: dec.visW,
        visibleH: dec.visH,
        minOverride: dec.tMin,
        maxOverride: dec.tMax,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMetaCard(sel, dec, rendered, scheme),
        if (rendered != null) ...[
          const SizedBox(height: 10),
          _ParamsRow(
            hasVisible: dec?.visibleRgb != null,
            phone: phone,
            params: _photoParams,
            onParamsChanged: (v) => setState(() => _photoParams = v),
          ),
        ],
        const SizedBox(height: 10),
        if (_busy && _progressTotal > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      _stage ?? '下载中',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_fmtSize(_progress)} / ${_fmtSize(_progressTotal)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(_progress * 100 / (_progressTotal == 0 ? 1 : _progressTotal)).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _progressTotal == 0
                        ? null
                        : _progress / _progressTotal,
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(child: _buildPreview(rendered)),
                // 右上角: 叠加开关按钮 (只在能显示叠加时出现).
                // 注意: TempOverlay 已移动到 _buildPreview 内部, 贴在真实
                // 画面 rect 左上角 (与导出图保持一致); 这里仅保留控制按钮.
                if (rendered != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.42),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(
                          () => _tempOverlayEnabled = !_tempOverlayEnabled,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            _tempOverlayEnabled
                                ? Icons.thermostat
                                : Icons.thermostat_outlined,
                            size: 16,
                            color: _tempOverlayEnabled
                                ? const Color(0xFFFF6E40)
                                : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(RenderedFrame? r) {
    final scheme = Theme.of(context).colorScheme;
    if (_raw == null) {
      if (!_busy) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '点击列表中的图片即可下载解析',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        );
      }
      // 排队 / 下载中: 显眼占位 + spinner.
      final sel = _selected;
      final isQueued =
          _pendingDownload != null &&
          sel != null &&
          _pendingDownload!.filename == sel.filename;
      final title = isQueued ? '排队中' : '下载中';
      final sub = isQueued ? '等待当前下载完成后立即处理此图' : (_stage ?? '请求文件…');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  color: isQueued ? scheme.tertiary : scheme.primary,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                sub,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              if (sel != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    sel.filename,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final dec = _decoded;
    if (dec?.format == PhotoFormat.jpegLike && dec?.jpegBytes != null) {
      return InteractiveViewer(
        child: Center(
          child: Image.memory(dec!.jpegBytes!, fit: BoxFit.contain),
        ),
      );
    }
    if (r != null) {
      final showVis = _showVisible && dec?.visibleRgb != null;
      // 计算左上角温度叠加 (与导出图保持视觉一致: 叠加贴在真实画面 rect
      // 左上角, 而不是外层 Container 左上). 仅在用户开启时显示.
      Widget? tempBadge;
      if (_tempOverlayEnabled) {
        tempBadge = TempOverlay(
          tMax: r.tMax,
          tMin: r.tMin,
          tAvg:
              _session[_selected?.filename]?.thermalAvgC ??
              (dec?.thermal != null
                  ? computeAvgC(dec!.thermal!)
                  : (r.tMin + r.tMax) / 2),
          compact: MediaQuery.of(context).size.shortestSide < 600,
        );
      }
      // 用 AspectRatio 把 ThermalCanvas 限制到帧比例, 让 TempOverlay 可以
      // Positioned 在 AspectRatio 的左上角 (= 真实图像左上角).
      final thermalRect = Center(
        child: AspectRatio(
          aspectRatio: r.width / r.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: ThermalCanvas(
                  frame: r,
                  showCursorTemp: true,
                  markers: _markers,
                  onAddMarker: (px, py, temp) {
                    setState(() => _markers.add(TempMarker(px, py, temp)));
                  },
                  onRemoveMarker: (i) {
                    setState(() => _markers.removeAt(i));
                  },
                  placeholder: '等待热像数据…',
                ),
              ),
              if (tempBadge != null)
                Positioned(top: 8, left: 8, child: tempBadge),
            ],
          ),
        ),
      );
      return Row(
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: thermalRect,
            ),
          ),
          if (showVis)
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '可见光 (${dec!.visW}x${dec.visH})',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: RgbImageView(
                        rgb: dec.visibleRgb!,
                        width: dec.visW,
                        height: dec.visH,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    // 解析失败 / 未知格式: 显示头部 hex.
    final head = _raw!
        .take(32)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 6),
              Text(
                '未识别的数据格式',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: scheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '字节数: ${_raw!.length}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            '头部 32 字节 (hex):',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              head,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$k: ',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
        TextSpan(
          text: v,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  /// 详情顶部的元数据卡: 默认折叠到单行摘要, 点击右侧 ▶ 展开全部 _kv chips.
  /// 折叠态: '#索引 · 文件名 · 大小' 一行 ellipsis, 不挡参数面板.
  Widget _buildMetaCard(
    PhotoMeta sel,
    PhotoDecoded? dec,
    RenderedFrame? rendered,
    ColorScheme scheme,
  ) {
    final summary =
        '#${sel.index}  ·  ${sel.filename}  ·  ${_fmtSize(sel.size)}';
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _metaExpanded = !_metaExpanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _metaExpanded
                      ? DefaultTextStyle(
                          key: const ValueKey('meta-expanded'),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface,
                          ),
                          child: Wrap(
                            spacing: 18,
                            runSpacing: 6,
                            children: [
                              _kv('索引', '#${sel.index}'),
                              _kv('文件名', sel.filename),
                              _kv('大小', _fmtSize(sel.size)),
                              if (sel.mode != null) _kv('模式', sel.mode!),
                              if (sel.dataFormat != null)
                                _kv('格式', sel.dataFormat!),
                              if (dec?.thermalView != null)
                                _kv(
                                  '热像视图',
                                  '${dec!.thermalView!.scale.toStringAsFixed(1)}x · '
                                      'X ${dec.thermalView!.xOffset} · '
                                      'Y ${dec.thermalView!.yOffset}',
                                ),
                              if (rendered != null)
                                _kv(
                                  '温度范围',
                                  '${rendered.tMin.toStringAsFixed(2)} ~ ${rendered.tMax.toStringAsFixed(2)} °C',
                                ),
                              if (dec != null) _kv('类型', dec.summary),
                            ],
                          ),
                        )
                      : Padding(
                          key: const ValueKey('meta-collapsed'),
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            summary,
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
    );
  }

  static bool _isReasonableTemp(double? v) =>
      v != null && v.isFinite && v > -200 && v < 1000;

  // 设备固件已知 bug: JSON metadata 中 temperatureMax 恒为 213329.13, temperatureMin 为
  // 随机/inf, 不可信. 真实温度来自下载后文件头的 float (PhotoDecoder 已正确解出),
  // 因此 UI 改为下载后展示, 此处保留辅助函数用于将来诊断.
  // ignore: unused_element
  static String _metaRange(PhotoMeta m) {
    final loOk = _isReasonableTemp(m.tempMin);
    final hiOk = _isReasonableTemp(m.tempMax);
    if (!loOk && !hiOk) return '— (设备元数据不可信)';
    final loStr = loOk ? '${m.tempMin!.toStringAsFixed(2)} °C' : '—';
    final hiStr = hiOk ? '${m.tempMax!.toStringAsFixed(2)} °C' : '—';
    return '$loStr ~ $hiStr';
  }

  Future<void> _exportPng() async {
    final dec = _decoded;
    final sel = _selected;
    if (dec == null || sel == null) return;
    setState(() => _statusText = '导出中 ...');
    try {
      // JPEG 直接落盘 .jpg
      if (dec.format == PhotoFormat.jpegLike && dec.jpegBytes != null) {
        final out = await _exportDir();
        final f = File(
          p.join(out.path, '${p.basenameWithoutExtension(sel.filename)}.jpg'),
        );
        await f.writeAsBytes(dec.jpegBytes!);
        final albumOk = await _saveToGalleryIfAndroid(
          bytes: dec.jpegBytes!,
          name: p.basenameWithoutExtension(sel.filename),
        );
        if (!mounted) return;
        setState(
          () => _statusText = albumOk
              ? '已导出: ${f.path} (并保存到相册)'
              : '已导出: ${f.path}',
        );
        _toast(
          albumOk
              ? '已导出 ${p.basename(f.path)} (相册已保存)'
              : '已导出 ${p.basename(f.path)}',
        );
        return;
      }
      // 热成像: 重新渲染 + 在画布上叠加 markers, 输出 PNG.
      if (dec.thermal == null) {
        if (!mounted) return;
        setState(() => _statusText = '无可导出的渲染结果');
        return;
      }
      final r = renderPipeline(
        thermalFrame: dec.thermal!,
        srcW: dec.srcW,
        srcH: dec.srcH,
        params: _photoParams,
        visibleRgb: dec.visibleRgb,
        visibleW: dec.visW,
        visibleH: dec.visH,
        minOverride: dec.tMin,
        maxOverride: dec.tMax,
      );
      final pngBytes = await _renderToPng(
        r,
        _markers,
        overlayMin: _tempOverlayEnabled ? r.tMin : null,
        overlayMax: _tempOverlayEnabled ? r.tMax : null,
        overlayAvg: _tempOverlayEnabled
            ? (dec.thermal != null ? computeAvgC(dec.thermal!) : null)
            : null,
      );
      final out = await _exportDir();
      final f = File(
        p.join(out.path, '${p.basenameWithoutExtension(sel.filename)}.png'),
      );
      await f.writeAsBytes(pngBytes);
      final albumOk = await _saveToGalleryIfAndroid(
        bytes: pngBytes,
        name: p.basenameWithoutExtension(sel.filename),
      );
      if (!mounted) return;
      setState(
        () => _statusText = albumOk
            ? '已导出: ${f.path} (并保存到相册)'
            : '已导出: ${f.path}',
      );
      _toast(
        albumOk
            ? '已导出 ${p.basename(f.path)} (相册已保存)'
            : '已导出 ${p.basename(f.path)}',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = '导出失败: $e');
    }
  }

  /// Android: 把图片字节同时写入系统相册 (MediaStore Pictures/BananaThermal).
  /// 桌面端直接返回 false. 失败仅 toast 提示, 不抛.
  Future<bool> _saveToGalleryIfAndroid({
    required Uint8List bytes,
    required String name,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      // gal 2.x: hasAccess/requestAccess 用于 toAlbum 才需; putImageBytes
      // 默认走 MediaStore, 在 Android 10+ 无需运行时权限.
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) return false;
      }
      await Gal.putImageBytes(bytes, album: 'BananaThermal', name: name);
      return true;
    } catch (e) {
      _toast('相册保存失败: $e');
      return false;
    }
  }

  Future<Directory> _exportDir() async {
    final root = await _ensureRoot();
    final dir = Directory(p.join(root.path, 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 把渲染后的 RGB + markers 画到 ui.Canvas, 输出 PNG bytes.
  ///
  /// [overlayMin]/[overlayMax]/[overlayAvg] 同时非 null 时, 在左上角烘焙一
  /// 条半透明温度补丁 (MAX/MIN/AVG), 与详情页看到的叠加保持一致.
  Future<Uint8List> _renderToPng(
    RenderedFrame r,
    List<TempMarker> markers, {
    double? overlayMin,
    double? overlayMax,
    double? overlayAvg,
  }) async {
    // 先把 RGB888 转成 ui.Image
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
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, r.width.toDouble(), r.height.toDouble()),
    );
    canvas.drawImage(baseImg, Offset.zero, Paint());

    // markers: 在帧像素坐标上绘制 (导出为帧分辨率 PNG).
    // 字号 / 圆半径按帧短边比例缩放, 保证小图也可读.
    final shortSide = r.width < r.height ? r.width : r.height;
    final fontSize = (shortSide / 22).clamp(10.0, 28.0);
    final dotR = (shortSide / 80).clamp(2.0, 7.0);
    final ringR = dotR + 2;
    for (final m in markers) {
      final cx = m.px + 0.5;
      final cy = m.py + 0.5;
      canvas.drawCircle(
        Offset(cx, cy),
        ringR,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      canvas.drawCircle(
        Offset(cx, cy),
        dotR,
        Paint()..color = const Color(0xFFFF5252),
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '${m.temp.toStringAsFixed(1)} \u00b0C',
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            fontFamily: currentAppFontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final bx = (cx + ringR + 2).clamp(0.0, r.width - tp.width - 4);
      final by = (cy - tp.height - 2).clamp(0.0, r.height - tp.height - 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(bx - 3, by - 1, tp.width + 6, tp.height + 2),
          const Radius.circular(3),
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.7),
      );
      tp.paint(canvas, Offset(bx, by));
    }

    // 烘焙温度叠加 (与详情页一致). 三项必须同时非 null 才绘制.
    if (overlayMin != null && overlayMax != null && overlayAvg != null) {
      _drawTempOverlayOnCanvas(
        canvas,
        r.width.toDouble(),
        r.height.toDouble(),
        overlayMin,
        overlayMax,
        overlayAvg,
      );
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(r.width, r.height);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw 'toByteData null';
    return bytes.buffer.asUint8List();
  }

  /// 把温度叠加 (MAX/MIN/AVG) 烘焙到导出画布的左上角. 与详情页 TempOverlay
  /// 视觉一致 (黑底 45% 透明 + 圆角胶囊 + 三色圆点).
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
          fontFamily: currentAppFontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final items = <({Color color, TextPainter label, TextPainter value})>[
      (
        color: const Color(0xFFFF6E40),
        label: mk('MAX', labelSize, FontWeight.w600, Colors.white70),
        value: mk(
          '${tMax.toStringAsFixed(1)}°',
          fontSize,
          FontWeight.w700,
          Colors.white,
        ),
      ),
      (
        color: const Color(0xFF40C4FF),
        label: mk('MIN', labelSize, FontWeight.w600, Colors.white70),
        value: mk(
          '${tMin.toStringAsFixed(1)}°',
          fontSize,
          FontWeight.w700,
          Colors.white,
        ),
      ),
      (
        color: const Color(0xFFFFD740),
        label: mk('AVG', labelSize, FontWeight.w600, Colors.white70),
        value: mk(
          '${tAvg.toStringAsFixed(1)}°',
          fontSize,
          FontWeight.w700,
          Colors.white,
        ),
      ),
    ];

    // 每个 item 宽度 = 圆点 + 间隔 + max(label, value) 宽
    double itemW(({Color color, TextPainter label, TextPainter value}) it) {
      final textW = it.label.width > it.value.width
          ? it.label.width
          : it.value.width;
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
      // 圆点垂直居中
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

  static String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.meta,
    required this.selected,
    required this.onTap,
    this.queued = false,
    this.thumb,
  });
  final PhotoMeta meta;
  final bool selected;
  final bool queued;
  final VoidCallback onTap;

  /// 单次会话缓存生成的缩略图. 非空时序号位置替换为热成像 / JPEG 缩略.
  final ui.Image? thumb;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasThumb = thumb != null;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.16)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                clipBehavior: hasThumb ? Clip.antiAlias : Clip.none,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: hasThumb && selected
                      ? Border.all(color: scheme.primary, width: 1.5)
                      : null,
                ),
                child: hasThumb
                    ? RawImage(
                        image: thumb,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                      )
                    : Text(
                        '${meta.index}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        _fmtSizeStatic(meta.size),
                        if (meta.mode != null) meta.mode!,
                        if (meta.dataFormat != null) meta.dataFormat!,
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (queued) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.tertiary,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '排队',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: scheme.tertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 见 _metaRange 注释: 元数据温度不可信, 列表卡片不再展示. 函数保留备用.
  // ignore: unused_element
  static String _tempPart(PhotoMeta m) {
    final lo = m.tempMin, hi = m.tempMax;
    bool ok(double? v) => v != null && v.isFinite && v > -200 && v < 1000;
    final loOk = ok(lo);
    final hiOk = ok(hi);
    if (!loOk && !hiOk) return '';
    final loS = loOk ? lo!.toStringAsFixed(1) : '—';
    final hiS = hiOk ? hi!.toStringAsFixed(1) : '—';
    return '$loS~$hiS°C';
  }

  static String _fmtSizeStatic(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

/// FusionParams 无 copyWith, 在此本地实现.
FusionParams _fusionWith(
  FusionParams f, {
  FusionMode? mode,
  double? alpha,
  double? gamma,
  double? edgeStrength,
  double? edgeThresh,
  double? edgeWidth,
}) {
  return FusionParams(
    mode: mode ?? f.mode,
    gamma: gamma ?? f.gamma,
    alpha: alpha ?? f.alpha,
    edgeStrength: edgeStrength ?? f.edgeStrength,
    edgeThresh: edgeThresh ?? f.edgeThresh,
    edgeWidth: edgeWidth ?? f.edgeWidth,
    edgeColor: f.edgeColor,
  );
}

/// 颜色映射的中文名.
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

/// 下载后预览上方的参数控件 (两行):
/// 行 1: 颜色映射 + 映射曲线 + 融合模式
/// 行 2: 当前融合模式对应的参数 (关闭则隐藏)
class _ParamsRow extends StatelessWidget {
  const _ParamsRow({
    required this.hasVisible,
    required this.params,
    required this.onParamsChanged,
    this.phone = false,
  });
  final bool hasVisible;
  final bool phone;
  final RenderParams params;
  final ValueChanged<RenderParams> onParamsChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        t,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );

    final colorWidgets = <Widget>[
      label('颜色映射'),
      _Dropdown<String>(
        value: params.colormapName,
        items: _colormapZh.keys.toList(),
        onChanged: (v) => onParamsChanged(
          params.copyWith(colormapName: v, useCustomColors: false),
        ),
        labelOf: (v) => _colormapZh[v] ?? v,
      ),
      const SizedBox(width: 14),
      label('映射曲线'),
      _Dropdown<String>(
        value: params.mappingCurve,
        items: const ['linear', 'nonlinear'],
        onChanged: (v) => onParamsChanged(params.copyWith(mappingCurve: v)),
        labelOf: (v) => v == 'linear' ? '线性' : 'S 曲线',
      ),
    ];
    final fusionWidgets = <Widget>[
      if (hasVisible) ...[
        label('融合模式'),
        _Dropdown<FusionMode>(
          value: params.fusion.mode,
          items: FusionMode.values,
          onChanged: (v) => onParamsChanged(
            params.copyWith(fusion: _fusionWith(params.fusion, mode: v)),
          ),
          labelOf: (v) => switch (v) {
            FusionMode.off => '关闭',
            FusionMode.blend => '混合',
            FusionMode.edge => '边缘',
          },
        ),
      ],
    ];
    // 桌面: 颜色映射 / 曲线 / 融合 都塞一行 (Wrap 自动换行).
    // 手机: 强制把 "融合模式" 单独一行, 避免挤在一起换行错位.
    final row1 = phone
        ? colorWidgets
        : [
            ...colorWidgets,
            if (fusionWidgets.isNotEmpty) const SizedBox(width: 14),
            ...fusionWidgets,
          ];

    // 第二行: 仅在双光 + 融合开启时显示对应参数.
    final row2 = <Widget>[];
    if (hasVisible && params.fusion.mode != FusionMode.off) {
      final f = params.fusion;
      if (f.mode == FusionMode.blend) {
        row2.addAll([
          _slider(
            context,
            title: '混合度',
            value: f.alpha,
            min: 0,
            max: 1,
            onChanged: (v) => onParamsChanged(
              params.copyWith(fusion: _fusionWith(f, alpha: v)),
            ),
          ),
          _slider(
            context,
            title: '伽马值',
            value: f.gamma,
            min: 0.3,
            max: 3.0,
            onChanged: (v) => onParamsChanged(
              params.copyWith(fusion: _fusionWith(f, gamma: v)),
            ),
          ),
        ]);
      } else if (f.mode == FusionMode.edge) {
        row2.addAll([
          _slider(
            context,
            title: '伽马值',
            value: f.gamma,
            min: 0.3,
            max: 3.0,
            onChanged: (v) => onParamsChanged(
              params.copyWith(fusion: _fusionWith(f, gamma: v)),
            ),
          ),
          _slider(
            context,
            title: '强度',
            value: f.edgeStrength,
            min: 0,
            max: 1,
            onChanged: (v) => onParamsChanged(
              params.copyWith(fusion: _fusionWith(f, edgeStrength: v)),
            ),
          ),
          _slider(
            context,
            title: '阈值',
            value: f.edgeThresh,
            min: 0,
            max: 0.5,
            digits: 3,
            onChanged: (v) => onParamsChanged(
              params.copyWith(fusion: _fusionWith(f, edgeThresh: v)),
            ),
          ),
          _slider(
            context,
            title: '粗细',
            value: f.edgeWidth,
            min: 0,
            max: 6,
            onChanged: (v) => onParamsChanged(
              params.copyWith(fusion: _fusionWith(f, edgeWidth: v)),
            ),
          ),
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
        if (phone && fusionWidgets.isNotEmpty) ...[
          const SizedBox(height: 6),
          shell(fusionWidgets),
        ],
        if (row2.isNotEmpty) ...[const SizedBox(height: 6), shell(row2)],
      ],
    );
  }

  Widget _slider(
    BuildContext ctx, {
    required String title,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    int digits = 2,
  }) {
    final scheme = Theme.of(ctx).colorScheme;
    return SizedBox(
      width: 230,
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              title,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
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
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
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

/// 设备图库单次会话缓存条目: filename → 已下载/已解码资源 + 列表缩略图.
///
/// - [raw] / [decoded]: 用户再次点击同一张图时秒开 (跳过设备 IO + 协议解析).
/// - [thumb] / [thumbBytes]: 列表项左侧 28×28 缩略图 (优先热成像渲染结果, 否则 JPEG).
/// - [thermalAvgC]: 平均温度 (从 thermal Float32List 求平均), 用于温度叠加.
/// - 与位于 `<download_root>/raw/` + sha256 指纹的「持久缓存」 (PhotoCacheIndex) 互不干涉:
///   持久缓存跨进程存活, 单次缓存仅当前 tab state 生命周期内, 刷新按钮即清空.
class _PhotoSessionEntry {
  _PhotoSessionEntry({required this.raw, required this.decoded});

  final Uint8List raw;
  final PhotoDecoded decoded;
  ui.Image? thumb;
  double? thermalAvgC;
}
