/// 拍摄 / 录制服务: 从 [AppState] 当前帧打包成 `.btpkg`.
///
/// 与设备图库 (PhotoDownloadTab 下载到本地的 jpg/raw) 严格隔离 —
/// 软件图库只读 `.btpkg`, 设备图库只读固件下行的原始照片. 两条路径互不污染.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'capture_package.dart';

/// 录制运行时状态.
enum RecordingState { idle, recording, finalizing }

/// 单例: 维护录制 writer + 输出根目录解析逻辑.
class CaptureService {
  CaptureService._();
  static final CaptureService instance = CaptureService._();

  CapturePackageWriter? _writer;
  DateTime? _recordingStart;
  RecordingState _state = RecordingState.idle;
  int _frameCount = 0;
  String? _activePath;
  // 录制写入串行队列: 帧到达回调是同步的, 但 PNG 编码 + 文件 IO 异步, 必须
  // 串行避免 RandomAccessFile 并发写崩溃 / frameCount 错乱.
  Future<void> _writeQueue = Future<void>.value();

  RecordingState get state => _state;
  int get frameCount => _frameCount;
  DateTime? get recordingStart => _recordingStart;
  String? get activePath => _activePath;

  /// 软件图库根目录: `<Documents>/BananaThermalStudio/SoftwareGallery`.
  /// 与设备图库 (`<Documents>/BananaThermalStudio/...` 用户可改) 物理分离.
  static Future<Directory> defaultGalleryDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'BananaThermalStudio', 'SoftwareGallery'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 把当前帧打包成 photo `.btpkg`. 返回写入路径.
  Future<String> takePhoto({
    required Float32List thermal,
    required int thermalW,
    required int thermalH,
    Uint8List? visibleRgb888,
    int visibleW = 0,
    int visibleH = 0,
    double? lat,
    double? lng,
    double? alt,
    String? place,
    String? deviceSn,
    String note = '',
    Map<String, dynamic>? renderParams,
    Directory? outDir,
  }) async {
    if (_state != RecordingState.idle) {
      throw StateError('正在录制中, 无法单独拍摄');
    }
    final dir = outDir ?? await defaultGalleryDir();
    final now = DateTime.now();
    final filename = 'IMG_${_ts(now)}.btpkg';
    final path = p.join(dir.path, filename);

    Uint8List visPng = Uint8List(0);
    if (visibleRgb888 != null && visibleW > 0 && visibleH > 0) {
      visPng = _encodePng(visibleRgb888, visibleW, visibleH);
    }
    final meta = CaptureMeta(
      createdAt: now.toUtc(),
      lat: lat,
      lng: lng,
      alt: alt,
      place: place,
      note: note,
      deviceSn: deviceSn,
      thermalW: thermalW,
      thermalH: thermalH,
      visibleW: visPng.isEmpty ? 0 : visibleW,
      visibleH: visPng.isEmpty ? 0 : visibleH,
      frameCount: 1,
      renderParams: renderParams,
    );
    final w = await CapturePackageWriter.create(
      path: path,
      type: CapturePackageHeader.typePhoto,
      meta: meta,
    );
    await w.appendFrame(CaptureFrame(
      tsMs: 0,
      thermal: Float32List.fromList(thermal),
      visiblePng: visPng,
    ));
    await w.close();
    return path;
  }

  /// 开始录制. 返回输出文件路径. 录制期间 AppState 应周期性调 [pushFrame].
  Future<String> startRecording({
    required int thermalW,
    required int thermalH,
    int visibleW = 0,
    int visibleH = 0,
    double? lat,
    double? lng,
    double? alt,
    String? place,
    String? deviceSn,
    String note = '',
    Map<String, dynamic>? renderParams,
    Directory? outDir,
  }) async {
    if (_state != RecordingState.idle) {
      throw StateError('已经在录制中');
    }
    final dir = outDir ?? await defaultGalleryDir();
    final now = DateTime.now();
    final filename = 'VID_${_ts(now)}.btpkg';
    final path = p.join(dir.path, filename);
    final meta = CaptureMeta(
      createdAt: now.toUtc(),
      lat: lat,
      lng: lng,
      alt: alt,
      place: place,
      note: note,
      deviceSn: deviceSn,
      thermalW: thermalW,
      thermalH: thermalH,
      visibleW: visibleW,
      visibleH: visibleH,
      frameCount: 0,
      renderParams: renderParams,
    );
    _writer = await CapturePackageWriter.create(
      path: path,
      type: CapturePackageHeader.typeVideo,
      meta: meta,
    );
    _recordingStart = now;
    _frameCount = 0;
    _activePath = path;
    _state = RecordingState.recording;
    return path;
  }

  /// 录制期间, AppState 在收到新帧时调用. 帧到达回调是同步的, PNG 编码 +
  /// 文件 IO 异步, 内部用 [_writeQueue] 串行化, 调用方 fire-and-forget.
  void pushFrame({
    required Float32List thermal,
    Uint8List? visibleRgb888,
    int visibleW = 0,
    int visibleH = 0,
  }) {
    final w = _writer;
    final start = _recordingStart;
    if (w == null || start == null || _state != RecordingState.recording) {
      return;
    }
    final ts = DateTime.now().difference(start).inMilliseconds;
    // 拷贝热帧 (调用方持有的 Float32List 会被下一帧覆写).
    final thermalCopy = Float32List.fromList(thermal);
    final visCopy =
        visibleRgb888 == null ? null : Uint8List.fromList(visibleRgb888);
    _writeQueue = _writeQueue.then((_) async {
      // 二次校验状态: 排队期间可能已 stop.
      if (_state != RecordingState.recording) return;
      Uint8List visPng = Uint8List(0);
      if (visCopy != null && visibleW > 0 && visibleH > 0) {
        visPng = _encodePng(visCopy, visibleW, visibleH);
      }
      try {
        await w.appendFrame(CaptureFrame(
          tsMs: ts,
          thermal: thermalCopy,
          visiblePng: visPng,
        ));
        _frameCount += 1;
      } catch (_) {
        // 静默: 后续 stopRecording 会回写 frameCount, 即使丢一帧也能正常关包.
      }
    });
  }

  /// 停止录制. 安全 close 文件 (回写 frameCount + trailer) 并复位状态.
  Future<String?> stopRecording() async {
    if (_state != RecordingState.recording) return null;
    _state = RecordingState.finalizing;
    // 等待写队列排空, 否则末几帧可能丢失.
    try {
      await _writeQueue;
    } catch (_) {}
    final w = _writer;
    final path = _activePath;
    try {
      await w?.close();
    } catch (_) {}
    _writer = null;
    _recordingStart = null;
    _frameCount = 0;
    _activePath = null;
    _writeQueue = Future<void>.value();
    _state = RecordingState.idle;
    return path;
  }

  /// 强制中止 (异常路径). 不保证文件可读, 但会尽量 flush.
  Future<void> abortRecording() async {
    if (_writer == null) {
      _state = RecordingState.idle;
      return;
    }
    try {
      await _writer!.close();
    } catch (_) {}
    _writer = null;
    _recordingStart = null;
    _frameCount = 0;
    _activePath = null;
    _state = RecordingState.idle;
  }

  static String _ts(DateTime t) {
    String two(int x) => x.toString().padLeft(2, '0');
    final l = t.toLocal();
    return '${l.year}${two(l.month)}${two(l.day)}_${two(l.hour)}${two(l.minute)}${two(l.second)}';
  }

  static Uint8List _encodePng(Uint8List rgb888, int w, int h) {
    final im = img.Image(width: w, height: h);
    int i = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final r = rgb888[i];
        final g = rgb888[i + 1];
        final b = rgb888[i + 2];
        i += 3;
        im.setPixelRgb(x, y, r, g, b);
      }
    }
    return Uint8List.fromList(img.encodePng(im, level: 6));
  }
}

/// 软件图库索引项: 列出目录时的简化视图.
class SoftwareGalleryItem {
  final String path;
  final String name;
  final int sizeBytes;
  final DateTime mtime;
  // 来自 meta 的关键字段 (懒加载, 失败时为 null).
  final CaptureMeta? meta;
  final int packageType; // 0 photo / 1 video / -1 unknown

  const SoftwareGalleryItem({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.mtime,
    required this.meta,
    required this.packageType,
  });
}

/// 扫描软件图库目录, 不解析 frames (只读 header + meta).
class SoftwareGalleryIndex {
  /// 列出目录内所有 `.btpkg`. 按修改时间倒序 (新的在前).
  static Future<List<SoftwareGalleryItem>> list({Directory? dir}) async {
    final d = dir ?? await CaptureService.defaultGalleryDir();
    if (!await d.exists()) return const [];
    final items = <SoftwareGalleryItem>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      if (!e.path.toLowerCase().endsWith('.btpkg')) continue;
      try {
        final st = await e.stat();
        // 只读 header + meta (轻量).
        final reader = await CapturePackageReader.open(e.path);
        items.add(SoftwareGalleryItem(
          path: e.path,
          name: p.basename(e.path),
          sizeBytes: st.size,
          mtime: st.modified,
          meta: reader.meta,
          packageType: reader.type,
        ));
      } catch (_) {
        // 损坏文件: 仍列出, 但 meta=null.
        try {
          final st = await e.stat();
          items.add(SoftwareGalleryItem(
            path: e.path,
            name: p.basename(e.path),
            sizeBytes: st.size,
            mtime: st.modified,
            meta: null,
            packageType: -1,
          ));
        } catch (_) {}
      }
    }
    items.sort((a, b) => b.mtime.compareTo(a.mtime));
    return items;
  }
}
